/// AHCI (Advanced Host Controller Interface) SATA driver.
///
/// PCI class 0x01, subclass 0x06, prog_if 0x01 (AHCI 1.0).
/// Uses MMIO BAR5 ("ABAR") for register access. Single-port, polling-based I/O.
/// Provides readBlock/writeBlock for 4096-byte blocks (same API as nvme/virtio_blk).

const pmm = @import("pmm.zig");
const klog = @import("klog.zig");
const mem = @import("mem.zig");

const builtin = @import("builtin");

const paging = switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64/paging.zig"),
    .riscv64 => @import("arch/riscv64/paging.zig"),
    .aarch64 => @import("arch/aarch64/paging.zig"),
    else => struct {
        pub fn physPtr(_: u64) [*]u8 {
            return @ptrFromInt(0);
        }
        pub fn getKernelPml4() u64 {
            return 0;
        }
        pub fn getKernelRoot() u64 {
            return 0;
        }
        pub fn mapPage(_: u64, _: u64, _: u64, _: u64) ?u64 {
            return null;
        }
        pub const Flags = struct {
            pub const WRITABLE: u64 = 0;
            pub const NO_CACHE: u64 = 0;
        };
    },
};

const pci = switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64/pci.zig"),
    .riscv64 => @import("arch/riscv64/pci.zig"),
    .aarch64 => @import("arch/aarch64/pci.zig"),
    else => struct {
        pub const PciDevice = struct {
            pub fn memBase(_: *const @This(), _: u3) ?u64 {
                return null;
            }
        };
        pub fn findAhci() ?*PciDevice {
            return null;
        }
        pub fn enableBusMastering(_: *const PciDevice) void {}
    },
};

const cpu = switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64/cpu.zig"),
    .riscv64 => @import("arch/riscv64/cpu.zig"),
    .aarch64 => @import("arch/aarch64/cpu.zig"),
    else => struct {
        pub fn spinHint() void {}
    },
};

// ── AHCI Global Register Offsets (BAR5 MMIO — "ABAR") ─────────────────

const REG_CAP = 0x00; // Host Capabilities (u32)
const REG_GHC = 0x04; // Global Host Control (u32)
const REG_IS = 0x08; // Interrupt Status (u32)
const REG_PI = 0x0C; // Ports Implemented (u32)
const REG_VS = 0x10; // AHCI Version (u32)

// GHC register bits
const GHC_AE: u32 = 1 << 31; // AHCI Enable
const GHC_HR: u32 = 1 << 0; // HBA Reset

// ── Per-Port Register Offsets (base = ABAR + 0x100 + port × 0x80) ──────

const PORT_CLB = 0x00; // Command List Base Address (low 32)
const PORT_CLBU = 0x04; // Command List Base Address (high 32)
const PORT_FB = 0x08; // FIS Base Address (low 32)
const PORT_FBU = 0x0C; // FIS Base Address (high 32)
const PORT_IS = 0x10; // Interrupt Status
const PORT_IE = 0x14; // Interrupt Enable
const PORT_CMD = 0x18; // Command and Status
const PORT_TFD = 0x20; // Task File Data
const PORT_SIG = 0x24; // Signature
const PORT_SSTS = 0x28; // SATA Status (SCR0: SStatus)
const PORT_SERR = 0x30; // SATA Error (SCR1: SError)
const PORT_CI = 0x38; // Command Issue

// PxCMD bits
const CMD_ST: u32 = 1 << 0; // Start
const CMD_FRE: u32 = 1 << 4; // FIS Receive Enable
const CMD_FR: u32 = 1 << 14; // FIS Receive Running
const CMD_CR: u32 = 1 << 15; // Command List Running

// PxTFD bits
const TFD_BSY: u32 = 1 << 7; // Busy
const TFD_DRQ: u32 = 1 << 3; // Data Request
const TFD_ERR: u32 = 1 << 0; // Error

// PxSSTS DET field (bits 3:0)
const SSTS_DET_MASK: u32 = 0x0F;
const SSTS_DET_PRESENT: u32 = 3; // Device present + phy established

// PxSIG values
const SIG_SATA_DISK: u32 = 0x00000101;

// ── ATA Commands ───────────────────────────────────────────────────────

const ATA_IDENTIFY: u8 = 0xEC; // IDENTIFY DEVICE
const ATA_READ_DMA_EXT: u8 = 0x25; // READ DMA EXT (LBA48)
const ATA_WRITE_DMA_EXT: u8 = 0x35; // WRITE DMA EXT (LBA48)

