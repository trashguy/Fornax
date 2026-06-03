# Phase 4007: Cadence USB3 Controller

## Status: Implemented (needs hardware test)

## Goal

Cadence USB3 host controller driver for JH7110. The JH7110 does NOT use Synopsys xHCI — it uses a Cadence USB3 controller with its own register interface. Fornax's existing xHCI driver does not directly apply.

## Hardware

- Cadence USB3 controller at `0x10100000`
- USB 2.0 PHY (dedicated)
- USB 3.0 via combo PHY (shared with PCIe — mutually exclusive with Phase 4006)
- Mars has 4x USB 3.0 Type-A ports (via USB hub)

## Reference

Linux: `drivers/usb/cdns3/cdns3-starfive.c` (wrapper) + `drivers/usb/cdns3/cdns3-plat.c` + `core.c` + `host.c`. The Cadence USB3 core can operate in host, device, or OTG mode. In host mode it presents an xHCI-compatible interface internally.

## Key Insight

The Cadence USB3 controller, when configured for **host mode**, exposes an **xHCI-compatible register set** at an offset within its MMIO region. This means Fornax's existing xHCI driver (`src/xhci.zig`) CAN work — but only after the Cadence wrapper is initialized and configured for host mode.

## Implementation

### 4007.1: Cadence Wrapper Init

StarFive-specific wrapper configuration:

1. Enable USB clocks (STGCRG domain) and deassert resets (4003)
2. Configure STG syscon registers:
   - Set `USB_STRAP_HOST` (bit 17) + `USB_SUSPENDM_HOST` (bit 19)
   - Set `USB_MISC_CFG`: PLL enable, bypass suspend, refclk mode (bits 23:20)
3. Init USB 2.0 PHY
4. Optionally init USB 3.0 combo PHY (if not using PCIe)

### 4007.2: xHCI Discovery

After Cadence wrapper init, the xHCI capability registers appear at an offset within the Cadence MMIO region. Discover:
- xHCI capability base (scan for xHCI cap ID)
- Map into kernel address space
- Pass to existing `src/xhci.zig` driver

### 4007.3: USB 2.0 Only Mode

If PCIe is in use (combo PHY configured for PCIe), USB 3.0 is unavailable. USB 2.0 still works via the dedicated USB 2.0 PHY. The xHCI controller operates with USB 2.0 ports only.

## Notes

- This is lower priority than SD/ethernet — USB is nice-to-have for Mars bring-up
- The xHCI-over-Cadence pattern means most of the existing USB stack works
- The wrapper is only ~200 lines in Linux
- USB hub on Mars means all 4 ports go through a single USB controller

## Files Modified

| File | Change |
|------|--------|
| `src/drivers/cdns_usb.zig` | New: Cadence USB3 wrapper + StarFive syscon config |
| `src/xhci.zig` | May need minor changes to accept non-PCI xHCI base address |
| `src/main.zig` | Init Cadence USB on Mars board |

## Verify

1. xHCI capability registers readable after wrapper init
2. USB device enumeration works (plug in USB drive)
3. USB mass storage read via existing xHCI driver

## Depends On

- Phase 4003 (USB clocks and resets)
- Phase 4002 (serial for debug)
