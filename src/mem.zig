/// Memory layout constants for Fornax.
///
/// Virtual memory map (x86_64):
///   0x0000_0000_0000_0000 - 0x0000_7FFF_FFFF_FFFF : User space (128 TB)
///   0xFFFF_8000_0000_0000 - 0xFFFF_FFFF_FFFF_FFFF : Kernel space (128 TB)
///
/// Kernel higher-half starts at KERNEL_VIRT_BASE.
/// Physical memory is identity-mapped in the kernel half for easy access.
pub const PAGE_SIZE: usize = 4096;
pub const PAGE_SHIFT: u6 = 12;

/// Kernel virtual address base — physical address 0 maps here.
pub const KERNEL_VIRT_BASE: u64 = 0xFFFF_8000_0000_0000;

/// User stack top (grows down).
pub const USER_STACK_TOP: u64 = 0x0000_7FFF_FFF0_0000;

/// How much physical memory to map in the kernel half (4 GB).
pub const KERNEL_MAP_SIZE: u64 = 4 * 1024 * 1024 * 1024;

/// Convert a physical address to its kernel virtual address.
pub fn physToVirt(phys: u64) u64 {
    return phys + KERNEL_VIRT_BASE;
}

/// Convert a kernel virtual address back to physical.
pub fn virtToPhys(virt: u64) u64 {
    return virt - KERNEL_VIRT_BASE;
}
