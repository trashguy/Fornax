/// DesignWare MMC Host Controller driver (DW-MMC / DWMCI).
///
/// Drives the microSD slot on JH7110-based boards (Milk-V Mars).
/// MMC1 base: 0x16020000. Uses polled FIFO I/O (no IDMAC/DMA).
/// Block size: 4096 bytes (8 × 512-byte sectors) to match Fornax blk layer.
///
/// SD card init: CMD0 → CMD8 → ACMD41 → CMD2 → CMD3 → CMD7 → ACMD6 → clock up.
/// Block read: CMD17 (single) / CMD18 (multi). Block write: CMD24 / CMD25.
const builtin = @import("builtin");
const klog = @import("klog.zig");
const mem = @import("mem.zig");

const cpu = switch (builtin.cpu.arch) {
    .riscv64 => @import("arch/riscv64/cpu.zig"),
    else => struct {
        pub fn rdtime() u64 {
            return 0;
        }
    },
};

const paging = switch (builtin.cpu.arch) {
    .riscv64 => @import("arch/riscv64/paging.zig"),
    else => struct {
        pub fn isInitialized() bool {
            return false;
        }
    },
};

const board = switch (builtin.cpu.arch) {
    .riscv64 => @import("arch/riscv64/board/board.zig"),
    else => struct {
        pub const active = struct {
            pub const timer_freq: u32 = 1;
        };
    },
};

// ── Register offsets ───────────────────────────────────────────────────

const CTRL: u32 = 0x000;
const PWREN: u32 = 0x004;
const CLKDIV: u32 = 0x008;
const CLKSRC: u32 = 0x00C;
const CLKENA: u32 = 0x010;
const TMOUT: u32 = 0x014;
const CTYPE: u32 = 0x018;
const BLKSIZ: u32 = 0x01C;
const BYTCNT: u32 = 0x020;
const INTMASK: u32 = 0x024;
const CMDARG: u32 = 0x028;
const CMD: u32 = 0x02C;
const RESP0: u32 = 0x030;
const RESP1: u32 = 0x034;
const RESP2: u32 = 0x038;
const RESP3: u32 = 0x03C;
const RINTSTS: u32 = 0x044;
const STATUS: u32 = 0x048;
const FIFOTH: u32 = 0x04C;
const CDETECT: u32 = 0x050;
const DATA: u32 = 0x200;

// CTRL bits
const CTRL_RESET: u32 = 1 << 0;
const CTRL_FIFO_RESET: u32 = 1 << 1;
const CTRL_DMA_RESET: u32 = 1 << 2;
const CTRL_INT_ENABLE: u32 = 1 << 4;

// CMD bits
const CMD_START: u32 = 1 << 31;
const CMD_USE_HOLD_REG: u32 = 1 << 29;
const CMD_UPDATE_CLK: u32 = 1 << 21;
const CMD_INIT: u32 = 1 << 15;
const CMD_SEND_STOP: u32 = 1 << 12;
const CMD_WRITE: u32 = 1 << 10;
const CMD_DATA_EXPECTED: u32 = 1 << 9;
const CMD_CHECK_RESP_CRC: u32 = 1 << 8;
const CMD_RESP_LONG: u32 = 1 << 7;
const CMD_RESP_EXPECTED: u32 = 1 << 6;

// RINTSTS bits
const INT_CMD_DONE: u32 = 1 << 2;
const INT_DATA_OVER: u32 = 1 << 3;
const INT_TXDR: u32 = 1 << 4;
const INT_RXDR: u32 = 1 << 5;
const INT_RESP_ERR: u32 = 1 << 1;
const INT_HLE: u32 = 1 << 12;
const INT_RTO: u32 = 1 << 8;
const INT_DRTO: u32 = 1 << 9;
const INT_DCRC: u32 = 1 << 7;
const INT_RE: u32 = 1 << 1;
const INT_ERR_MASK: u32 = INT_RESP_ERR | INT_HLE | INT_RTO | INT_DRTO | INT_DCRC;

