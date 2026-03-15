# Phase 4002: Mars First Boot (Serial Output)

## Status: Complete (software side)

## Goal

Boot Fornax on a physical Milk-V Mars and get serial console output. This is the "first sign of life" milestone — proves the boot path, MMU, and UART work on real JH7110 hardware.

## Boot Chain

Mars boot flow with Fornax as payload:

```
SPI Flash: U-Boot SPL → OpenSBI + U-Boot
                              ↓
                    U-Boot loads Fornax kernel
                    (via SD card, TFTP, or XMODEM)
                              ↓
                    OpenSBI jumps to Fornax in S-mode
                    a0 = hartid, a1 = FDT pointer
```

### Loading Options (development workflow)

1. **TFTP** (fastest iteration): U-Boot `tftpboot` loads kernel from dev machine over ethernet
2. **SD card**: Place kernel binary on FAT partition, U-Boot `fatload`
3. **UART XMODEM**: Slowest but works with nothing else — serial upload via `sx`/`lrzsz`

### U-Boot Commands

```
# TFTP (assuming DHCP or static IP configured)
setenv serverip 192.168.1.x
tftpboot ${kernel_addr_r} fornax.bin
bootm ${kernel_addr_r} - ${fdtcontroladdr}

# SD card
fatload mmc 1:1 ${kernel_addr_r} fornax.bin
go ${kernel_addr_r}

# Or wrap as FIT image for proper FDT passing
```

## Implementation

### 4002.1: Kernel Load Address

Determine correct load address for Mars:
- Check U-Boot `kernel_addr_r` environment variable (likely `0x40200000`)
- If different from QEMU's `0x80200000`, the board config and linker script must match
- OpenSBI on JH7110 may reserve a different range than QEMU's 0x80000000-0x80200000

May need a board-specific linker script or a relocatable kernel.

### 4002.2: UART Bring-up

JH7110 UART0 is a Synopsys DesignWare APB UART (NS16550 compatible). The existing `serial.zig` 16550 driver should work if:
- Base address is correct (from FDT or board config)
- Clock is already enabled by U-Boot (should be — U-Boot uses UART)
- Baud rate divisor matches (U-Boot leaves it at 115200)

If U-Boot has already initialized UART, Fornax can skip divisor programming and just write to THR (offset 0x00). Test with a single character write before full serial init.

### 4002.3: Early Debug

Add an ultra-early debug path before FDT or MMU:
1. In `entry.S` after boot hart selection, before BSS clear:
   - Write a character directly to UART MMIO (hardcoded board address)
   - This proves the CPU is running Fornax code
2. After BSS clear but before Zig code: write another character
3. In `riscv64KernelMain`: serial init → banner

### 4002.4: Memory Map Validation

JH7110 RAM starts at `0x40000000` (not `0x80000000` like QEMU). The Sv48 paging setup, identity mapping, and higher-half mapping must handle this different base:
- Identity map covers `0x40000000-0x80000000` (or wherever RAM ends)
- Kernel virtual addresses still at `0xFFFF_8000_0000_0000` + offset
- PMM bitmap starts at correct physical address

### 4002.5: PLIC Validation

JH7110 PLIC should be at `0x0C000000` (same as QEMU). Verify via FDT. If it works, UART RX interrupts enable interactive serial console.

### 4002.6: SMP Validation

JH7110 has 4x U74 harts (IDs 1-4) + 1x S7 monitor hart (ID 0, rv32, no MMU). The S7 should be filtered out during SMP init. SBI HSM `hart_get_status` should report it differently, but verify. FDT `/cpus` parsing (4001) provides the authoritative hart list.

## Hardware Setup

- Milk-V Mars board
- USB-C power (5V/3A)
- USB-to-UART adapter on 40-pin GPIO header (TX=pin 8/GPIO5, RX=pin 10/GPIO6, GND=pin 6)
- Serial terminal at 115200 8N1
- microSD card (for kernel loading) or ethernet (for TFTP)

## Verify

1. Single character appears on serial after power-on (early debug)
2. Full Fornax boot banner prints
3. FDT memory size matches Mars RAM (1/2/4/8 GB depending on model)
4. PMM reports correct free page count
5. SMP starts correct number of U74 harts (4), skips S7
6. Shell prompt appears on serial console (if initrd is loaded)

## Depends On

- Phase 4000 (build target)
- Phase 4001 (FDT for address discovery)