// FIS types
const FIS_TYPE_H2D: u8 = 0x27; // Host to Device Register FIS

// ── DMA Structures (extern struct for hardware layout) ──────────────────

/// Command Header — 32 bytes each, 32 entries per command list (1 KB)
const CommandHeader = extern struct {
    /// Bits [4:0] = CFL (Command FIS Length in dwords)
    /// Bit 5 = A (ATAPI)
    /// Bit 6 = W (Write direction)
    /// Bit 7 = P (Prefetchable)
    /// Bits [15:8] = reserved
    flags: u16,
    /// Physical Region Descriptor Table Length (entries)
    prdtl: u16,
    /// Physical Region Descriptor Byte Count (updated by HBA)
    prdbc: u32,
    /// Command Table Descriptor Base Address (low)
    ctba: u32,
    /// Command Table Descriptor Base Address (high)
    ctbau: u32,
    /// Reserved
    _reserved: [4]u32,
};

/// PRDT Entry — 16 bytes
const PrdtEntry = extern struct {
    /// Data Base Address (low)
    dba: u32,
    /// Data Base Address (high)
    dbau: u32,
    /// Reserved
    _reserved: u32,
    /// Data Byte Count (0-based, bit 31 = Interrupt on Completion)
    dbc: u32,
};

/// Command Table — 128 bytes header + PRDT entries
/// CFIS: 64 bytes, ACMD: 16 bytes, reserved: 48 bytes, then PRDT[]
const COMMAND_TABLE_HEADER_SIZE = 128;

/// Host-to-Device Register FIS (20 bytes, padded to 64 in command table)
const FisH2D = extern struct {
    fis_type: u8, // 0x27
    flags: u8, // Bit 7 = C (command), bits [3:0] = PM port
    command: u8, // ATA command
    features_lo: u8,
    lba0: u8, // LBA [7:0]
    lba1: u8, // LBA [15:8]
    lba2: u8, // LBA [23:16]
    device: u8, // Device register (0x40 = LBA mode)
    lba3: u8, // LBA [31:24]
    lba4: u8, // LBA [39:32]
    lba5: u8, // LBA [47:40]
    features_hi: u8,
    count_lo: u8, // Sector count [7:0]
    count_hi: u8, // Sector count [15:8]
    icc: u8, // Isochronous Command Completion
    control: u8,
    _reserved: [4]u8,
};

// ── Port State ──────────────────────────────────────────────────────────

const Port = struct {
    mmio_base: u64, // ABAR + 0x100 + port*0x80
    clb_phys: u64, // command list base (1 page, 32 headers × 32B = 1KB)
    fb_phys: u64, // FIS receive base (1 page, 256B)
    ctba_phys: u64, // command table (1 page, covers slot 0 only)
    capacity_sectors: u64, // from IDENTIFY DEVICE (512-byte sectors)
    active: bool,
};

// ── Module State ────────────────────────────────────────────────────────

var abar: u64 = 0; // AHCI BAR5 base address
var port: Port = .{
    .mmio_base = 0,
    .clb_phys = 0,
    .fb_phys = 0,
    .ctba_phys = 0,
    .capacity_sectors = 0,
    .active = false,
};
var initialized: bool = false;

// ── MMIO Helpers (inline asm on x86_64, direct volatile on riscv64) ────

fn mmioRead32(addr: u64) u32 {
    if (comptime builtin.cpu.arch == .x86_64) {
        const virt: usize = @intFromPtr(paging.physPtr(addr));
        var result: u32 = undefined;
        asm volatile ("movl (%[addr]), %[result]"
            : [result] "=r" (result),
            : [addr] "r" (virt),
            : .{.memory = true});
        return result;
    } else {
        return cpu.mmioRead32(addr);
    }
}

fn mmioWrite32(addr: u64, val: u32) void {
    if (comptime builtin.cpu.arch == .x86_64) {
        const virt: usize = @intFromPtr(paging.physPtr(addr));
        asm volatile ("movl %[val], (%[addr])"
            :
            : [val] "r" (val), [addr] "r" (virt),
            : .{.memory = true});
    } else {
        cpu.mmioWrite32(addr, val);
    }
}