// STATUS bits
const STATUS_FIFO_EMPTY: u32 = 1 << 2;
const STATUS_FIFO_FULL: u32 = 1 << 3;
const STATUS_DATA_BUSY: u32 = 1 << 9;

// ── SD command indices ─────────────────────────────────────────────────

const SD_CMD0_GO_IDLE: u32 = 0;
const SD_CMD2_ALL_SEND_CID: u32 = 2;
const SD_CMD3_SEND_RCA: u32 = 3;
const SD_CMD7_SELECT: u32 = 7;
const SD_CMD8_SEND_IF_COND: u32 = 8;
const SD_CMD16_SET_BLOCKLEN: u32 = 16;
const SD_CMD17_READ_SINGLE: u32 = 17;
const SD_CMD18_READ_MULTI: u32 = 18;
const SD_CMD24_WRITE_SINGLE: u32 = 24;
const SD_CMD25_WRITE_MULTI: u32 = 25;
const SD_CMD55_APP: u32 = 55;
const SD_ACMD6_SET_BUS_WIDTH: u32 = 6;
const SD_ACMD41_SEND_OP_COND: u32 = 41;

const SECTORS_PER_BLOCK: u64 = 8; // 4096 / 512

// ── Controller state ───────────────────────────────────────────────────

const MMC0_BASE: u64 = 0x1601_0000; // JH7110 eMMC / alt SD
const MMC1_BASE: u64 = 0x1602_0000; // JH7110 microSD

var mmc_base: u64 = MMC1_BASE; // selected controller
var initialized: bool = false;
var card_rca: u32 = 0; // relative card address (from CMD3)
var card_sdhc: bool = false; // true = SDHC/SDXC (block addressing)
var capacity_sectors: u64 = 0; // total 512-byte sectors

// ── MMIO helpers ───────────────────────────────────────────────────────

inline fn addr(offset: u32) u64 {
    const phys = mmc_base + @as(u64, offset);
    return if (paging.isInitialized()) phys +% mem.KERNEL_VIRT_BASE else phys;
}

fn reg32(offset: u32) u32 {
    return @as(*volatile u32, @ptrFromInt(addr(offset))).*;
}

fn wreg32(offset: u32, val: u32) void {
    @as(*volatile u32, @ptrFromInt(addr(offset))).* = val;
}

// ── Internal helpers ───────────────────────────────────────────────────

/// Millisecond delay using RISC-V rdtime (4 MHz on JH7110 = 4000 ticks/ms).
fn delayMs(ms: u32) void {
    const freq = board.active.timer_freq; // ticks per second
    const ticks = @as(u64, ms) * freq / 1000;
    const start = cpu.rdtime();
    while (cpu.rdtime() - start < ticks) {
        asm volatile ("nop");
    }
}

/// Wait for previous command to complete (CMD register START bit cleared by hw).
fn waitCmdAccepted() bool {
    var timeout: u32 = 500_000;
    while (timeout > 0) : (timeout -= 1) {
        if ((reg32(CMD) & CMD_START) == 0) return true;
    }
    klog.warn("dwmmc: CMD_START stuck\n");
    return false;
}

/// Update internal clock registers (CLKDIV/CLKENA) without sending a real command.
fn updateClock() bool {
    wreg32(CMDARG, 0);
    wreg32(CMD, CMD_START | CMD_UPDATE_CLK);
    return waitCmdAccepted();
}

/// Send a command and wait for CMD_DONE. Returns false on error/timeout.
fn sendCmd(cmd_index: u32, arg: u32, flags: u32) bool {
    // Clear all interrupt status
    wreg32(RINTSTS, 0xFFFFFFFF);

    wreg32(CMDARG, arg);
    wreg32(CMD, CMD_START | CMD_USE_HOLD_REG | cmd_index | flags);

    // Wait for command done or error
    var timeout: u32 = 500_000;
    while (timeout > 0) : (timeout -= 1) {
        const sts = reg32(RINTSTS);
        if ((sts & INT_ERR_MASK) != 0) {
            klog.warn("dwmmc: CMD");
            klog.warnDec(cmd_index);
            klog.warn(" error sts=");
            klog.warnHex(sts);
            klog.warn("\n");
            return false;
        }
        if ((sts & INT_CMD_DONE) != 0) return true;
    }
    klog.warn("dwmmc: CMD");
    klog.warnDec(cmd_index);
    klog.warn(" timeout\n");
    return false;
}

