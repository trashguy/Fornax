/// RISC-V 64-bit freestanding boot for Fornax.
///
/// Called from _start in entry.S after stack setup.
/// Replaces the UEFI boot path used on x86_64.
/// Board-specific addresses (RAM base, initrd) come from board/ config.
/// FDT overrides board defaults at runtime when available.
const serial = @import("../../serial.zig");
const pmm = @import("../../pmm.zig");
const heap = @import("../../heap.zig");
const klog = @import("../../klog.zig");
const initrd_mod = @import("../../initrd.zig");
const main = @import("../../main.zig");
const fdt = @import("fdt.zig");
const board = @import("board/board.zig");
const build_options = @import("build_options");

/// Default RAM base (board-specific, fallback if FDT parsing fails).
const RAM_BASE: u64 = board.active.ram_base;

/// Default RAM size (fallback if FDT parsing fails).
const RAM_SIZE: u64 = 256 * 1024 * 1024;

/// Reservation for OpenSBI + kernel + boot data (32 MB from RAM base).
const RESERVED_SIZE: u64 = 32 * 1024 * 1024;

/// Well-known initrd load address (board-specific).
const INITRD_ADDR: u64 = board.active.initrd_addr;

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

/// Boot hart ID — saved for SMP init so we know which hart is BSP.
pub var boot_hartid: u64 = 0;

/// FDT blob address — saved for later subsystem use.
pub var dtb_addr: u64 = 0;

/// Kernel entry point called from _start in entry.S.
/// a0 = hartid, a1 = FDT pointer (passed by OpenSBI).
export fn riscv64KernelMain(hartid: u64, dtb_ptr: u64) callconv(.c) noreturn {
    boot_hartid = hartid;
    dtb_addr = dtb_ptr;

    // Serial console first — earliest possible output
    serial.init();
    klog.console_level = .info;
    const board_name = switch (build_options.board) {
        .qemu_virt => "qemu-virt",
        .milkv_mars => "milkv-mars",
    };
    klog.info("\nFornax RISC-V booting (");
    klog.info(board_name);
    klog.info(")...\n");

    klog.info("Boot hart: ");
    klog.infoDec(hartid);
    klog.info(", FDT at ");
    klog.infoHex(dtb_ptr);
    klog.info("\n");

    // No framebuffer on riscv64 (serial-only mode).
    // Skip console.init() so console stays uninitialized — putChar
    // will output to serial only.

    // Full FDT probe — discovers RAM, UART, PLIC, CPUs, peripherals.
    // U-Boot `go` doesn't pass DTB in a1 (passes argv instead), so try
    // the board's fallback FDT address if the primary probe fails.
    var cfg = fdt.probe(dtb_ptr);
    if (!cfg.valid() and board.active.fdt_fallback_addr != 0) {
        klog.info("FDT: a1 invalid, trying fallback at ");
        klog.infoHex(board.active.fdt_fallback_addr);
        klog.info("\n");
        cfg = fdt.probe(board.active.fdt_fallback_addr);
    }

    // Detect RAM from FDT, fall back to hardcoded values
    var ram_base = RAM_BASE;
    var ram_size = RAM_SIZE;

    if (cfg.ram_count > 0) {
        ram_base = cfg.ram_regions[0].base;
        ram_size = cfg.ram_regions[0].size;
        klog.info("FDT: RAM at ");
        klog.infoHex(ram_base);
        klog.info(" size ");
        klog.infoDec(ram_size / (1024 * 1024));
        klog.info(" MB\n");
    } else {
        klog.warn("FDT: memory probe failed, using defaults (");
        klog.warnDec(RAM_SIZE / (1024 * 1024));
        klog.warn(" MB)\n");
    }

    // Log FDT discoveries
    if (cfg.valid()) {
        fdt.dumpConfig();
    }

    const reserved_end = ram_base + RESERVED_SIZE;
    pmm.initDirect(ram_base, ram_size, reserved_end);

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

        klog.info("Initrd found at ");
        klog.infoHex(INITRD_ADDR);
        klog.info("\n");
        main.kernelInit(initrd_ptr, initrd_size, null);
    } else {
        main.kernelInit(null, 0, null);
    }
}