fn mapMmioRegion(phys_base: u64, size: u64) bool {
    const kernel_root = if (comptime builtin.cpu.arch == .x86_64)
        paging.getKernelPml4()
    else if (comptime builtin.cpu.arch == .riscv64)
        paging.getKernelRoot()
    else
        return false;
    const flags = paging.Flags.WRITABLE | if (comptime @hasDecl(paging.Flags, "NO_CACHE")) paging.Flags.NO_CACHE else 0;
    const page_size: u64 = 4096;
    var offset: u64 = 0;
    while (offset < size) : (offset += page_size) {
        const phys = (phys_base + offset) & ~@as(u64, 0xFFF);
        const virt = phys +% mem.KERNEL_VIRT_BASE;
        paging.mapPage(kernel_root, virt, phys, flags) orelse {
            return false;
        };
    }
    return true;
}

fn zeroPage(phys: u64) void {
    const ptr: [*]u8 = paging.physPtr(phys);
    @memset(ptr[0..4096], 0);
}

// ── Port Helpers ────────────────────────────────────────────────────────

fn portBase(port_num: u5) u64 {
    return abar + 0x100 + @as(u64, port_num) * 0x80;
}

/// Stop command engine on a port (clear ST and FRE, wait for CR and FR to clear).
fn stopPort(base: u64) bool {
    var cmd = mmioRead32(base + PORT_CMD);

    // Clear ST (Stop command list processing)
    cmd &= ~CMD_ST;
    mmioWrite32(base + PORT_CMD, cmd);

    // Wait for CR (Command list Running) to clear
    var spins: u32 = 0;
    while (mmioRead32(base + PORT_CMD) & CMD_CR != 0) : (spins += 1) {
        if (spins > 1_000_000) {
            klog.err("ahci: timeout waiting for CR clear\n");
            return false;
        }
        cpu.spinHint();
    }

    // Clear FRE (FIS Receive Enable)
    cmd = mmioRead32(base + PORT_CMD);
    cmd &= ~CMD_FRE;
    mmioWrite32(base + PORT_CMD, cmd);

    // Wait for FR (FIS Receive Running) to clear
    spins = 0;
    while (mmioRead32(base + PORT_CMD) & CMD_FR != 0) : (spins += 1) {
        if (spins > 1_000_000) {
            klog.err("ahci: timeout waiting for FR clear\n");
            return false;
        }
        cpu.spinHint();
    }

    return true;
}

/// Start command engine on a port (set FRE then ST).
fn startPort(base: u64) void {
    // Wait for BSY and DRQ to clear before starting
    var spins: u32 = 0;
    while (mmioRead32(base + PORT_TFD) & (TFD_BSY | TFD_DRQ) != 0) : (spins += 1) {
        if (spins > 1_000_000) break;
        cpu.spinHint();
    }

    var cmd = mmioRead32(base + PORT_CMD);
    cmd |= CMD_FRE;
    mmioWrite32(base + PORT_CMD, cmd);
    cmd |= CMD_ST;
    mmioWrite32(base + PORT_CMD, cmd);
}

/// Issue a command in slot 0 and wait for completion.
fn issueCommand(base: u64) bool {
    // Barrier: ensure command header + table writes are visible before CI
    // (see docs/aarch64-gotchas.md §3)
    if (comptime builtin.cpu.arch == .aarch64) {
        asm volatile ("dsb sy" ::: .{ .memory = true });
    } else if (comptime builtin.cpu.arch == .riscv64) {
        asm volatile ("fence rw, rw" ::: .{ .memory = true });
    }

    // Set CI bit 0
    mmioWrite32(base + PORT_CI, 1);

    // Poll until CI bit 0 clears (command complete) or error
    var spins: u32 = 0;
    while (mmioRead32(base + PORT_CI) & 1 != 0) : (spins += 1) {
        if (spins > 50_000_000) {
            klog.err("ahci: command timeout\n");
            return false;
        }
        // Check for error
        const tfd = mmioRead32(base + PORT_TFD);
        if (tfd & TFD_ERR != 0) {
            klog.err("ahci: task file error 0x");
            klog.errHex(@as(u64, tfd));
            klog.err("\n");
            return false;
        }
        cpu.spinHint();
    }

    // Final error check
    const tfd = mmioRead32(base + PORT_TFD);
    if (tfd & (TFD_ERR | TFD_BSY) != 0) {
        klog.err("ahci: command completed with error TFD=0x");
        klog.errHex(@as(u64, tfd));
        klog.err("\n");
        return false;
    }

    return true;
}