/// Send ACMD (CMD55 + app command).
fn sendAcmd(cmd_index: u32, arg: u32, flags: u32) bool {
    if (!sendCmd(SD_CMD55_APP, @as(u32, card_rca) << 16, CMD_RESP_EXPECTED | CMD_CHECK_RESP_CRC))
        return false;
    return sendCmd(cmd_index, arg, flags);
}

/// Reset FIFO.
fn resetFifo() void {
    wreg32(CTRL, reg32(CTRL) | CTRL_FIFO_RESET);
    var timeout: u32 = 100_000;
    while (timeout > 0) : (timeout -= 1) {
        if ((reg32(CTRL) & CTRL_FIFO_RESET) == 0) return;
    }
    klog.warn("dwmmc: FIFO reset timeout\n");
}

// ── SD card initialization ─────────────────────────────────────────────

/// Set DW-MMC clock divider. JH7110 source clock is ~50 MHz from SYSCRG.
/// Output = source / (2 * div). div=0 means bypass (full speed).
fn setClock(div: u32) void {
    // Disable clock
    wreg32(CLKENA, 0);
    if (!updateClock()) return;

    // Set divider
    wreg32(CLKSRC, 0);
    wreg32(CLKDIV, div);
    if (!updateClock()) return;

    // Enable clock
    wreg32(CLKENA, 1);
    _ = updateClock();
}

fn controllerReset() bool {
    // Full controller reset
    wreg32(CTRL, CTRL_RESET | CTRL_FIFO_RESET | CTRL_DMA_RESET);
    var timeout: u32 = 100_000;
    while (timeout > 0) : (timeout -= 1) {
        if ((reg32(CTRL) & (CTRL_RESET | CTRL_FIFO_RESET | CTRL_DMA_RESET)) == 0)
            break;
    }
    if (timeout == 0) {
        klog.err("dwmmc: controller reset timeout\n");
        return false;
    }

    // Enable internal interrupt signaling (not IRQ — we poll RINTSTS)
    wreg32(CTRL, CTRL_INT_ENABLE);

    // Power on — card needs ≥10ms power stabilization
    wreg32(PWREN, 1);
    delayMs(20);

    // Data/response timeout
    wreg32(TMOUT, 0xFFFFFFFF);

    // FIFO threshold: RX watermark = 7 (half of 16-entry FIFO)
    wreg32(FIFOTH, (7 << 16) | 8);

    // Clear pending interrupts
    wreg32(RINTSTS, 0xFFFFFFFF);

    // Unmask all interrupts for polling
    wreg32(INTMASK, 0);

    return true;
}

fn cardInit() bool {
    // Slow clock for identification (400 kHz: 50 MHz / (2 * 63) ≈ 397 kHz)
    setClock(63);

    // SD spec: ≥1ms supply ramp-up + ≥74 clocks at ≤400 kHz before first cmd.
    delayMs(20);

    // CMD0: GO_IDLE_STATE (no response) — send twice for reliability.
    _ = sendCmd(SD_CMD0_GO_IDLE, 0, CMD_INIT);
    delayMs(5);
    if (!sendCmd(SD_CMD0_GO_IDLE, 0, CMD_INIT)) {
        klog.err("dwmmc: CMD0 failed\n");
        return false;
    }
    delayMs(2);

    // CMD8: SEND_IF_COND (voltage check, 0x1AA pattern)
    if (!sendCmd(SD_CMD8_SEND_IF_COND, 0x1AA, CMD_RESP_EXPECTED | CMD_CHECK_RESP_CRC)) {
        klog.warn("dwmmc: CMD8 failed — SD v1 card?\n");
        // Continue — may be an old SD v1 card
    } else {
        const r7 = reg32(RESP0);
        if ((r7 & 0xFF) != 0xAA) {
            klog.err("dwmmc: CMD8 bad pattern\n");
            return false;
        }
    }

    if (!finishCardInit()) return false;

    // Switch to 25 MHz (div=1 → 50 / (2*1) = 25 MHz)
    setClock(1);

    return true;
}

