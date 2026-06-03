/// JH7110 Clock/Reset Generator (CRG) driver — minimal peripheral enablement.
///
/// The JH7110 has 268 clocks and 181 resets across SYSCRG, AONCRG, and STGCRG domains.
/// Each clock is a 32-bit register at base + clock_id * 4:
///   bit 31 = CLK_ENABLE, bits 27:24 = MUX_SEL, bits 23:0 = DIV
/// Resets are bit-packed: assert register at domain-specific offset,
///   word_index = reset_id / 32, bit = reset_id % 32.
///
/// This driver only enables clocks/resets needed by Fornax peripheral drivers
/// (GMAC, SDIO, PCIe). PLLs are left as U-Boot configured them.
const klog = @import("../../klog.zig");
const mem = @import("../../mem.zig");
const paging = @import("paging.zig");

// ── Domain base addresses ──────────────────────────────────────────────

const SYSCRG_BASE: u64 = 0x1302_0000;
const STGCRG_BASE: u64 = 0x1023_0000;

// Reset register offsets within each domain
const SYSCRG_ASSERT: u64 = 0x2F8;
const SYSCRG_STATUS: u64 = 0x308;
const STGCRG_ASSERT: u64 = 0x74;
const STGCRG_STATUS: u64 = 0x78;

// ── Peripheral definitions ─────────────────────────────────────────────

pub const Peripheral = enum {
    gmac1,
    sdio0,
    sdio1,
    pcie0,
    usb0,
};

// SYSCRG clock IDs (register offset = id * 4)
const SYSCLK_SDIO0_AHB: u32 = 88;
const SYSCLK_SDIO0_CCLK_INT: u32 = 89;
const SYSCLK_SDIO0_SDCARD: u32 = 90;
const SYSCLK_SDIO1_AHB: u32 = 92;
const SYSCLK_SDIO1_SDCARD: u32 = 94;
const SYSCLK_GMAC1_AHB: u32 = 97;
const SYSCLK_GMAC1_AXI: u32 = 98;
const SYSCLK_GMAC1_GTXCLK: u32 = 100;
const SYSCLK_GMAC1_TX: u32 = 105;

// SYSCRG clock IDs (USB PHY)
const SYSCLK_USB_125M: u32 = 95;

// STGCRG clock IDs
const STGCLK_USB0_APB: u32 = 1;
const STGCLK_USB0_UTMI_APB: u32 = 2;
const STGCLK_USB0_AXI: u32 = 3;
const STGCLK_USB0_LPM: u32 = 4;
const STGCLK_USB0_STB: u32 = 5;
const STGCLK_USB0_APP_125: u32 = 6;
const STGCLK_PCIE0_AXI_MST0: u32 = 8;
const STGCLK_PCIE0_APB: u32 = 9;
const STGCLK_PCIE0_TL: u32 = 10;

// SYSCRG reset IDs
const SYSRST_SDIO0_AHB: u32 = 61;
const SYSRST_SDIO1_AHB: u32 = 65;
const SYSRST_GMAC1_AXI: u32 = 66;
const SYSRST_GMAC1_AHB: u32 = 67;

// STGCRG reset IDs (USB)
const STGRST_USB0_AXI: u32 = 7;
const STGRST_USB0_APB: u32 = 8;
const STGRST_USB0_UTMI_APB: u32 = 9;
const STGRST_USB0_PWRUP: u32 = 10;

// STGCRG reset IDs (PCIe)
const STGRST_PCIE0_AXI_MST0: u32 = 11;
const STGRST_PCIE0_AXI_SLV0: u32 = 12;
const STGRST_PCIE0_AXI_SLV: u32 = 13;
const STGRST_PCIE0_BRG: u32 = 14;
const STGRST_PCIE0_CORE: u32 = 15;
const STGRST_PCIE0_APB: u32 = 16;

// ── MMIO helpers ───────────────────────────────────────────────────────

inline fn addr(phys: u64) u64 {
    return if (paging.isInitialized()) phys +% mem.KERNEL_VIRT_BASE else phys;
}

fn mmioRead32(a: u64) u32 {
    return @as(*volatile u32, @ptrFromInt(a)).*;
}

fn mmioWrite32(a: u64, val: u32) void {
    @as(*volatile u32, @ptrFromInt(a)).* = val;
}

// ── Clock primitives ───────────────────────────────────────────────────

/// Enable a clock by setting bit 31 in its register.
fn enableClock(domain_base: u64, clock_id: u32) void {
    const reg = addr(domain_base + @as(u64, clock_id) * 4);
    const val = mmioRead32(reg);
    mmioWrite32(reg, val | (1 << 31));
}

// ── Reset primitives ──────────────────────────────────────────────────

/// Deassert a reset (clear the bit → release from reset).
fn deassertReset(domain_base: u64, assert_offset: u64, reset_id: u32) void {
    const word_index = reset_id / 32;
    const bit: u5 = @intCast(reset_id % 32);
    const reg = addr(domain_base + assert_offset + @as(u64, word_index) * 4);
    const val = mmioRead32(reg);
    mmioWrite32(reg, val & ~(@as(u32, 1) << bit));
}

/// Wait for reset status to confirm deasserted.
/// JH7110 polarity: status bit SET = deasserted (out of reset).
fn waitResetDone(domain_base: u64, status_offset: u64, reset_id: u32) void {
    const word_index = reset_id / 32;
    const bit: u5 = @intCast(reset_id % 32);
    const reg = addr(domain_base + status_offset + @as(u64, word_index) * 4);
    var timeout: u32 = 100_000;
    while (timeout > 0) : (timeout -= 1) {
        if ((mmioRead32(reg) & (@as(u32, 1) << bit)) != 0) return;
    }
    klog.warn("CRG: reset ");
    klog.warnDec(reset_id);
    klog.warn(" status timeout (reg=");
    klog.warnHex(mmioRead32(reg));
    klog.warn(")\n");
}

