/// Milk-V Mars (StarFive JH7110) board constants.
///
/// JH7110 SoC: 4x U74 application cores (harts 1-4) + 1x S7 monitor (hart 0).
/// DDR at 0x40000000. PLIC at 0x0C000000. UART0 at 0x10000000.
/// PCIe via PLDA controller (no raw ECAM — requires phase 4006).

pub const uart_base: u64 = 0x1000_0000;
pub const uart_reg_shift: u5 = 2; // DW APB UART: 4-byte register spacing
pub const uart_irq: u32 = 32; // JH7110 UART0 PLIC IRQ
pub const plic_base: u64 = 0x0C00_0000;
pub const ecam_base: u64 = 0; // PLDA PCIe, not raw ECAM
pub const timer_freq: u32 = 4_000_000; // 4 MHz
pub const excluded_harts: []const u8 = &.{0}; // S7 monitor core
pub const ram_base: u64 = 0x4000_0000;
pub const kernel_load_addr: u64 = 0x4020_0000;
pub const initrd_addr: u64 = 0x4400_0000;
pub const has_pci_ecam: bool = false;
pub const fdt_fallback_addr: u64 = 0x4600_0000; // U-Boot `fdt move` target

/// PLIC S-mode context for a given hart.
/// JH7110: hart 0 (S7) has only an M-mode context, so subsequent harts'
/// S-mode contexts are at hart*2 instead of hart*2+1.
pub fn plicSContext(hartid: u64) u64 {
    return hartid * 2;
}