/// Build an H2D Register FIS in the command table's CFIS area.
fn buildH2dFis(ctba_virt: [*]u8, command: u8, lba: u48, count: u16) void {
    // Zero the CFIS area (64 bytes)
    @memset(ctba_virt[0..64], 0);

    // FIS H2D is 20 bytes at offset 0 of command table
    ctba_virt[0] = FIS_TYPE_H2D; // FIS type
    ctba_virt[1] = 0x80; // C=1 (command register update)
    ctba_virt[2] = command; // Command
    ctba_virt[3] = 0; // Features low

    // LBA bytes
    ctba_virt[4] = @truncate(lba); // LBA [7:0]
    ctba_virt[5] = @truncate(lba >> 8); // LBA [15:8]
    ctba_virt[6] = @truncate(lba >> 16); // LBA [23:16]
    ctba_virt[7] = 0x40; // Device: LBA mode
    ctba_virt[8] = @truncate(lba >> 24); // LBA [31:24]
    ctba_virt[9] = @truncate(lba >> 32); // LBA [39:32]
    ctba_virt[10] = @truncate(lba >> 40); // LBA [47:40]
    ctba_virt[11] = 0; // Features high

    // Sector count
    ctba_virt[12] = @truncate(count); // Count [7:0]
    ctba_virt[13] = @truncate(count >> 8); // Count [15:8]
}

/// Set up command header slot 0 and PRDT for a single-page transfer.
fn setupCommand(data_phys: u64, byte_count: u32, is_write: bool) void {
    const clb_virt: [*]u8 = paging.physPtr(port.clb_phys);
    const ctba_virt: [*]u8 = paging.physPtr(port.ctba_phys);

    // Zero command header slot 0 (32 bytes)
    @memset(clb_virt[0..32], 0);

    // Command header flags:
    // CFL = 5 dwords (20 bytes for H2D FIS)
    // W bit (bit 6) for write direction
    var flags: u16 = 5; // CFL = 5
    if (is_write) flags |= (1 << 6); // W bit

    // Write flags
    clb_virt[0] = @truncate(flags);
    clb_virt[1] = @truncate(flags >> 8);

    // PRDTL = 1 (one PRDT entry)
    clb_virt[2] = 1;
    clb_virt[3] = 0;

    // PRDBC = 0 (cleared, HBA updates this)
    @memset(clb_virt[4..8], 0);

    // CTBA = command table physical address
    clb_virt[8] = @truncate(port.ctba_phys);
    clb_virt[9] = @truncate(port.ctba_phys >> 8);
    clb_virt[10] = @truncate(port.ctba_phys >> 16);
    clb_virt[11] = @truncate(port.ctba_phys >> 24);
    // CTBAU (high 32 bits)
    clb_virt[12] = @truncate(port.ctba_phys >> 32);
    clb_virt[13] = @truncate(port.ctba_phys >> 40);
    clb_virt[14] = @truncate(port.ctba_phys >> 48);
    clb_virt[15] = @truncate(port.ctba_phys >> 56);

    // Set up PRDT entry at offset 128 in command table
    // (CFIS 64B + ACMD 16B + reserved 48B = 128B)
    const prdt_offset: usize = COMMAND_TABLE_HEADER_SIZE;
    @memset(ctba_virt[prdt_offset..][0..16], 0);

    // DBA (low)
    ctba_virt[prdt_offset + 0] = @truncate(data_phys);
    ctba_virt[prdt_offset + 1] = @truncate(data_phys >> 8);
    ctba_virt[prdt_offset + 2] = @truncate(data_phys >> 16);
    ctba_virt[prdt_offset + 3] = @truncate(data_phys >> 24);
    // DBAU (high)
    ctba_virt[prdt_offset + 4] = @truncate(data_phys >> 32);
    ctba_virt[prdt_offset + 5] = @truncate(data_phys >> 40);
    ctba_virt[prdt_offset + 6] = @truncate(data_phys >> 48);
    ctba_virt[prdt_offset + 7] = @truncate(data_phys >> 56);

    // DBC = byte_count - 1 (0-based), bit 31 = 0 (no interrupt)
    const dbc = byte_count - 1;
    ctba_virt[prdt_offset + 12] = @truncate(dbc);
    ctba_virt[prdt_offset + 13] = @truncate(dbc >> 8);
    ctba_virt[prdt_offset + 14] = @truncate(dbc >> 16);
    ctba_virt[prdt_offset + 15] = @truncate(dbc >> 24);
}

// ── Public API ──────────────────────────────────────────────────────────

