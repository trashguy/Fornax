/// AArch64 GICv2 (Generic Interrupt Controller v2) for QEMU virt machine.
///
/// GICD (Distributor) at 0x0800_0000
/// GICC (CPU Interface) at 0x0801_0000
///
/// QEMU virt aarch64 GIC IRQs:
///   SGI 0-15    = Software Generated Interrupts
///   PPI 16-31   = Per-Processor Interrupts (timer = PPI 30)
///   SPI 32+     = Shared Peripheral Interrupts (UART0 = SPI 33)
const klog = @import("../../klog.zig");
const mem = @import("../../mem.zig");
const paging = @import("paging.zig");

const GICD_BASE: u64 = 0x0800_0000;
const GICC_BASE: u64 = 0x0801_0000;

// GICD registers
const GICD_CTLR: u64 = 0x000; // Distributor Control
const GICD_ISENABLER: u64 = 0x100; // Interrupt Set-Enable (32 bits per reg)
const GICD_IPRIORITYR: u64 = 0x400; // Interrupt Priority (8 bits per IRQ)
const GICD_ITARGETSR: u64 = 0x800; // Interrupt Target (8 bits per IRQ)
const GICD_SGIR: u64 = 0xF00; // Software Generated Interrupt Register

// GICC registers
const GICC_CTLR: u64 = 0x000; // CPU Interface Control
const GICC_PMR: u64 = 0x004; // Priority Mask
const GICC_IAR: u64 = 0x00C; // Interrupt Acknowledge
const GICC_EOIR: u64 = 0x010; // End of Interrupt

/// Get effective GICD address (higher-half after paging init).
inline fn gicdAddr(offset: u64) u64 {
    const addr = GICD_BASE + offset;
    return if (paging.isInitialized()) addr +% mem.KERNEL_VIRT_BASE else addr;
}

/// Get effective GICC address (higher-half after paging init).
inline fn giccAddr(offset: u64) u64 {
    const addr = GICC_BASE + offset;
    return if (paging.isInitialized()) addr +% mem.KERNEL_VIRT_BASE else addr;
}

fn mmioRead32(addr: u64) u32 {
    return @as(*volatile u32, @ptrFromInt(addr)).*;
}

fn mmioWrite32(addr: u64, val: u32) void {
    @as(*volatile u32, @ptrFromInt(addr)).* = val;
}

/// Initialize GICv2: enable distributor and CPU interface.
pub fn init() void {
    // Enable GICD
    mmioWrite32(gicdAddr(GICD_CTLR), 1);

    // Set priority mask to accept all priorities
    mmioWrite32(giccAddr(GICC_PMR), 0xFF);

    // Enable GICC
    mmioWrite32(giccAddr(GICC_CTLR), 1);

    klog.info("GIC: initialized (GICv2)\n");
}

/// Enable an interrupt and set its priority/target.
pub fn enable(irq: u32) void {
    // Set priority to 0xA0 (relatively low)
    const prio_offset = GICD_IPRIORITYR + irq;
    const prio_addr = gicdAddr(prio_offset & ~@as(u64, 3)); // align to word
    const prio_shift: u5 = @intCast((irq % 4) * 8);
    var prio_val = mmioRead32(prio_addr);
    prio_val &= ~(@as(u32, 0xFF) << prio_shift);
    prio_val |= @as(u32, 0xA0) << prio_shift;
    mmioWrite32(prio_addr, prio_val);

    // Set target to CPU 0 (for SPIs only; PPIs are per-CPU)
    if (irq >= 32) {
        const target_offset = GICD_ITARGETSR + irq;
        const target_addr = gicdAddr(target_offset & ~@as(u64, 3));
        const target_shift: u5 = @intCast((irq % 4) * 8);
        var target_val = mmioRead32(target_addr);
        target_val &= ~(@as(u32, 0xFF) << target_shift);
        target_val |= @as(u32, 0x01) << target_shift; // CPU 0
        mmioWrite32(target_addr, target_val);
    }

    // Enable the interrupt
    const reg_index = irq / 32;
    const bit: u32 = @as(u32, 1) << @intCast(irq % 32);
    mmioWrite32(gicdAddr(GICD_ISENABLER + reg_index * 4), bit);
}

/// Claim the highest-priority pending interrupt.
/// Returns IRQ number (1023 = spurious, no pending interrupt).
pub fn claim() u32 {
    return mmioRead32(giccAddr(GICC_IAR));
}

/// Complete (acknowledge) an interrupt.
/// For SGIs, the full IAR value (including source CPU bits [12:10]) must be passed.
pub fn complete(irq: u32) void {
    mmioWrite32(giccAddr(GICC_EOIR), irq);
}

/// Send a Software Generated Interrupt (SGI) to target CPUs.
/// sgi_id: SGI number (0-15), target_mask: bitmask of target CPUs (bit N = CPU N).
pub fn sendSgi(sgi_id: u4, target_mask: u8) void {
    // GICD_SGIR format:
    //   [3:0]   = SGIINTID (SGI number)
    //   [15:4]  = reserved
    //   [23:16] = CPUTargetList (bitmask)
    //   [25:24] = TargetListFilter (0b00 = use CPUTargetList)
    const val: u32 = @as(u32, sgi_id) |
        (@as(u32, target_mask) << 16) |
        (0b00 << 24); // TargetListFilter = use list
    mmioWrite32(gicdAddr(GICD_SGIR), val);
}

/// Initialize per-CPU GIC interface (for APs — distributor already init'd by BSP).
pub fn initCpuInterface() void {
    // Set priority mask to accept all priorities
    mmioWrite32(giccAddr(GICC_PMR), 0xFF);
    // Enable CPU interface
    mmioWrite32(giccAddr(GICC_CTLR), 1);
}

/// Enable timer PPI 30 for the calling core.
/// PPIs are per-CPU — each core must enable its own.
pub fn enableTimerPpi() void {
    // PPI 30 priority = 0xA0
    const prio_offset = GICD_IPRIORITYR + 30;
    const prio_addr = gicdAddr(prio_offset & ~@as(u64, 3));
    const prio_shift: u5 = @intCast((30 % 4) * 8);
    var prio_val = mmioRead32(prio_addr);
    prio_val &= ~(@as(u32, 0xFF) << prio_shift);
    prio_val |= @as(u32, 0xA0) << prio_shift;
    mmioWrite32(prio_addr, prio_val);

    // Enable PPI 30 (bit 30 in ISENABLER0)
    mmioWrite32(gicdAddr(GICD_ISENABLER), @as(u32, 1) << 30);
}
