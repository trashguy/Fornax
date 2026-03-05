// IRQ forwarding to userspace via MSI-X.
// Allocates interrupt vectors, programs MSI-X hardware, and delivers
// pending counts to userspace via dev_irq file descriptors.

const process = @import("process.zig");
const klog = @import("klog.zig");
const mem = @import("mem.zig");

const arch = @import("builtin").cpu.arch;
const apic = if (arch == .x86_64) @import("arch/x86_64/apic.zig") else undefined;
const pci = if (arch == .x86_64) @import("arch/x86_64/pci.zig") else undefined;
const interrupts = if (arch == .x86_64) @import("arch/x86_64/interrupts.zig") else undefined;

pub const MAX_FORWARDS = 32;

pub const IrqForward = struct {
    active: bool = false,
    vector: u8 = 0,
    owner_pid: u32 = 0,
    pending_count: u32 align(4) = 0,
    waiter_pid: u32 align(4) = 0,
    masked: bool = false,
    msix_table_virt: u64 = 0,
    msix_entry_index: u16 = 0,
    pci_dev_index: u16 = 0,
};

pub var forwards: [MAX_FORWARDS]IrqForward = [_]IrqForward{.{}} ** MAX_FORWARDS;

// --- Comptime-generated ISR handlers ---
// VectorHandler = *const fn() bool — no context param, so we generate
// 32 distinct function pointers, each baking in its forward slot index.

fn irqForwardHandler(comptime idx: u5) bool {
    const fwd = &forwards[idx];
    if (!fwd.active) return false;

    // Atomic increment pending_count
    _ = @atomicRmw(u32, &fwd.pending_count, .Add, 1, .seq_cst);

    // Auto-mask the MSI-X entry to prevent interrupt storms.
    // Write 1 to vector_control (bit 0 = mask) at entry offset + 12.
    if (fwd.msix_table_virt != 0) {
        const vc_addr = fwd.msix_table_virt + @as(u64, fwd.msix_entry_index) * 16 + 12;
        const vc_ptr: *volatile u32 = @ptrFromInt(vc_addr);
        vc_ptr.* = 1;
    }
    fwd.masked = true;

    // Wake waiter if any
    const waiter = @atomicLoad(u32, &fwd.waiter_pid, .seq_cst);
    if (waiter != 0) {
        _ = process.markReadyByPid(waiter);
    }

    return true;
}

fn makeHandler(comptime idx: u5) interrupts.VectorHandler {
    const S = struct {
        fn handler() bool {
            return irqForwardHandler(idx);
        }
    };
    return S.handler;
}

const handlers = blk: {
    var h: [MAX_FORWARDS]interrupts.VectorHandler = undefined;
    for (0..MAX_FORWARDS) |i| {
        h[i] = makeHandler(@intCast(i));
    }
    break :blk h;
};

// --- Alloc / Free ---

pub const AllocResult = struct {
    slot: u8,
    vector: u8,
};

pub fn alloc(dev_index: u16, msix_entry: u16, pid: u32) ?AllocResult {
    if (arch != .x86_64) return null;

    // Find free slot
    var slot: ?u8 = null;
    for (0..MAX_FORWARDS) |i| {
        if (!forwards[i].active) {
            slot = @intCast(i);
            break;
        }
    }
    const s = slot orelse return null;

    // Allocate interrupt vector
    const vector = apic.allocVector() orelse return null;

    // Get PCI device and validate MSI-X
    const devs = pci.getDevices();
    if (dev_index >= devs.len) {
        apic.freeVector(vector);
        return null;
    }
    const dev = &devs[dev_index];
    const msix_cap = dev.msix orelse {
        apic.freeVector(vector);
        return null;
    };

    // Pre-compute MSI-X table virtual address
    const bar_phys = dev.memBase(msix_cap.table_bar) orelse {
        apic.freeVector(vector);
        return null;
    };
    const table_virt = (bar_phys + msix_cap.table_offset) +% mem.KERNEL_VIRT_BASE;

    // Program MSI-X entry — route to BSP (core 0)
    if (!pci.enableMsixEntry(dev, msix_entry, vector, apic.lapic_ids[0])) {
        apic.freeVector(vector);
        return null;
    }

    // Register vector handler
    if (!interrupts.registerVectorHandler(vector, handlers[s])) {
        apic.freeVector(vector);
        return null;
    }

    // Populate struct
    forwards[s] = .{
        .active = true,
        .vector = vector,
        .owner_pid = pid,
        .pending_count = 0,
        .waiter_pid = 0,
        .masked = false,
        .msix_table_virt = table_virt,
        .msix_entry_index = msix_entry,
        .pci_dev_index = dev_index,
    };

    return .{ .slot = s, .vector = vector };
}

pub fn free(slot: u8) void {
    if (arch != .x86_64) return;
    if (slot >= MAX_FORWARDS) return;

    const fwd = &forwards[slot];
    if (!fwd.active) return;

    // Mask the MSI-X entry
    if (fwd.msix_table_virt != 0) {
        const vc_addr = fwd.msix_table_virt + @as(u64, fwd.msix_entry_index) * 16 + 12;
        const vc_ptr: *volatile u32 = @ptrFromInt(vc_addr);
        vc_ptr.* = 1;
    }

    // Unregister vector handler
    interrupts.unregisterVectorHandler(fwd.vector);

    // Free vector
    apic.freeVector(fwd.vector);

    // Clear struct
    fwd.* = .{};
}

// --- Query functions ---

pub fn hasPending(slot: u8) bool {
    if (slot >= MAX_FORWARDS) return false;
    return @atomicLoad(u32, &forwards[slot].pending_count, .seq_cst) > 0;
}

pub fn setWaiter(slot: u8, pid: u32) void {
    if (slot >= MAX_FORWARDS) return;
    @atomicStore(u32, &forwards[slot].waiter_pid, pid, .seq_cst);
}

pub fn consumePending(slot: u8) u32 {
    if (slot >= MAX_FORWARDS) return 0;
    return @atomicRmw(u32, &forwards[slot].pending_count, .Xchg, 0, .seq_cst);
}

pub fn maskEntry(slot: u8) void {
    if (slot >= MAX_FORWARDS) return;
    const fwd = &forwards[slot];
    if (!fwd.active) return;
    if (fwd.msix_table_virt != 0) {
        const vc_addr = fwd.msix_table_virt + @as(u64, fwd.msix_entry_index) * 16 + 12;
        const vc_ptr: *volatile u32 = @ptrFromInt(vc_addr);
        vc_ptr.* = 1;
    }
    fwd.masked = true;
}

pub fn unmaskEntry(slot: u8) void {
    if (slot >= MAX_FORWARDS) return;
    const fwd = &forwards[slot];
    if (!fwd.active) return;
    if (fwd.msix_table_virt != 0) {
        const vc_addr = fwd.msix_table_virt + @as(u64, fwd.msix_entry_index) * 16 + 12;
        const vc_ptr: *volatile u32 = @ptrFromInt(vc_addr);
        vc_ptr.* = 0;
    }
    fwd.masked = false;
}

pub fn freeByPid(pid: u32) void {
    for (0..MAX_FORWARDS) |i| {
        if (forwards[i].active and forwards[i].owner_pid == pid) {
            free(@intCast(i));
        }
    }
}