pub fn init() bool {
    if (builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .riscv64 and builtin.cpu.arch != .aarch64) return false;

    const dev = pci.findAhci() orelse {
        klog.debug("ahci: no controller found\n");
        return false;
    };

    klog.info("ahci: found at PCI ");
    klog.infoDec(dev.bus);
    klog.info(":");
    klog.infoDec(dev.slot);
    klog.info(".");
    klog.infoDec(dev.func);
    klog.info("\n");

    // Enable bus mastering + memory space
    pci.enableBusMastering(dev);

    // Read BAR5 (ABAR — AHCI Base Memory Register)
    abar = dev.memBase(5) orelse {
        klog.err("ahci: BAR5 not memory-mapped\n");
        return false;
    };

    // Map MMIO region if above 4 GB
    if (abar >= 0x1_0000_0000) {
        if (!mapMmioRegion(abar, 0x1100)) { // 0x100 global + 32 ports × 0x80
            klog.err("ahci: failed to map MMIO region\n");
            return false;
        }
    }

    // Enable AHCI mode
    var ghc = mmioRead32(abar + REG_GHC);
    ghc |= GHC_AE;
    mmioWrite32(abar + REG_GHC, ghc);

    // Read version
    const vs = mmioRead32(abar + REG_VS);
    klog.info("ahci: version ");
    klog.infoDec((vs >> 16) & 0xFFFF);
    klog.info(".");
    klog.infoDec(vs & 0xFFFF);
    klog.info("\n");

    // Read ports implemented bitmask
    const pi = mmioRead32(abar + REG_PI);
    if (pi == 0) {
        klog.err("ahci: no ports implemented\n");
        return false;
    }

    // Scan for first SATA disk
    var found = false;
    for (0..32) |port_idx| {
        const port_num: u5 = @intCast(port_idx);
        if (pi & (@as(u32, 1) << port_num) == 0) continue;

        const base = portBase(port_num);

        // Check SATA status — DET field must be 3 (device present + phy)
        const ssts = mmioRead32(base + PORT_SSTS);
        if (ssts & SSTS_DET_MASK != SSTS_DET_PRESENT) continue;

        // Check signature for SATA disk
        const sig = mmioRead32(base + PORT_SIG);
        if (sig != SIG_SATA_DISK) {
            klog.debug("ahci: port ");
            klog.debugDec(port_num);
            klog.debug(" sig=0x");
            klog.debugHex(@as(u64, sig));
            klog.debug(" (not SATA disk)\n");
            continue;
        }

        klog.info("ahci: SATA disk on port ");
        klog.infoDec(port_num);
        klog.info("\n");

        // Stop port command engine
        if (!stopPort(base)) continue;

        // Allocate DMA pages
        const clb_phys = pmm.allocPage() orelse {
            klog.err("ahci: OOM CLB\n");
            return false;
        };
        const fb_phys = pmm.allocPage() orelse {
            klog.err("ahci: OOM FB\n");
            pmm.freePage(clb_phys);
            return false;
        };
        const ctba_phys = pmm.allocPage() orelse {
            klog.err("ahci: OOM CTBA\n");
            pmm.freePage(clb_phys);
            pmm.freePage(fb_phys);
            return false;
        };

        zeroPage(clb_phys);
        zeroPage(fb_phys);
        zeroPage(ctba_phys);

        // Write Command List Base Address (PxCLB/PxCLBU)
        mmioWrite32(base + PORT_CLB, @truncate(clb_phys));
        mmioWrite32(base + PORT_CLBU, @truncate(clb_phys >> 32));

        // Write FIS Base Address (PxFB/PxFBU)
        mmioWrite32(base + PORT_FB, @truncate(fb_phys));
        mmioWrite32(base + PORT_FBU, @truncate(fb_phys >> 32));

        // Clear SATA error register (write all 1s to clear)
        mmioWrite32(base + PORT_SERR, 0xFFFFFFFF);

        // Clear port interrupt status
        mmioWrite32(base + PORT_IS, 0xFFFFFFFF);

        // Start port
        startPort(base);

        // Save port state
        port = .{
            .mmio_base = base,
            .clb_phys = clb_phys,
            .fb_phys = fb_phys,
            .ctba_phys = ctba_phys,
            .capacity_sectors = 0,
            .active = true,
        };

        // Issue IDENTIFY DEVICE
        const id_phys = pmm.allocPage() orelse {
            klog.err("ahci: OOM identify\n");
            return false;
        };
        zeroPage(id_phys);

        // Set up command: IDENTIFY DEVICE, 512 bytes, read direction
        const ctba_virt: [*]u8 = paging.physPtr(ctba_phys);
        buildH2dFis(ctba_virt, ATA_IDENTIFY, 0, 0);
        setupCommand(id_phys, 512, false);

        if (!issueCommand(base)) {
            klog.err("ahci: IDENTIFY DEVICE failed\n");
            pmm.freePage(id_phys);
            return false;
        }

        // Parse IDENTIFY DEVICE data (512 bytes)
        const id_ptr: [*]const u8 = paging.physPtr(id_phys);

        // Check LBA48 support: word 83, bit 10
        const word83 = readU16LE(id_ptr[166..168]);
        if (word83 & (1 << 10) == 0) {
            klog.err("ahci: device does not support LBA48\n");
            pmm.freePage(id_phys);
            return false;
        }

        // LBA48 capacity at words 100-103 (u64, little-endian)
        const cap_lo: u64 = readU16LE(id_ptr[200..202]);
        const cap_mid1: u64 = readU16LE(id_ptr[202..204]);
        const cap_mid2: u64 = readU16LE(id_ptr[204..206]);
        const cap_hi: u64 = readU16LE(id_ptr[206..208]);
        port.capacity_sectors = cap_lo | (cap_mid1 << 16) | (cap_mid2 << 32) | (cap_hi << 48);

        pmm.freePage(id_phys);

        const mb = (port.capacity_sectors * 512) / (1024 * 1024);
        klog.info("ahci: ");
        klog.infoDec(port.capacity_sectors);
        klog.info(" sectors, ");
        klog.infoDec(mb);
        klog.info(" MB\n");

        found = true;
        break;
    }

    if (!found) {
        klog.debug("ahci: no SATA disk found\n");
        return false;
    }

    klog.info("ahci: ready\n");
    initialized = true;
    return true;
}

