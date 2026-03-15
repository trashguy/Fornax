# Phase 4006: PLDA PCIe Host Bridge

## Status: Not Started

## Goal

PLDA XpressRICH PCIe host controller driver for JH7110. Required for any PCIe expansion (NVMe, USB card, NIC). Not critical for initial Mars bring-up (SD + ethernet work without PCIe) but enables the existing Fornax PCI device drivers (NVMe, xHCI).

## Hardware

JH7110 has two PLDA XpressRICH PCIe 2.0 x1 controllers:
- PCIe0: config space at `0x940000000`, M1 window at `0x900000000`
- PCIe1: config space at `0x9C0000000`, M1 window at `0x980000000`

**Important**: PCIe and USB 3.0 share a lane. Only one can be active at a time.

Mars exposes PCIe0 on the M.2 M-key slot (typically used for NVMe SSD).

## Reference

Linux: `drivers/pci/controller/plda/pcie-starfive.c` (~500 lines) + `pcie-plda-host.c` (generic PLDA). This is NOT a DesignWare PCIe controller — different register layout.

## Implementation

### 4006.1: PLDA Register Map

Key registers (from PLDA bridge base, not ECAM):

| Register | Purpose |
|----------|---------|
| Bridge header (type 1 config) | Standard PCI bridge config space |
| BAR0/BAR1 | Root port BARs |
| PLDA control registers | Link control, AXI mapping, interrupt routing |

### 4006.2: Syscon Configuration

StarFive-specific syscon registers (STG syscon domain):

| Offset | Purpose |
|--------|---------|
| 0x48 (PCIe0) / 0x1F8 (PCIe1) | Base config |
| 0x78 | Address read channel config |
| 0x7C | Address write channel config |
| 0xE8 | Root port / endpoint selection |
| 0x170 | Link status (DATA_LINK_ACTIVE bit) |

### 4006.3: Init Sequence

From Linux `starfive_pcie_host_init()`:

1. Init and power on combo PHY (`phy-jh7110-pcie.c` — configure for PCIe mode, not USB)
2. Configure syscon: reference clock, CLKREQ enable
3. Enable all PCIe clocks (STGCRG domain), deassert resets (4003)
4. Optional: enable 3.3V regulator
5. Assert PERST# GPIO → wait 100+ ms → deassert (PCIe spec requirement)
6. Disable functions 1-3 (root port function 0 only)
7. Configure BAR0/BAR1
8. Set root port class code
9. Disable LTR message forwarding (prevents kernel hangs)
10. Poll link training: check DATA_LINK_ACTIVE bit at syscon offset 0x170 (up to 1 second)
11. Once link is up, ECAM-style config access works at the config space window

### 4006.4: ECAM Bridge

After PLDA init, the config space window behaves like standard ECAM. The existing Fornax RISC-V PCI code (`src/arch/riscv64/pci.zig`) can work with a different ECAM base address:
- Set ECAM base to PCIe0 config window (`0x940000000`)
- Standard ECAM formula: `base + (bus << 20 | dev << 15 | func << 12 | reg)`

### 4006.5: Combo PHY Configuration

The PCIe/USB3 combo PHY needs explicit configuration for PCIe mode. Linux uses `phy-jh7110-pcie.c`:
- Set PHY mode to `PHY_MODE_PCIE`
- Configure SerDes lane for PCIe signaling
- Power on PHY

If USB 3.0 is needed instead, this PHY must be configured differently (Phase 4007).

## Notes

- PCIe 2.0 x1 = 5 GT/s = ~500 MB/s theoretical bandwidth
- Once PLDA is initialized and link is up, existing NVMe/xHCI drivers should "just work"
- The PLDA controller is used by several RISC-V SoCs — the driver is somewhat portable
- Mars M.2 slot is M-key so it accepts NVMe SSDs

## Files Modified

| File | Change |
|------|--------|
| `src/drivers/plda_pcie.zig` | New: PLDA host bridge init, PHY config |
| `src/arch/riscv64/pci.zig` | Accept ECAM base from PLDA init instead of hardcoded |
| `src/main.zig` | Call PLDA init on Mars board before PCI device scan |

## Verify

1. Link training succeeds (DATA_LINK_ACTIVE)
2. ECAM config read of bus 0 dev 0 returns valid vendor/device ID
3. NVMe SSD detected in M.2 slot (if present)
4. NVMe read/write works via existing Fornax NVMe driver

## Depends On

- Phase 4003 (PCIe clocks and resets in STGCRG domain)
- Phase 4002 (serial for debug)
