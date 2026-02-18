/// Local APIC driver + ACPI MADT parser + AP startup.
///
/// Parses the ACPI MADT to discover LAPIC IDs, initializes the BSP's LAPIC,
/// and boots Application Processors (APs) via INIT-SIPI-SIPI.
/// APs enter an idle loop, ready for Phase D scheduling.
const klog = @import("../../klog.zig");
const cpu = @import("cpu.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const percpu = @import("../../percpu.zig");
const mem = @import("../../mem.zig");
const pmm = @import("../../pmm.zig");

// ── ACPI table structures ────────────────────────────────────────────

const RsdpV2 = extern struct {
    signature: [8]u8, // "RSD PTR "
    checksum: u8,
    oem_id: [6]u8,
    revision: u8, // 2 for ACPI 2.0+
    rsdt_address: u32,
    length: u32,
    xsdt_address: u64,
    extended_checksum: u8,
    reserved: [3]u8,
};

const AcpiSdtHeader = extern struct {
    signature: [4]u8,
    length: u32,
    revision: u8,
    checksum: u8,
    oem_id: [6]u8,
    oem_table_id: [8]u8,
    oem_revision: u32,
    creator_id: u32,
    creator_revision: u32,
};

const MadtHeader = extern struct {
    header: AcpiSdtHeader,
    lapic_address: u32,
    flags: u32,
};

const MadtEntryHeader = extern struct {
    entry_type: u8,
    length: u8,
};

const MadtLocalApic = extern struct {
    header: MadtEntryHeader,
    acpi_processor_id: u8,
    apic_id: u8,
    flags: u32,
};

// MADT entry types
const MADT_LOCAL_APIC = 0;
const MADT_IO_APIC = 1;

// ── LAPIC registers (MMIO, at LAPIC base + offset) ──────────────────

const LAPIC_ID = 0x020;
const LAPIC_VERSION = 0x030;
const LAPIC_TPR = 0x080;
const LAPIC_EOI = 0x0B0;
const LAPIC_SVR = 0x0F0;
const LAPIC_ICR_LO = 0x300;
const LAPIC_ICR_HI = 0x310;
const LAPIC_TIMER_LVT = 0x320;
const LAPIC_TIMER_INIT = 0x380;
const LAPIC_TIMER_CURRENT = 0x390;
const LAPIC_TIMER_DIVIDE = 0x3E0;

// SVR bits
const SVR_ENABLE = 0x100;
const SVR_SPURIOUS_VECTOR = 0xFF; // Spurious vector number

// ICR delivery modes
const ICR_INIT = 0x00000500;
const ICR_STARTUP = 0x00000600;
const ICR_LEVEL_ASSERT = 0x00004000;
const ICR_LEVEL_DEASSERT = 0x00000000;

// IPI vectors
pub const IPI_SCHEDULE: u8 = 0xFE;
pub const IPI_TLB_SHOOTDOWN: u8 = 0xFD;

// ── Module state ─────────────────────────────────────────────────────

var lapic_base: u64 = 0;
var lapic_virt: u64 = 0; // Higher-half virtual address for MMIO

/// Discovered LAPIC IDs. Index 0 = BSP.
pub var lapic_ids: [percpu.MAX_CORES]u8 = [_]u8{0} ** percpu.MAX_CORES;
pub var core_count: u8 = 0;

/// Convert physical address to higher-half virtual address.
inline fn physToVirt(phys: u64) u64 {
    return phys +% mem.KERNEL_VIRT_BASE;
}

// AP boot synchronization (accessed via @atomicStore/@atomicLoad)
var ap_boot_done: bool = false;
var ap_boot_core_id: u8 = 0;

// ── LAPIC MMIO helpers ──────────────────────────────────────────────

fn lapicRead(reg: u32) u32 {
    const addr: *volatile u32 = @ptrFromInt(lapic_virt + reg);
    return addr.*;
}

fn lapicWrite(reg: u32, val: u32) void {
    const addr: *volatile u32 = @ptrFromInt(lapic_virt + reg);
    addr.* = val;
}

/// Send EOI to local APIC.
pub fn sendEoi() void {
    if (lapic_virt != 0) {
        lapicWrite(LAPIC_EOI, 0);
    }
}

/// Send an IPI to a specific core.
pub fn sendIpi(target_lapic_id: u8, vector: u8) void {
    if (lapic_virt == 0) return;
    // Set destination in ICR high
    lapicWrite(LAPIC_ICR_HI, @as(u32, target_lapic_id) << 24);
    // Send fixed IPI with the given vector
    lapicWrite(LAPIC_ICR_LO, @as(u32, vector));
}

// ── MADT Parsing ────────────────────────────────────────────────────

fn parseMadt(madt_phys: u64) void {
    const madt: *align(1) const MadtHeader = @ptrFromInt(physToVirt(madt_phys));
    lapic_base = madt.lapic_address;
    klog.info("MADT: LAPIC at 0x");
    klog.infoHex(lapic_base);
    klog.info("\n");

    const total_len = madt.header.length;
    var offset: u32 = @sizeOf(MadtHeader);

    while (offset + 2 <= total_len) {
        const entry_ptr: [*]const u8 = @ptrFromInt(physToVirt(madt_phys) + offset);
        const entry: *align(1) const MadtEntryHeader = @ptrCast(entry_ptr);

        if (entry.length < 2) break;

        if (entry.entry_type == MADT_LOCAL_APIC and entry.length >= @sizeOf(MadtLocalApic)) {
            const lapic_entry: *align(1) const MadtLocalApic = @ptrCast(entry_ptr);
            // Bit 0 of flags = processor enabled, bit 1 = online capable
            if (lapic_entry.flags & 0x1 != 0 and core_count < percpu.MAX_CORES) {
                lapic_ids[core_count] = lapic_entry.apic_id;
                klog.info("MADT: Core ");
                klog.infoHex(core_count);
                klog.info(" LAPIC ID=");
                klog.infoHex(lapic_entry.apic_id);
                klog.info("\n");
                core_count += 1;
            }
        }

        offset += entry.length;
    }
}

fn findMadt(rsdp_ptr: [*]const u8) bool {
    const rsdp: *align(1) const RsdpV2 = @ptrCast(rsdp_ptr);

    // Validate signature
    if (!eqlBytes(&rsdp.signature, "RSD PTR ")) {
        klog.err("ACPI: bad RSDP signature\n");
        return false;
    }

    if (rsdp.revision < 2 or rsdp.xsdt_address == 0) {
        klog.err("ACPI: need XSDT (revision >= 2)\n");
        return false;
    }

    // Walk XSDT — entries may not be 8-byte aligned (header is 36 bytes)
    const xsdt: *align(1) const AcpiSdtHeader = @ptrFromInt(physToVirt(rsdp.xsdt_address));
    const entries_len = (xsdt.length - @sizeOf(AcpiSdtHeader)) / 8;
    const entries_base = physToVirt(rsdp.xsdt_address) + @sizeOf(AcpiSdtHeader);

    for (0..entries_len) |i| {
        const entry_ptr: *align(1) const u64 = @ptrFromInt(entries_base + i * 8);
        const table_phys = entry_ptr.*;
        const table: *align(1) const AcpiSdtHeader = @ptrFromInt(physToVirt(table_phys));
        if (eqlBytes(&table.signature, "APIC")) {
            parseMadt(table_phys);
            return true;
        }
    }

    klog.err("ACPI: MADT not found in XSDT\n");
    return false;
}

// ── LAPIC initialization ────────────────────────────────────────────

fn initLapic() void {
    // Map LAPIC MMIO page into higher-half
    lapic_virt = physToVirt(lapic_base);

    // Enable LAPIC: set SVR with enable bit + spurious vector
    lapicWrite(LAPIC_SVR, SVR_ENABLE | SVR_SPURIOUS_VECTOR);

    // Set task priority to 0 (accept all interrupts)
    lapicWrite(LAPIC_TPR, 0);

    klog.info("LAPIC: enabled (ID=");
    klog.infoHex(lapicRead(LAPIC_ID) >> 24);
    klog.info(")\n");
}

// ── AP Trampoline ──────────────────────────────────────────────────
//
// The trampoline runs at physical address 0x8000 (SIPI vector 0x08).
// It transitions the AP from 16-bit real mode to 64-bit long mode,
// then calls apEntry(). Layout:
//
//   0x8000+0x00: 16-bit real mode code
//   0x8000+0x50: 64-bit long mode code
//   0x8000+0x80: temporary GDT (null + code64 + data)
//   0x8000+0x98: GDT pointer (6 bytes)
//   0x8000+0xC0: data area (patched per-AP by BSP)

const TRAMPOLINE_BASE: u64 = 0x8000;
const SIPI_VECTOR: u8 = 0x08; // vector * 0x1000 = 0x8000

// Data area offsets within the trampoline page
const DATA_CR3: usize = 0xC0;
const DATA_STACK_TOP: usize = 0xC4;
const DATA_ENTRY: usize = 0xCC;

/// Raw trampoline machine code.
/// 16-bit section (0x00-0x42): real mode → long mode transition
/// 64-bit section (0x50-0x72): load segments + stack, call entry
/// GDT (0x80-0x97): null + code64 + data descriptors
/// GDT ptr (0x98-0x9D): limit=23, base=0x00008080
const trampoline_code = [_]u8{
    // ===== 16-bit real mode (physical 0x8000, CS=0x0800 IP=0x0000) =====
    0xFA, // 0x00: cli
    0x31, 0xC0, // 0x01: xor ax, ax
    0x8E, 0xD8, // 0x03: mov ds, ax
    0x8E, 0xC0, // 0x05: mov es, ax
    0x8E, 0xD0, // 0x07: mov ss, ax
    0x0F, 0x01, 0x16, 0x98, 0x80, // 0x09: lgdt [0x8098] (trampoline GDT ptr)
    // Enable PAE (CR4.PAE = bit 5)
    0x0F, 0x20, 0xE0, // 0x0E: mov eax, cr4
    0x66, 0x83, 0xC8, 0x20, // 0x11: or eax, 0x20
    0x0F, 0x22, 0xE0, // 0x15: mov cr4, eax
    // Load CR3 from data area
    0x66, 0xA1, 0xC0, 0x80, // 0x18: mov eax, [0x80C0] (cr3 value)
    0x0F, 0x22, 0xD8, // 0x1C: mov cr3, eax
    // Enable long mode (IA32_EFER.LME = bit 8)
    0x66, 0xB9, 0x80, 0x00, 0x00, 0xC0, // 0x1F: mov ecx, 0xC0000080
    0x0F, 0x32, // 0x25: rdmsr
    0x66, 0x0D, 0x00, 0x01, 0x00, 0x00, // 0x27: or eax, 0x100
    0x0F, 0x30, // 0x2D: wrmsr
    // Enable paging + protected mode (CR0.PG|CR0.PE)
    0x0F, 0x20, 0xC0, // 0x2F: mov eax, cr0
    0x66, 0x0D, 0x01, 0x00, 0x00, 0x80, // 0x32: or eax, 0x80000001
    0x0F, 0x22, 0xC0, // 0x38: mov cr0, eax
    // Far jump to 64-bit code (selector 0x08, offset 0x00008050)
    0x66, 0xEA, 0x50, 0x80, 0x00, 0x00, 0x08, 0x00, // 0x3B: jmp 0x0008:0x8050
    // Padding to offset 0x50
    0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, // 0x43-0x4A
    0x90, 0x90, 0x90, 0x90, 0x90, // 0x4B-0x4F

    // ===== 64-bit long mode (physical 0x8050) =====
    // Load data segment registers
    0xB8, 0x10, 0x00, 0x00, 0x00, // 0x50: mov eax, 0x10
    0x8E, 0xD8, // 0x55: mov ds, ax
    0x8E, 0xC0, // 0x57: mov es, ax
    0x8E, 0xD0, // 0x59: mov ss, ax
    0x31, 0xC0, // 0x5B: xor eax, eax
    0x8E, 0xE0, // 0x5D: mov fs, ax
    0x8E, 0xE8, // 0x5F: mov gs, ax
    // Load stack from data area [0x80C4] (u64)
    0x48, 0x8B, 0x24, 0x25, 0xC4, 0x80, 0x00, 0x00, // 0x61: mov rsp, [0x80C4]
    // Call entry point from data area [0x80CC] (u64)
    0x48, 0x8B, 0x04, 0x25, 0xCC, 0x80, 0x00, 0x00, // 0x69: mov rax, [0x80CC]
    0xFF, 0xD0, // 0x71: call rax (pushes return addr → ABI-correct alignment)
    // Should never return
    0xF4, // 0x73: hlt
    0xEB, 0xFD, // 0x74: jmp $-1 (infinite loop)
    // Padding to offset 0x80
    0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, // 0x76-0x7E
    0x90, // 0x7F

    // ===== Trampoline GDT (physical 0x8080) =====
    // Null descriptor
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 0x80
    // Code64 (selector 0x08): base=0 limit=0xFFFFF, L=1 D=0 P=1 DPL=0 exec/read
    0xFF, 0xFF, 0x00, 0x00, 0x00, 0x9A, 0xAF, 0x00, // 0x88
    // Data (selector 0x10): base=0 limit=0xFFFFF, G=1 DB=1 P=1 DPL=0 read/write
    0xFF, 0xFF, 0x00, 0x00, 0x00, 0x92, 0xCF, 0x00, // 0x90

    // ===== GDT pointer (physical 0x8098) =====
    0x17, 0x00, // limit = 23 (3*8-1)
    0x80, 0x80, 0x00, 0x00, // base = 0x00008080 (32-bit, used by 16-bit lgdt)
};

/// Copy trampoline to 0x8000 and patch data area for the given AP.
fn setupApTrampoline(stack_top: u64, entry: u64) void {
    // Read BSP's CR3
    const cr3: u64 = asm volatile ("mov %%cr3, %[cr3]"
        : [cr3] "=r" (-> u64),
    );

    // Copy trampoline code to physical 0x8000 (identity-mapped)
    const dest: [*]u8 = @ptrFromInt(TRAMPOLINE_BASE);
    for (trampoline_code, 0..) |b, i| {
        dest[i] = b;
    }

    // Patch data area at 0x80C0
    const data: [*]u8 = @ptrFromInt(TRAMPOLINE_BASE + DATA_CR3);
    // CR3 (u32 at offset 0xC0)
    const cr3_32: u32 = @truncate(cr3);
    data[0] = @truncate(cr3_32);
    data[1] = @truncate(cr3_32 >> 8);
    data[2] = @truncate(cr3_32 >> 16);
    data[3] = @truncate(cr3_32 >> 24);

    // Stack top (u64 at offset 0xC4)
    const stack_ptr: [*]u8 = @ptrFromInt(TRAMPOLINE_BASE + DATA_STACK_TOP);
    writeU64(stack_ptr, stack_top);

    // Entry point (u64 at offset 0xCC)
    const entry_ptr: [*]u8 = @ptrFromInt(TRAMPOLINE_BASE + DATA_ENTRY);
    writeU64(entry_ptr, entry);
}

fn writeU64(ptr: [*]u8, val: u64) void {
    ptr[0] = @truncate(val);
    ptr[1] = @truncate(val >> 8);
    ptr[2] = @truncate(val >> 16);
    ptr[3] = @truncate(val >> 24);
    ptr[4] = @truncate(val >> 32);
    ptr[5] = @truncate(val >> 40);
    ptr[6] = @truncate(val >> 48);
    ptr[7] = @truncate(val >> 56);
}

// ── AP Entry Point ─────────────────────────────────────────────────

/// AP entry point called from the trampoline. Runs on the AP's kernel stack.
export fn apEntry() callconv(.{ .x86_64_sysv = .{} }) noreturn {
    const core_id = @atomicLoad(u8, &ap_boot_core_id, .acquire);

    // Load BSP's GDT (replaces trampoline GDT) and IDT
    gdt.reloadGdtForAp();
    idt.reloadForAp();

    // Enable this AP's local APIC
    lapicWrite(LAPIC_SVR, SVR_ENABLE | SVR_SPURIOUS_VECTOR);
    lapicWrite(LAPIC_TPR, 0);

    // Set up per-CPU state
    percpu.percpu_array[core_id].core_id = core_id;
    percpu.percpu_array[core_id].online = true;

    // Set KERNEL_GS_BASE + GS_BASE for swapgs
    cpu.wrmsr(0xC0000102, @intFromPtr(&percpu.asm_states[core_id]));
    cpu.wrmsr(0xC0000101, @intFromPtr(&percpu.asm_states[core_id]));

    // Signal BSP that this AP is up
    @atomicStore(bool, &ap_boot_done, true, .release);

    // AP idle loop — Phase D will add run queue checking
    while (true) {
        asm volatile ("sti");
        asm volatile ("hlt");
        asm volatile ("cli");
    }
}

// ── INIT-SIPI-SIPI Sequence ────────────────────────────────────────

/// Busy-wait delay (approximate). Each iteration is ~1 cycle + pause overhead.
fn spinDelay(iterations: u32) void {
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        cpu.spinHint();
    }
}

