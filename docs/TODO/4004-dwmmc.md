# Phase 4004: DW-MMC SD/eMMC Driver

## Status: Not Started

## Goal

DesignWare MMC host controller driver for microSD and eMMC on the JH7110. This is the primary block device on Mars — needed to load initrd/rootfs from SD card.

## Hardware

JH7110 has two DW-MMC controllers:
- MMC0 (`0x16010000`) — eMMC (if populated)
- MMC1 (`0x16020000`) — microSD slot

Mars uses MMC1 for the SD card slot. Both are Synopsys DesignWare Mobile Storage Host Controller (DW-MMC / DWMCI).

## Reference

Linux driver: `drivers/mmc/host/dw_mmc.c` (generic) + `drivers/mmc/host/dw_mmc-starfive.c` (JH7110 glue). The generic DW-MMC driver is well-documented and handles all register programming. The StarFive glue adds UHS tuning (~150 lines).

## Implementation

### 4004.1: DW-MMC Register Map

Key registers (offsets from controller base):

| Register | Offset | Purpose |
|----------|--------|---------|
| CTRL | 0x000 | Controller control (reset, interrupt enable) |
| PWREN | 0x004 | Power enable |
| CLKDIV | 0x008 | Clock divider |
| CLKSRC | 0x00C | Clock source |
| CLKENA | 0x010 | Clock enable |
| TMOUT | 0x014 | Timeout |
| CTYPE | 0x018 | Card type (bus width: 1/4/8 bit) |
| BLKSIZ | 0x01C | Block size |
| BYTCNT | 0x020 | Byte count |
| INTMASK | 0x024 | Interrupt mask |
| CMDARG | 0x028 | Command argument |
| CMD | 0x02C | Command register |
| RESP0-3 | 0x030-0x03C | Response registers |
| MINTSTS | 0x040 | Masked interrupt status |
| RINTSTS | 0x044 | Raw interrupt status |
| STATUS | 0x048 | Status (FIFO count, busy) |
| FIFOTH | 0x04C | FIFO threshold |
| CDETECT | 0x050 | Card detect |
| BMOD | 0x080 | Bus mode (IDMAC enable) |
| DBADDR | 0x088 | Descriptor list base address |
| IDSTS | 0x08C | Internal DMA status |
| IDINTEN | 0x090 | Internal DMA interrupt enable |
| UHS_REG_EXT | 0x108 | UHS extended register (tuning) |

### 4004.2: SD Card Protocol (SPI mode not needed)

DW-MMC operates in SD native mode. Init sequence:

1. Controller reset (CTRL bit 0, FIFO reset bit 1, DMA reset bit 2)
2. Power on (PWREN = 1)
3. Set clock to 400 kHz for identification (CLKDIV, CLKENA, send CMD with update_clk flag)
4. Send CMD0 (GO_IDLE_STATE)
5. Send CMD8 (SEND_IF_COND, voltage check)
6. Send ACMD41 (SD_SEND_OP_COND, wait for ready, check SDHC)
7. Send CMD2 (ALL_SEND_CID)
8. Send CMD3 (SEND_RELATIVE_ADDR) → get RCA
9. Send CMD7 (SELECT_CARD, with RCA)
10. Send ACMD6 (SET_BUS_WIDTH, 4-bit)
11. Increase clock to 25 MHz (or 50 MHz for high-speed)

### 4004.3: Block Read/Write

Single-block transfer (CMD17/CMD24) using polling (no DMA initially):

```
1. Set BLKSIZ = 512, BYTCNT = 512
2. Write block address to CMDARG
3. Write CMD17 (READ_SINGLE_BLOCK) or CMD24 (WRITE_SINGLE_BLOCK) to CMD register
4. Poll RINTSTS for command done
5. Read/write FIFO data register (offset 0x200) in 32-bit words
6. Poll RINTSTS for data transfer complete
7. Clear interrupt status
```

Multi-block: CMD18/CMD25 with BYTCNT = n * 512.

### 4004.4: Integration with Block Device Layer

Register as a block device (like virtio-blk / NVMe):
- Implement `blk.BlockDevice` interface: `read(lba, count, buf)`, `write(lba, count, buf)`
- Register with `blk.registerDevice()` for fxfs / partfs consumption
- SD card appears as `/dev/blk0` or similar

### 4004.5: JH7110 UHS Tuning (Optional, for High Speed)

For SDR50/SDR104 modes at high clock rates, the StarFive-specific tuning:
1. Iterate delay chain values 0-31 (UHS_REG_EXT bits 20:16)
2. Send CMD19 (SEND_TUNING_BLOCK) at each phase
3. Find valid window boundaries, select midpoint

This is optional for initial bring-up — 25 MHz default speed is sufficient.

## Files Modified

| File | Change |
|------|--------|
| `src/drivers/dwmmc.zig` | New: DW-MMC host controller driver |
| `src/main.zig` | Init DW-MMC on Mars board |
| `src/blk.zig` | May need minor adjustments for new block device registration |

## Verify

1. SD card detected (CDETECT register reads 0 = card present)
2. CMD0/CMD8/ACMD41 succeed (card identified as SDHC)
3. Read sector 0 (MBR/GPT) — verify magic bytes
4. fxfs mounts from SD card partition
5. Initrd loads from SD card

## Depends On

- Phase 4002 (serial working for debug output)
- Phase 4003 (SDIO1 clocks enabled and reset deasserted)