// ── Public API ─────────────────────────────────────────────────────────

/// Dump U-Boot's register state for a controller (before we touch anything).
fn dumpUbootState(base: u64, name: []const u8) void {
    mmc_base = base;
    klog.info("dwmmc: ");
    klog.info(name);
    klog.info(" U-Boot state: CTRL=");
    klog.infoHex(reg32(CTRL));
    klog.info(" CLKENA=");
    klog.infoHex(reg32(CLKENA));
    klog.info(" CLKDIV=");
    klog.infoHex(reg32(CLKDIV));
    klog.info(" CTYPE=");
    klog.infoHex(reg32(CTYPE));
    klog.info(" CDETECT=");
    klog.infoHex(reg32(CDETECT));
    klog.info(" STATUS=");
    klog.infoHex(reg32(STATUS));
    klog.info(" PWREN=");
    klog.infoHex(reg32(PWREN));
    klog.info("\n");
}

/// Try soft init: use U-Boot's clock/controller config, just re-idle the card.
fn trySoftInit(base: u64, name: []const u8) bool {
    mmc_base = base;

    // Check if controller has an active clock (U-Boot left it running)
    if ((reg32(CLKENA) & 1) == 0) return false;

    klog.info("dwmmc: ");
    klog.info(name);
    klog.info(" trying soft init (no reset)...\n");

    // Reset card state only — clear pending interrupts, FIFO
    wreg32(RINTSTS, 0xFFFFFFFF);
    resetFifo();

    // Ensure CTRL has INT_ENABLE
    wreg32(CTRL, reg32(CTRL) | CTRL_INT_ENABLE);

    // Send CMD0 to idle the card (use existing clock)
    delayMs(5);
    _ = sendCmd(SD_CMD0_GO_IDLE, 0, CMD_INIT);
    delayMs(5);
    if (!sendCmd(SD_CMD0_GO_IDLE, 0, CMD_INIT)) {
        klog.warn("dwmmc: soft CMD0 failed\n");
        return false;
    }
    delayMs(2);

    // Try CMD8
    if (!sendCmd(SD_CMD8_SEND_IF_COND, 0x1AA, CMD_RESP_EXPECTED | CMD_CHECK_RESP_CRC)) {
        klog.warn("dwmmc: soft CMD8 failed\n");
        return false;
    }
    klog.info("dwmmc: soft CMD8 OK!\n");

    // Continue with full card init from ACMD41 onward
    card_rca = 0;
    card_sdhc = false;

    const r7 = reg32(RESP0);
    if ((r7 & 0xFF) != 0xAA) {
        klog.err("dwmmc: CMD8 bad pattern\n");
        return false;
    }

    return finishCardInit();
}