// ── Peripheral enable ─────────────────────────────────────────────────

/// Enable clocks and deassert resets for a JH7110 peripheral.
pub fn enablePeripheral(peripheral: Peripheral) void {
    switch (peripheral) {
        .gmac1 => {
            enableClock(SYSCRG_BASE, SYSCLK_GMAC1_AHB);
            enableClock(SYSCRG_BASE, SYSCLK_GMAC1_AXI);
            enableClock(SYSCRG_BASE, SYSCLK_GMAC1_GTXCLK);
            enableClock(SYSCRG_BASE, SYSCLK_GMAC1_TX);
            deassertReset(SYSCRG_BASE, SYSCRG_ASSERT, SYSRST_GMAC1_AXI);
            deassertReset(SYSCRG_BASE, SYSCRG_ASSERT, SYSRST_GMAC1_AHB);
            waitResetDone(SYSCRG_BASE, SYSCRG_STATUS, SYSRST_GMAC1_AXI);
            waitResetDone(SYSCRG_BASE, SYSCRG_STATUS, SYSRST_GMAC1_AHB);
            klog.info("CRG: GMAC1 clocks enabled, resets deasserted\n");
        },
        .sdio0 => {
            enableClock(SYSCRG_BASE, SYSCLK_SDIO0_AHB);
            enableClock(SYSCRG_BASE, SYSCLK_SDIO0_CCLK_INT);
            enableClock(SYSCRG_BASE, SYSCLK_SDIO0_SDCARD);
            deassertReset(SYSCRG_BASE, SYSCRG_ASSERT, SYSRST_SDIO0_AHB);
            waitResetDone(SYSCRG_BASE, SYSCRG_STATUS, SYSRST_SDIO0_AHB);
            klog.info("CRG: SDIO0 clocks enabled, reset deasserted\n");
        },
        .sdio1 => {
            enableClock(SYSCRG_BASE, SYSCLK_SDIO1_AHB);
            enableClock(SYSCRG_BASE, SYSCLK_SDIO1_SDCARD);
            deassertReset(SYSCRG_BASE, SYSCRG_ASSERT, SYSRST_SDIO1_AHB);
            waitResetDone(SYSCRG_BASE, SYSCRG_STATUS, SYSRST_SDIO1_AHB);
            klog.info("CRG: SDIO1 clocks enabled, reset deasserted\n");
        },
        .usb0 => {
            // STGCRG USB clocks
            enableClock(STGCRG_BASE, STGCLK_USB0_LPM);
            enableClock(STGCRG_BASE, STGCLK_USB0_STB);
            enableClock(STGCRG_BASE, STGCLK_USB0_APB);
            enableClock(STGCRG_BASE, STGCLK_USB0_AXI);
            enableClock(STGCRG_BASE, STGCLK_USB0_UTMI_APB);
            enableClock(STGCRG_BASE, STGCLK_USB0_APP_125);
            // SYSCRG USB 125 MHz reference clock
            enableClock(SYSCRG_BASE, SYSCLK_USB_125M);
            // Deassert USB resets
            deassertReset(STGCRG_BASE, STGCRG_ASSERT, STGRST_USB0_PWRUP);
            deassertReset(STGCRG_BASE, STGCRG_ASSERT, STGRST_USB0_APB);
            deassertReset(STGCRG_BASE, STGCRG_ASSERT, STGRST_USB0_AXI);
            deassertReset(STGCRG_BASE, STGCRG_ASSERT, STGRST_USB0_UTMI_APB);
            waitResetDone(STGCRG_BASE, STGCRG_STATUS, STGRST_USB0_PWRUP);
            waitResetDone(STGCRG_BASE, STGCRG_STATUS, STGRST_USB0_APB);
            waitResetDone(STGCRG_BASE, STGCRG_STATUS, STGRST_USB0_AXI);
            waitResetDone(STGCRG_BASE, STGCRG_STATUS, STGRST_USB0_UTMI_APB);
            klog.info("CRG: USB0 clocks enabled, resets deasserted\n");
        },
        .pcie0 => {
            enableClock(STGCRG_BASE, STGCLK_PCIE0_AXI_MST0);
            enableClock(STGCRG_BASE, STGCLK_PCIE0_APB);
            enableClock(STGCRG_BASE, STGCLK_PCIE0_TL);
            deassertReset(STGCRG_BASE, STGCRG_ASSERT, STGRST_PCIE0_AXI_MST0);
            deassertReset(STGCRG_BASE, STGCRG_ASSERT, STGRST_PCIE0_AXI_SLV0);
            deassertReset(STGCRG_BASE, STGCRG_ASSERT, STGRST_PCIE0_AXI_SLV);
            deassertReset(STGCRG_BASE, STGCRG_ASSERT, STGRST_PCIE0_BRG);
            deassertReset(STGCRG_BASE, STGCRG_ASSERT, STGRST_PCIE0_CORE);
            deassertReset(STGCRG_BASE, STGCRG_ASSERT, STGRST_PCIE0_APB);
            waitResetDone(STGCRG_BASE, STGCRG_STATUS, STGRST_PCIE0_AXI_MST0);
            waitResetDone(STGCRG_BASE, STGCRG_STATUS, STGRST_PCIE0_CORE);
            waitResetDone(STGCRG_BASE, STGCRG_STATUS, STGRST_PCIE0_APB);
            klog.info("CRG: PCIe0 clocks enabled, resets deasserted\n");
        },
    }
}
