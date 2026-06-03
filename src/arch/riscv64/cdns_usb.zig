/// Cadence USB3 controller wrapper for StarFive JH7110 (Milk-V Mars).
///
/// The JH7110 uses a Cadence USB3 controller at 0x10100000. In host mode,
/// it exposes xHCI-compatible registers at offset 0x10000 within the block.
/// This module configures the STG syscon for host mode and initializes the
/// USB 2.0 PHY, then returns the xHCI MMIO base for the existing xHCI driver.
///
/// Reference: Linux drivers/usb/cdns3/cdns3-starfive.c + drivers/phy/starfive/phy-jh7110-usb.c

const klog = @import("../../klog.zig");
const mem = @import("../../mem.zig");
const paging = @import("paging.zig");

// ── Hardware addresses ────────────────────────────────────────────────

const STG_SYSCON_BASE: u64 = 0x1024_0000;
const SYS_SYSCON_BASE: u64 = 0x1303_0000;
const CDNS_USB_BASE: u64 = 0x1010_0000;
const XHCI_OFFSET: u64 = 0x1_0000;
const USB_PHY_BASE: u64 = 0x1020_0000;

// ── JH7110 SYS IOMUX (pin mux controller) ──────────────────────��─────

const SYS_IOMUX_BASE: u64 = 0x1304_0000;
const GPO_DOUT_BASE: u64 = 0x000; // output function select
const GPO_DOEN_BASE: u64 = 0x040; // output enable function select
// 4 GPIOs packed per 32-bit register, 8 bits each (6-bit function ID)

// Mars: GPIO 25 = USB VBUS power enable
const USB_VBUS_GPIO: u32 = 25;
const GPOUT_SYS_USB_DRIVE_VBUS: u32 = 92; // 0x5c — USB controller drives VBUS
const GPOEN_ENABLE: u32 = 0; // output always enabled

// ── STG syscon USB mode register (offset 0x4) ────────────���───────────

const STG_USB_MODE_OFF: u64 = 0x4;

const USB_STRAP_HOST: u32 = 1 << 17;
const USB_STRAP_DEVICE: u32 = 1 << 18;
const USB_STRAP_MASK: u32 = 0x7 << 16; // bits 18:16
const USB_SUSPENDM_HOST: u32 = 1 << 19;
const USB_SUSPENDM_MASK: u32 = 1 << 19;
const USB_MISC_CFG_MASK: u32 = 0xF << 20; // bits 23:20
const USB_SUSPENDM_BYPS: u32 = 1 << 20;
const USB_PLL_EN: u32 = 1 << 22;
const USB_REFCLK_MODE: u32 = 1 << 23;

// ── USB 2.0 PHY registers ────────────────────────────────────────────

const USB_CLK_MODE_OFF: u64 = 0x0;
const USB_CLK_MODE_RX_NORMAL_PWR: u32 = 1 << 1;
const USB_LS_KEEPALIVE_OFF: u64 = 0x4;
const USB_LS_KEEPALIVE_ENABLE: u32 = 1 << 4;

// ── SYS syscon USB PHY split register ────────────────────────────────

const SYSCON_USB_SPLIT_OFF: u64 = 0x18;
const USB_PDRSTN_SPLIT: u32 = 1 << 17;

// ── MMIO helpers ──────────────────────────────────────────────────────

inline fn addr(phys: u64) u64 {
    return if (paging.isInitialized()) phys +% mem.KERNEL_VIRT_BASE else phys;
}

fn mmioRead32(a: u64) u32 {
    return @as(*volatile u32, @ptrFromInt(a)).*;
}

fn mmioWrite32(a: u64, val: u32) void {
    @as(*volatile u32, @ptrFromInt(a)).* = val;
}

fn regUpdate(base: u64, offset: u64, mask: u32, val: u32) void {
    const a = addr(base + offset);
    const old = mmioRead32(a);
    mmioWrite32(a, (old & ~mask) | (val & mask));
}

