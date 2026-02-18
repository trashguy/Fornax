/// RISC-V 64-bit freestanding boot for Fornax.
///
/// Called from _start in entry.S after stack setup.
/// Replaces the UEFI boot path used on x86_64.
///
/// QEMU virt memory layout:
///   0x0200_0000  CLINT
///   0x0300_0000  PCI I/O window (64 KB)
///   0x0C00_0000  PLIC
///   0x1000_0000  UART0
///   0x3000_0000  PCI ECAM
///   0x8000_0000  RAM base (OpenSBI at 0x80000000, kernel loaded at 0x80200000)
const serial = @import("../../serial.zig");
const pmm = @import("../../pmm.zig");
const heap = @import("../../heap.zig");
const klog = @import("../../klog.zig");
const initrd_mod = @import("../../initrd.zig");
const main = @import("../../main.zig");

/// QEMU virt: RAM starts at 0x80000000 (2 GiB).
const RAM_BASE: u64 = 0x8000_0000;

/// Default RAM size (matches QEMU -m 256M).
const RAM_SIZE: u64 = 256 * 1024 * 1024;

/// Reserve first 32 MB for OpenSBI + kernel + boot data.
const RESERVED_END: u64 = RAM_BASE + 32 * 1024 * 1024;

/// Well-known initrd load address. QEMU script uses:
///   -device loader,file=INITRD,addr=0x8400_0000,force-raw=on
const INITRD_ADDR: u64 = 0x8400_0000;

/// 16 KB kernel boot stack (BSS).
const BOOT_STACK_SIZE = 16 * 1024;
export var __boot_stack: [BOOT_STACK_SIZE]u8 align(16) linksection(".bss") = undefined;

comptime {
    // Export the stack top symbol for entry.S
    asm (
        \\.global __boot_stack_top
        \\__boot_stack_top = __boot_stack + 16384
    );
}

/// Kernel entry point called from _start in entry.S.
/// a0 = hartid, a1 = FDT pointer (currently unused).
export fn riscv64KernelMain(_: u64, _: u64) callconv(.c) noreturn {
    // Serial console first — earliest possible output
    serial.init();
    klog.console_level = .info;
    klog.info("Fornax RISC-V booting...\n");

    // No framebuffer on riscv64 (serial-only mode).
    // Skip console.init() so console stays uninitialized — putChar
    // will output to serial only.

    // Physical memory manager from hardcoded QEMU virt layout
    pmm.initDirect(RAM_BASE, RAM_SIZE, RESERVED_END);

    // Kernel heap
    heap.init();

    // Probe for initrd at well-known address (loaded by QEMU -device loader)
    const initrd_ptr: [*]const u8 = @ptrFromInt(INITRD_ADDR);
    const magic = "FXINITRD";
    var has_initrd = true;
    for (magic, 0..) |expected, i| {
        if (initrd_ptr[i] != expected) {
            has_initrd = false;
            break;
        }
    }

    if (has_initrd) {
        // INITRD format: 8-byte magic + 4-byte LE count + entries + data
        // Entry = name(64) + offset(u32) + size(u32) = 72 bytes
        // Compute total size from entry table: max(entry.offset + entry.size)
        const count_bytes = initrd_ptr[8..12];
        const count: u32 = @as(u32, count_bytes[0]) |
            (@as(u32, count_bytes[1]) << 8) |
            (@as(u32, count_bytes[2]) << 16) |
            (@as(u32, count_bytes[3]) << 24);

        const entry_size: usize = 72; // sizeof(Entry) = 64 + 4 + 4
        const header_size: usize = 12 + @as(usize, count) * entry_size;

        // Scan entries to find max(offset + size) = total image size
        var initrd_size: usize = header_size;
        for (0..count) |i| {
            const entry_base = 12 + i * entry_size;
            // offset is at entry_base + 64 (after name), size at entry_base + 68
            const off_ptr = initrd_ptr[entry_base + 64 .. entry_base + 68];
            const sz_ptr = initrd_ptr[entry_base + 68 .. entry_base + 72];
            const off: u32 = @as(u32, off_ptr[0]) |
                (@as(u32, off_ptr[1]) << 8) |
                (@as(u32, off_ptr[2]) << 16) |
                (@as(u32, off_ptr[3]) << 24);
            const sz: u32 = @as(u32, sz_ptr[0]) |
                (@as(u32, sz_ptr[1]) << 8) |
                (@as(u32, sz_ptr[2]) << 16) |
                (@as(u32, sz_ptr[3]) << 24);
            const end: usize = @as(usize, off) + @as(usize, sz);
            if (end > initrd_size) initrd_size = end;
        }

        klog.info("Initrd found at 0x84000000\n");
        main.kernelInit(initrd_ptr, initrd_size, null);
    } else {
        main.kernelInit(null, 0, null);
    }
}