/// Card init from ACMD41 onward (shared between soft and hard init paths).
fn finishCardInit() bool {
    var acmd41_timeout: u32 = 1000;
    while (acmd41_timeout > 0) : (acmd41_timeout -= 1) {
        if (!sendAcmd(SD_ACMD41_SEND_OP_COND, 0x40FF8000, CMD_RESP_EXPECTED)) {
            klog.err("dwmmc: ACMD41 failed\n");
            return false;
        }
        const ocr = reg32(RESP0);
        if ((ocr & (1 << 31)) != 0) {
            card_sdhc = (ocr & (1 << 30)) != 0;
            break;
        }
        delayMs(10);
    }
    if (acmd41_timeout == 0) {
        klog.err("dwmmc: ACMD41 timeout — card not ready\n");
        return false;
    }

    if (!sendCmd(SD_CMD2_ALL_SEND_CID, 0, CMD_RESP_EXPECTED | CMD_RESP_LONG)) {
        klog.err("dwmmc: CMD2 failed\n");
        return false;
    }

    if (!sendCmd(SD_CMD3_SEND_RCA, 0, CMD_RESP_EXPECTED | CMD_CHECK_RESP_CRC)) {
        klog.err("dwmmc: CMD3 failed\n");
        return false;
    }
    card_rca = reg32(RESP0) >> 16;

    if (!sendCmd(SD_CMD7_SELECT, @as(u32, card_rca) << 16, CMD_RESP_EXPECTED | CMD_CHECK_RESP_CRC)) {
        klog.err("dwmmc: CMD7 failed\n");
        return false;
    }

    if (!sendAcmd(SD_ACMD6_SET_BUS_WIDTH, 2, CMD_RESP_EXPECTED | CMD_CHECK_RESP_CRC)) {
        klog.warn("dwmmc: ACMD6 failed, staying 1-bit\n");
    } else {
        wreg32(CTYPE, 1);
    }

    if (!card_sdhc) {
        if (!sendCmd(SD_CMD16_SET_BLOCKLEN, 512, CMD_RESP_EXPECTED | CMD_CHECK_RESP_CRC)) {
            klog.warn("dwmmc: CMD16 failed\n");
        }
    }

    // Don't change clock speed in soft init — keep U-Boot's setting
    return true;
}

/// Try full init: controller reset + card init from scratch.
fn tryFullInit(base: u64, name: []const u8) bool {
    mmc_base = base;

    if ((reg32(CDETECT) & 1) != 0) return false;

    klog.info("dwmmc: ");
    klog.info(name);
    klog.info(" full init...\n");

    if (!controllerReset()) return false;
    if (!cardInit()) return false;

    return true;
}

pub fn init() bool {
    if (comptime builtin.cpu.arch != .riscv64) return false;
    if (comptime @import("build_options").board != .milkv_mars) return false;

    // Strategy 1: Soft init — reuse U-Boot's clock/controller config
    if (trySoftInit(MMC1_BASE, "MMC1")) {
        capacity_sectors = 0;
        initialized = true;
        klog.info("dwmmc: SD card ready (soft init)\n");
        return true;
    }
    if (trySoftInit(MMC0_BASE, "MMC0")) {
        capacity_sectors = 0;
        initialized = true;
        klog.info("dwmmc: SD card ready (soft init)\n");
        return true;
    }

    // Strategy 2: Full reset + card init
    if (tryFullInit(MMC1_BASE, "MMC1") or tryFullInit(MMC0_BASE, "MMC0")) {
        capacity_sectors = 0;
        initialized = true;
        klog.info("dwmmc: SD card ready (full init)\n");
        return true;
    }

    klog.info("dwmmc: no SD card found\n");
    return false;
}

pub fn isInitialized() bool {
    return initialized;
}

/// Read a 4096-byte (8-sector) block. block is a 4K-block number.
pub fn readBlock(block: u64, buf: *[4096]u8) bool {
    if (!initialized) return false;

    resetFifo();

    const sector = block * SECTORS_PER_BLOCK;
    const card_addr: u32 = if (card_sdhc)
        @intCast(sector) // SDHC: block address
    else
        @intCast(sector * 512); // SD: byte address

    // Set up for 4096-byte transfer (8 sectors of 512)
    wreg32(BLKSIZ, 512);
    wreg32(BYTCNT, 4096);

    // Clear interrupts
    wreg32(RINTSTS, 0xFFFFFFFF);

    // CMD18: READ_MULTIPLE_BLOCK (CMD_SEND_STOP → auto CMD12 after BYTCNT bytes)
    if (!sendCmd(SD_CMD18_READ_MULTI, card_addr, CMD_RESP_EXPECTED | CMD_CHECK_RESP_CRC | CMD_DATA_EXPECTED | CMD_SEND_STOP)) {
        return false;
    }

    // Read data from FIFO — 1024 × 32-bit words = 4096 bytes
    var offset: usize = 0;
    while (offset < 4096) {
        // Wait for data available in FIFO
        var timeout: u32 = 500_000;
        while (timeout > 0) : (timeout -= 1) {
            const sts = reg32(RINTSTS);
            if ((sts & INT_ERR_MASK) != 0) {
                klog.warn("dwmmc: read error sts=");
                klog.warnHex(sts);
                klog.warn("\n");
                return false;
            }
            if ((sts & (INT_RXDR | INT_DATA_OVER)) != 0) break;
        }
        if (timeout == 0) {
            klog.warn("dwmmc: read FIFO timeout\n");
            return false;
        }

        // Drain available FIFO entries
        while (offset < 4096) {
            if ((reg32(STATUS) & STATUS_FIFO_EMPTY) != 0) break;
            const word = reg32(DATA);
            const dst: *align(1) u32 = @ptrCast(buf[offset..][0..4]);
            dst.* = word;
            offset += 4;
        }

        // Clear RXDR so we get another watermark interrupt
        wreg32(RINTSTS, INT_RXDR);
    }

    // Wait for data transfer complete + auto-stop done
    var done_timeout: u32 = 500_000;
    while (done_timeout > 0) : (done_timeout -= 1) {
        if ((reg32(RINTSTS) & INT_DATA_OVER) != 0) break;
    }
    wreg32(RINTSTS, 0xFFFFFFFF);

    // Wait for card not busy after auto CMD12
    var busy_timeout: u32 = 500_000;
    while (busy_timeout > 0) : (busy_timeout -= 1) {
        if ((reg32(STATUS) & STATUS_DATA_BUSY) == 0) break;
    }

    return true;
}

