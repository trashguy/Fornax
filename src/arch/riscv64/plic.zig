/// RISC-V PLIC (Platform-Level Interrupt Controller).
///
/// Base address comes from FDT discovery, with board config as fallback.
/// Context is computed at init() from the boot hart ID.
const klog = @import("../../klog.zig");
const mem = @import("../../mem.zig");
const paging = @import("paging.zig");
const board = @import("board/board.zig");
const fdt = @import("fdt.zig");

/// Effective PLIC base — set at init() from FDT or board fallback.
var plic_base: u64 = board.active.plic_base;

// Register base offsets (context-dependent offsets computed at runtime)
const PRIORITY_BASE: u64 = 0x0000_0000;

/// S-mode PLIC context for the boot hart, set during init().
var context: u64 = 1;

inline fn enableBase() u64 {
    return 0x0000_2000 + context * 0x80;
}

inline fn thresholdOff() u64 {
    return 0x0020_0000 + context * 0x1000;
}

inline fn claimOff() u64 {
    return 0x0020_0004 + context * 0x1000;
}

/// Get the effective PLIC address (higher-half after paging init).
inline fn plicAddr(offset: u64) u64 {
    const addr = plic_base + offset;
    return if (paging.isInitialized()) addr +% mem.KERNEL_VIRT_BASE else addr;
}

fn mmioRead32(addr: u64) u32 {
    return @as(*volatile u32, @ptrFromInt(addr)).*;
}

fn mmioWrite32(addr: u64, val: u32) void {
    @as(*volatile u32, @ptrFromInt(addr)).* = val;
}

/// Initialize PLIC: use FDT-discovered base (or board fallback),
/// compute context from boot hart, set threshold to 0.
pub fn init() void {
    const boot = @import("boot.zig");

    // Override with FDT-discovered address if available
    if (fdt.fdt_config.plic_base != 0) {
        plic_base = fdt.fdt_config.plic_base;
    }

    context = board.active.plicSContext(boot.boot_hartid);

    // Clear all interrupt enables left over from U-Boot.
    // Without this, stale enables (e.g. UART TX-empty, DW-MMC) flood
    // core 0 with external interrupts that starve the timer.
    // JH7110 has ~136 interrupt sources; clear 8 regs to cover 0-255.
    for (0..8) |i| {
        mmioWrite32(plicAddr(enableBase() + @as(u64, @intCast(i)) * 4), 0);
    }
    // Also clear enables for all AP contexts (harts 2-4 S-mode)
    for (1..5) |hart| {
        const ap_ctx = hart * 2;
        const ap_enable_base: u64 = 0x0000_2000 + ap_ctx * 0x80;
        for (0..8) |i| {
            mmioWrite32(plicAddr(ap_enable_base + @as(u64, @intCast(i)) * 4), 0);
        }
    }

    mmioWrite32(plicAddr(thresholdOff()), 0);
    klog.info("PLIC: initialized at ");
    klog.infoHex(plic_base);
    klog.info(" (context=");
    klog.infoDec(context);
    klog.info(", threshold=0)\n");
}

/// Enable an interrupt source and set its priority to 1.
pub fn enable(irq: u32) void {
    // Set priority to 1 (minimum non-zero)
    mmioWrite32(plicAddr(PRIORITY_BASE + irq * 4), 1);

    // Enable the interrupt for the boot hart's S-mode context
    const reg_offset = enableBase() + (irq / 32) * 4;
    const bit: u32 = @as(u32, 1) << @intCast(irq % 32);
    const current = mmioRead32(plicAddr(reg_offset));
    mmioWrite32(plicAddr(reg_offset), current | bit);
}

/// Claim the highest-priority pending interrupt. Returns the IRQ number (0 = none).
pub fn claim() u32 {
    return mmioRead32(plicAddr(claimOff()));
}

/// Complete (acknowledge) an interrupt.
pub fn complete(irq: u32) void {
    mmioWrite32(plicAddr(claimOff()), irq);
}
