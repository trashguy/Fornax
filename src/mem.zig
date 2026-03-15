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
/// x86_64/aarch64: Sv48-canonical (bit 47 sign-extended).
/// riscv64: Sv39-canonical (bit 38 sign-extended) — Sv48 not available on all hardware.
pub const KERNEL_VIRT_BASE: u64 = switch (@import("builtin").cpu.arch) {
    .riscv64 => 0xFFFF_FFC0_0000_0000,
    else => 0xFFFF_8000_0000_0000,
};

/// User stack top (grows down).
/// riscv64 Sv39: user half is 0-256 GB, so stack must be below 0x40_0000_0000.
pub const USER_STACK_TOP: u64 = switch (@import("builtin").cpu.arch) {
    .riscv64 => 0x0000_003F_FFF0_0000,
    else => 0x0000_7FFF_FFF0_0000,
};

/// Initial user SP:
/// x86_64:  RSP ≡ 8 (mod 16) at function entry (as if `call` pushed RA) → TOP - 8
/// riscv64: SP ≡ 0 (mod 16) at function entry → TOP
pub const USER_STACK_INIT: u64 = switch (@import("builtin").cpu.arch) {
    .riscv64, .aarch64 => USER_STACK_TOP, // SP mod 16 == 0 at function entry
    else => USER_STACK_TOP - 8, // x86_64: RSP mod 16 == 8 at function entry
};

/// Base address for argv layout (one page below USER_STACK_TOP).
/// Layout at ARGV_BASE: [argc: u64][argv[0]: ptr][argv[1]: ptr]...[str0\0str1\0...]
/// Stack pointer is set to ARGV_BASE - 8, so program stack grows down from here.
pub const ARGV_BASE: u64 = USER_STACK_TOP - PAGE_SIZE;

/// Base address for auxiliary vector (one page below ARGV_BASE).
/// Used by POSIX programs for AT_PHDR, AT_PHNUM, etc.
pub const AUXV_BASE: u64 = ARGV_BASE - PAGE_SIZE;

/// How much physical memory to map in the kernel half.
/// AArch64 QEMU virt: RAM starts at 0x4000_0000, so 4 GB of RAM occupies
/// physical addresses up to 0x1_4000_0000 — requiring an 8 GB map.
/// x86_64 and riscv64 RAM starts near 0, so 4 GB suffices.
pub const KERNEL_MAP_SIZE: u64 = if (@import("builtin").cpu.arch == .aarch64)
    8 * 1024 * 1024 * 1024
else
    4 * 1024 * 1024 * 1024;

/// Convert a physical address to its kernel virtual address.
pub fn physToVirt(phys: u64) u64 {
    return phys + KERNEL_VIRT_BASE;
}

/// Convert a kernel virtual address back to physical.
pub fn virtToPhys(virt: u64) u64 {
    return virt - KERNEL_VIRT_BASE;
}
