/// QEMU virt machine defaults for RISC-V 64-bit.
///
/// Memory map:
///   0x0C00_0000  PLIC
///   0x1000_0000  UART0 (16550)
///   0x3000_0000  PCI ECAM
///   0x8000_0000  RAM base (OpenSBI at 0x80000000, kernel at 0x80200000)

pub const uart_base: u64 = 0x1000_0000;
pub const uart_reg_shift: u5 = 0; // NS16550: 1-byte register spacing
pub const uart_irq: u32 = 10;
pub const plic_base: u64 = 0x0C00_0000;
pub const ecam_base: u64 = 0x3000_0000;
pub const timer_freq: u32 = 10_000_000; // 10 MHz
pub const excluded_harts: []const u8 = &.{};
pub const ram_base: u64 = 0x8000_0000;
pub const kernel_load_addr: u64 = 0x8020_0000;
pub const initrd_addr: u64 = 0x8400_0000;
pub const has_pci_ecam: bool = true;
pub const fdt_fallback_addr: u64 = 0; // Not needed for QEMU (OpenSBI passes DTB in a1)

/// PLIC S-mode context for a given hart.
/// QEMU virt: all harts have M+S contexts, so context = hart*2 + 1.
pub fn plicSContext(hartid: u64) u64 {
    return hartid * 2 + 1;
}
