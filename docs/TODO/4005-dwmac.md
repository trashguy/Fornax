# Phase 4005: DW-GMAC Ethernet Driver

## Status: Not Started

## Goal

Synopsys DesignWare GMAC 5.20 ethernet driver for the JH7110. Provides network connectivity on Mars for remote debugging, TFTP kernel loading, and eventually production networking.

## Hardware

JH7110 has two GMAC instances:
- GMAC0 (`0x16030000`) — active on Mars (RJ45 jack)
- GMAC1 (`0x16040000`) — active on VisionFive 2

Mars uses GMAC0 with RGMII PHY interface. The PHY is typically a Motorcomm YT8531 or similar, connected via MDIO.

## Reference

Linux: `drivers/net/ethernet/stmicro/stmmac/` (generic framework, ~20k lines) + `dwmac-starfive.c` (~200 lines JH7110 glue). The Synopsys DW GMAC has public register documentation and the stmmac driver is one of the best-documented ethernet drivers in Linux.

## Implementation

### 4005.1: GMAC Register Map

Key registers (offsets from GMAC base):

| Register | Offset | Purpose |
|----------|--------|---------|
| MAC_CONFIG | 0x0000 | Speed, duplex, TX/RX enable |
| MAC_PACKET_FILTER | 0x0008 | Promiscuous, multicast filter |
| MAC_ADDR_HIGH | 0x0300 | MAC address upper 16 bits |
| MAC_ADDR_LOW | 0x0304 | MAC address lower 32 bits |
| MAC_MDIO_ADDR | 0x0200 | MDIO address register |
| MAC_MDIO_DATA | 0x0204 | MDIO data register |
| DMA_MODE | 0x1000 | DMA software reset, bus mode |
| DMA_SYSBUS_MODE | 0x1004 | AXI burst length, address width |
| DMA_CH0_CONTROL | 0x1100 | Channel 0 control |
| DMA_CH0_TX_CONTROL | 0x1104 | TX DMA control (start/stop) |
| DMA_CH0_RX_CONTROL | 0x1108 | RX DMA control (start/stop, buf size) |
| DMA_CH0_TXDESC_LIST | 0x1114 | TX descriptor ring base (phys) |
| DMA_CH0_RXDESC_LIST | 0x111C | RX descriptor ring base (phys) |
| DMA_CH0_TXDESC_TAIL | 0x1120 | TX descriptor tail pointer |
| DMA_CH0_RXDESC_TAIL | 0x1128 | RX descriptor tail pointer |
| DMA_CH0_TXDESC_RING_LEN | 0x112C | TX ring length |
| DMA_CH0_RXDESC_RING_LEN | 0x1130 | RX ring length |
| DMA_CH0_STATUS | 0x1160 | Channel 0 interrupt status |

### 4005.2: DMA Descriptor Format

GMAC 5.20 uses enhanced descriptors (16 bytes each):

```zig
const DmaDesc = extern struct {
    des0: u32,  // Buffer 1 address (low)
    des1: u32,  // Buffer 2 address (low) or buffer 1 address (high)
    des2: u32,  // Buffer 1 length, VLAN, checksum control
    des3: u32,  // OWN bit, FD/LD, packet length, status
};
// TX des3: OWN(31), FD(29), LD(28), length in des2 bits 13:0
// RX des3: OWN(31), FD(29), LD(28), packet length bits 14:0
```

### 4005.3: PHY Management (MDIO)

Read/write PHY registers via MAC MDIO interface:
1. Write PHY address + register + control bits to MAC_MDIO_ADDR
2. Poll busy bit until cleared
3. Read/write data from MAC_MDIO_DATA

PHY init:
- Read PHY ID registers (reg 2, 3) to identify PHY model
- Configure auto-negotiation (reg 0, 4)
- Wait for link up (reg 1, bit 2)
- Read negotiated speed/duplex from PHY-specific registers

### 4005.4: JH7110 Glue (syscon)

Before using GMAC, configure the StarFive system controller:
- Set PHY interface mode to RGMII via STG syscon register
- Configure TX delay chain (PHY-specific)
- Enable GMAC TX and GTX clocks (Phase 4003)
- Deassert GMAC resets

### 4005.5: Init Sequence

1. Enable clocks, deassert resets (4003)
2. Configure syscon for RGMII mode
3. DMA software reset (DMA_MODE bit 0, poll until cleared)
4. Configure DMA bus mode (AXI burst, address width)
5. Allocate TX/RX descriptor rings (DMA memory, ~64 descriptors each)
6. Allocate RX buffers (2 KB each, DMA memory)
7. Program descriptor ring base addresses and lengths
8. Initialize all RX descriptors (set OWN bit, buffer address)
9. Set RX buffer size in DMA_CH0_RX_CONTROL
10. PHY init via MDIO (auto-negotiate, wait for link)
11. Set MAC address
12. Configure MAC_CONFIG (speed from PHY, full duplex, TX/RX enable)
13. Start DMA TX and RX channels

### 4005.6: Integration with Ether Layer

Register with Fornax's ether layer as a hardware backend:
- Provide `send(frame)` and `recv() -> frame` to `src/ether.zig`
- Either use the "driver mode" ether client (Phase 2100 pattern) or direct kernel integration
- For initial bring-up, direct kernel integration is simpler — replace virtio-net as the ether backend on Mars

## Notes

- GMAC 5.20 is well-documented, same IP used in dozens of SoCs
- The Linux stmmac driver is battle-tested reference code
- Start with polling, add interrupt-driven RX later via PLIC
- Mars buildroot SDK device tree has exact PHY configuration

## Files Modified

| File | Change |
|------|--------|
| `src/drivers/dwmac.zig` | New: GMAC DMA engine, MAC config, descriptor management |
| `src/drivers/mdio.zig` | New: MDIO/PHY management (reusable across GMAC instances) |
| `src/ether.zig` | Add GMAC as hardware backend alongside virtio-net |
| `src/main.zig` | Init GMAC on Mars board |

## Verify

1. PHY detected via MDIO (PHY ID registers non-zero)
2. Link negotiation succeeds (1000BASE-T or 100BASE-TX)
3. ARP request sent and reply received
4. DHCP succeeds (IP address obtained)
5. TCP connection works (netd stack end-to-end)
6. `ping` from Mars to dev machine

## Depends On

- Phase 4003 (GMAC clocks enabled, resets deasserted)
- Phase 4002 (serial debug output)