/// Wait for ICR delivery (bit 12 = delivery status, 0 = idle).
fn waitIcrIdle() void {
    while (lapicRead(LAPIC_ICR_LO) & (1 << 12) != 0) {
        cpu.spinHint();
    }
}

/// Send INIT-SIPI-SIPI to the given LAPIC ID and wait for AP to signal boot.
fn bootAp(target_lapic_id: u8) bool {
    @atomicStore(bool, &ap_boot_done, false, .release);

    // INIT IPI (level assert)
    lapicWrite(LAPIC_ICR_HI, @as(u32, target_lapic_id) << 24);
    lapicWrite(LAPIC_ICR_LO, ICR_INIT | ICR_LEVEL_ASSERT);
    waitIcrIdle();

    // 10ms delay
    spinDelay(1_000_000);

    // INIT deassert
    lapicWrite(LAPIC_ICR_HI, @as(u32, target_lapic_id) << 24);
    lapicWrite(LAPIC_ICR_LO, ICR_INIT | ICR_LEVEL_DEASSERT);
    waitIcrIdle();

    // Send SIPI twice (Intel recommendation for reliability)
    for (0..2) |_| {
        spinDelay(10_000); // ~200µs delay

        lapicWrite(LAPIC_ICR_HI, @as(u32, target_lapic_id) << 24);
        lapicWrite(LAPIC_ICR_LO, ICR_STARTUP | @as(u32, SIPI_VECTOR));
        waitIcrIdle();
    }

    // Wait for AP to signal (with timeout)
    var timeout: u32 = 0;
    while (!@atomicLoad(bool, &ap_boot_done, .acquire)) {
        cpu.spinHint();
        timeout += 1;
        if (timeout > 100_000_000) return false; // ~1-2 seconds, give up
    }
    return true;
}

