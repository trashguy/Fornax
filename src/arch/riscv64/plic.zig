/// RISC-V PLIC (Platform-Level Interrupt Controller) for QEMU virt machine.
///
/// PLIC base address: 0x0C000000
/// Context 1 = S-mode, hart 0
///
/// QEMU virt PLIC IRQs:
///   1-8   = virtio devices
///   10    = UART0
const klog = @import("../../klog.zig");
const mem = @import("../../mem.zig");
const paging = @import("paging.zig");

const PLIC_BASE: u64 = 0x0C00_0000;

// Context 1 = S-mode hart 0
const CONTEXT: u64 = 1;

// Register offsets
const PRIORITY_BASE: u64 = 0x0000_0000;
const ENABLE_BASE: u64 = 0x0000_2000 + CONTEXT * 0x80;
const THRESHOLD_OFF: u64 = 0x0020_0000 + CONTEXT * 0x1000;
const CLAIM_OFF: u64 = 0x0020_0004 + CONTEXT * 0x1000;

/// Get the effective PLIC address (higher-half after paging init).
inline fn plicAddr(offset: u64) u64 {
    const addr = PLIC_BASE + offset;
    return if (paging.isInitialized()) addr +% mem.KERNEL_VIRT_BASE else addr;
}

fn mmioRead32(addr: u64) u32 {
    return @as(*volatile u32, @ptrFromInt(addr)).*;
}

fn mmioWrite32(addr: u64, val: u32) void {
    @as(*volatile u32, @ptrFromInt(addr)).* = val;
}

/// Initialize PLIC: set threshold to 0 (accept all priorities).
pub fn init() void {
    mmioWrite32(plicAddr(THRESHOLD_OFF), 0);
    klog.info("PLIC: initialized (threshold=0)\n");
}

/// Enable an interrupt source and set its priority to 1.
pub fn enable(irq: u32) void {
    // Set priority to 1 (minimum non-zero)
    mmioWrite32(plicAddr(PRIORITY_BASE + irq * 4), 1);

    // Enable the interrupt for context 1
    const reg_offset = ENABLE_BASE + (irq / 32) * 4;
    const bit: u32 = @as(u32, 1) << @intCast(irq % 32);
    const current = mmioRead32(plicAddr(reg_offset));
    mmioWrite32(plicAddr(reg_offset), current | bit);
}

/// Claim the highest-priority pending interrupt. Returns the IRQ number (0 = none).
pub fn claim() u32 {
    return mmioRead32(plicAddr(CLAIM_OFF));
}

/// Complete (acknowledge) an interrupt.
pub fn complete(irq: u32) void {
    mmioWrite32(plicAddr(CLAIM_OFF), irq);
}