pub fn readBlock(block: u64, buf: *[4096]u8) bool {
    if (!initialized) return false;
    if (!port.active) return false;

    const capacity_blocks = (port.capacity_sectors * 512) / 4096;
    if (block >= capacity_blocks) return false;

    // Allocate DMA page
    const data_phys = pmm.allocPage() orelse {
        klog.err("ahci: read OOM blk=");
        klog.errDec(block);
        klog.err("\n");
        return false;
    };
    zeroPage(data_phys);

    // Convert 4096-byte block to 512-byte sector LBA
    const lba: u48 = @truncate(block * 8);
    const sector_count: u16 = 8; // 4096 / 512

    // Build command
    const ctba_virt: [*]u8 = paging.physPtr(port.ctba_phys);
    buildH2dFis(ctba_virt, ATA_READ_DMA_EXT, lba, sector_count);
    setupCommand(data_phys, 4096, false);

    if (!issueCommand(port.mmio_base)) {
        pmm.freePage(data_phys);
        return false;
    }

    // Copy DMA buffer to caller
    const data_ptr: [*]u8 = paging.physPtr(data_phys);
    @memcpy(buf, data_ptr[0..4096]);
    pmm.freePage(data_phys);
    return true;
}

pub fn writeBlock(block: u64, buf: *const [4096]u8) bool {
    if (!initialized) return false;
    if (!port.active) return false;

    const capacity_blocks = (port.capacity_sectors * 512) / 4096;
    if (block >= capacity_blocks) return false;

    // Allocate DMA page
    const data_phys = pmm.allocPage() orelse {
        klog.err("ahci: write OOM blk=");
        klog.errDec(block);
        klog.err("\n");
        return false;
    };

    // Copy caller data to DMA buffer
    const data_ptr: [*]u8 = paging.physPtr(data_phys);
    @memcpy(data_ptr[0..4096], buf);

    // Convert 4096-byte block to 512-byte sector LBA
    const lba: u48 = @truncate(block * 8);
    const sector_count: u16 = 8;

    // Build command
    const ctba_virt: [*]u8 = paging.physPtr(port.ctba_phys);
    buildH2dFis(ctba_virt, ATA_WRITE_DMA_EXT, lba, sector_count);
    setupCommand(data_phys, 4096, true);

    if (!issueCommand(port.mmio_base)) {
        pmm.freePage(data_phys);
        return false;
    }

    pmm.freePage(data_phys);
    return true;
}

pub fn isInitialized() bool {
    return initialized;
}

pub fn getCapacitySectors() u64 {
    return port.capacity_sectors;
}

pub fn getCapacityBlocks() u64 {
    return (port.capacity_sectors * 512) / 4096;
}

// ── Utility ─────────────────────────────────────────────────────────────

fn readU16LE(data: *const [2]u8) u16 {
    return @as(u16, data[0]) | (@as(u16, data[1]) << 8);
}