/// Configure a JH7110 SYS IOMUX GPIO pad's output function and enable.
/// 4 GPIOs per 32-bit register, 8 bits each (bits 5:0 = function ID).
fn setPinMux(gpio: u32, dout_func: u32, doen_func: u32) void {
    const reg_off: u64 = @as(u64, gpio / 4) * 4;
    const shift: u5 = @intCast((gpio % 4) * 8);
    const mask: u32 = @as(u32, 0x3F) << shift;

    // Set output function (which signal drives this pad)
    const dout_addr = addr(SYS_IOMUX_BASE + GPO_DOUT_BASE + reg_off);
    mmioWrite32(dout_addr, (mmioRead32(dout_addr) & ~mask) | ((dout_func & 0x3F) << shift));

    // Set output enable function (which signal controls OE)
    const doen_addr = addr(SYS_IOMUX_BASE + GPO_DOEN_BASE + reg_off);
    mmioWrite32(doen_addr, (mmioRead32(doen_addr) & ~mask) | ((doen_func & 0x3F) << shift));
}

// ── Public init ───────────────────────────────────────────────────────

/// Initialize the Cadence USB3 controller for host mode.
/// Returns the physical address of the xHCI register block, or null on failure.
/// Handles the full sequence: mode config → clocks/resets → PHY init (Linux order).
pub fn init() ?u64 {
    const jh7110_crg = @import("jh7110_crg.zig");

    klog.info("cdns-usb: configuring host mode\n");

    // Step 0: Enable USB VBUS power via GPIO 25 pin mux
    // Mars routes SYS_USB_DRIVE_VBUS signal to GPIO pad 25 to power the onboard hub.
    setPinMux(USB_VBUS_GPIO, GPOUT_SYS_USB_DRIVE_VBUS, GPOEN_ENABLE);
    klog.info("cdns-usb: VBUS enabled (GPIO 25)\n");

    // Step 1: STG syscon mode config — MUST happen BEFORE clocks/resets
    // (controller latches strap bits when coming out of reset)
    regUpdate(STG_SYSCON_BASE, STG_USB_MODE_OFF, USB_MISC_CFG_MASK,
        USB_SUSPENDM_BYPS | USB_PLL_EN | USB_REFCLK_MODE);
    regUpdate(STG_SYSCON_BASE, STG_USB_MODE_OFF, USB_STRAP_MASK, USB_STRAP_HOST);
    regUpdate(STG_SYSCON_BASE, STG_USB_MODE_OFF, USB_SUSPENDM_MASK, USB_SUSPENDM_HOST);

    // Step 2: Enable clocks and deassert resets
    jh7110_crg.enablePeripheral(.usb0);

    // Step 3: USB 2.0 PHY init (after clocks are running)
    const phy_clk = addr(USB_PHY_BASE + USB_CLK_MODE_OFF);
    mmioWrite32(phy_clk, mmioRead32(phy_clk) | USB_CLK_MODE_RX_NORMAL_PWR);

    const phy_ka = addr(USB_PHY_BASE + USB_LS_KEEPALIVE_OFF);
    mmioWrite32(phy_ka, mmioRead32(phy_ka) | USB_LS_KEEPALIVE_ENABLE);

    // SYS syscon: set USB PHY split mode
    regUpdate(SYS_SYSCON_BASE, SYSCON_USB_SPLIT_OFF, USB_PDRSTN_SPLIT, USB_PDRSTN_SPLIT);

    // Stabilization delay (~100ms) — hub chip needs time to power up and link train
    var delay: u32 = 400_000;
    while (delay > 0) : (delay -= 1) {
        asm volatile ("nop");
    }

    // Step 4: Verify xHCI capability registers
    const xhci_base = CDNS_USB_BASE + XHCI_OFFSET;
    const cap0 = mmioRead32(addr(xhci_base));
    const caplength = cap0 & 0xFF;
    const version = (cap0 >> 16) & 0xFFFF;

    if (caplength == 0 or caplength == 0xFF or version == 0 or version == 0xFFFF) {
        klog.err("cdns-usb: xHCI cap registers not responding (cap0=");
        klog.errHex(cap0);
        klog.err(")\n");
        return null;
    }

    klog.info("cdns-usb: xHCI detected, version ");
    klog.infoDec(version >> 8);
    klog.info(".");
    klog.infoDec(version & 0xFF);
    klog.info(" at ");
    klog.infoHex(xhci_base);
    klog.info("\n");

    return xhci_base;
}