fn startAps() void {
    if (core_count <= 1) {
        klog.info("SMP: single core, no APs to start\n");
        return;
    }

    const entry_addr = @intFromPtr(&apEntry);

    // Boot each AP sequentially
    for (1..core_count) |i| {
        // Allocate 16 KB kernel stack (4 contiguous pages)
        const stack_page = pmm.allocPage() orelse {
            klog.err("SMP: failed to alloc AP kernel stack\n");
            return;
        };
        _ = pmm.allocPage() orelse return;
        _ = pmm.allocPage() orelse return;
        _ = pmm.allocPage() orelse return;
        const stack_top = stack_page + mem.KERNEL_VIRT_BASE + 4 * mem.PAGE_SIZE;
        percpu.asm_states[i].kernel_stack_top = stack_top;

        // Set core ID for this AP (read by apEntry)
        @atomicStore(u8, &ap_boot_core_id, @intCast(i), .release);

        // Set up trampoline with this AP's stack
        setupApTrampoline(stack_top, entry_addr);

        // Send INIT-SIPI-SIPI
        if (bootAp(lapic_ids[i])) {
            klog.info("SMP: Core ");
            klog.infoHex(i);
            klog.info(" online (LAPIC ");
            klog.infoHex(lapic_ids[i]);
            klog.info(")\n");
        } else {
            klog.err("SMP: Core ");
            klog.infoHex(i);
            klog.info(" failed to start\n");
        }
    }

    percpu.cores_online = core_count;
}

// ── Public init ─────────────────────────────────────────────────────

pub fn init(rsdp: ?[*]const u8) void {
    const rsdp_ptr = rsdp orelse {
        klog.info("ACPI: no RSDP, assuming single core\n");
        core_count = 1;
        lapic_ids[0] = 0;
        return;
    };

    if (!findMadt(rsdp_ptr)) {
        core_count = 1;
        return;
    }

    if (core_count == 0) {
        klog.err("ACPI: no processors found in MADT\n");
        core_count = 1;
        return;
    }

    // Initialize BSP LAPIC
    initLapic();

    // Start APs
    startAps();
}

// ── Helpers ─────────────────────────────────────────────────────────

fn eqlBytes(a: []const u8, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}