/// Write a 4096-byte (8-sector) block. block is a 4K-block number.
pub fn writeBlock(block: u64, buf: *const [4096]u8) bool {
    if (!initialized) return false;

    resetFifo();

    const sector = block * SECTORS_PER_BLOCK;
    const card_addr: u32 = if (card_sdhc)
        @intCast(sector)
    else
        @intCast(sector * 512);

    wreg32(BLKSIZ, 512);
    wreg32(BYTCNT, 4096);

    wreg32(RINTSTS, 0xFFFFFFFF);

    // CMD25: WRITE_MULTIPLE_BLOCK (CMD_SEND_STOP → auto CMD12)
    if (!sendCmd(SD_CMD25_WRITE_MULTI, card_addr, CMD_RESP_EXPECTED | CMD_CHECK_RESP_CRC | CMD_DATA_EXPECTED | CMD_WRITE | CMD_SEND_STOP)) {
        return false;
    }

    // Write data to FIFO
    var offset: usize = 0;
    while (offset < 4096) {
        var timeout: u32 = 500_000;
        while (timeout > 0) : (timeout -= 1) {
            const sts = reg32(RINTSTS);
            if ((sts & INT_ERR_MASK) != 0) {
                klog.warn("dwmmc: write error sts=");
                klog.warnHex(sts);
                klog.warn("\n");
                return false;
            }
            if ((sts & (INT_TXDR | INT_DATA_OVER)) != 0) break;
        }
        if (timeout == 0) {
            klog.warn("dwmmc: write FIFO timeout\n");
            return false;
        }

        while (offset < 4096) {
            if ((reg32(STATUS) & STATUS_FIFO_FULL) != 0) break;
            const src: *align(1) const u32 = @ptrCast(buf[offset..][0..4]);
            wreg32(DATA, src.*);
            offset += 4;
        }

        wreg32(RINTSTS, INT_TXDR);
    }

    // Wait for data transfer complete + auto-stop
    var done_timeout: u32 = 500_000;
    while (done_timeout > 0) : (done_timeout -= 1) {
        if ((reg32(RINTSTS) & INT_DATA_OVER) != 0) break;
    }
    wreg32(RINTSTS, 0xFFFFFFFF);

    // Wait for card not busy after auto CMD12
    var busy_timeout: u32 = 1_000_000;
    while (busy_timeout > 0) : (busy_timeout -= 1) {
        if ((reg32(STATUS) & STATUS_DATA_BUSY) == 0) break;
    }

    return true;
}

pub fn getCapacitySectors() u64 {
    return capacity_sectors;
}

pub fn getCapacityBlocks() u64 {
    return capacity_sectors / SECTORS_PER_BLOCK;
}
