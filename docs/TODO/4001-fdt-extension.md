# Phase 4001: FDT Parser Extension

## Status: Complete

## Goal

Extend `src/arch/riscv64/fdt.zig` from memory-only discovery to full hardware enumeration. On real hardware, FDT is the authoritative source for UART, PLIC, timer, ethernet, and MMC addresses. Board config constants (4000) serve as fallbacks; FDT overrides them at runtime.

## Current State

`fdt.zig` currently:
- Parses FDT magic (0xD00DFEED) and structure block
- Walks `/memory@*` nodes, extracts `reg` property (base + size)
- Returns first memory region or null
- No string block lookup, no nested property parsing, no `compatible` matching

## Implementation

### 4001.1: FDT Infrastructure

Extend the parser with:
- **String block access**: resolve `nameoff` in property nodes to actual strings
- **Property lookup by name**: `findProp(node, "compatible")`, `findProp(node, "reg")`
- **`compatible` matching**: check if a node's `compatible` list contains a given string
- **Node path walking**: traverse `/soc/serial@*`, `/soc/ethernet@*`, etc.
- **`#address-cells` / `#size-cells` propagation**: needed to correctly parse `reg` tuples

### 4001.2: Discovered Devices

Parse and store discovered addresses in a `FdtConfig` struct populated during boot:

| Property | FDT Path | Fallback |
|----------|----------|----------|
| UART base | `/soc/serial@*` (compatible `"snps,dw-apb-uart"`) | `board.uart_base` |
| PLIC base | `/soc/interrupt-controller@*` (compatible `"sifive,plic-1.0.0"`) | `board.plic_base` |
| Timer freq | `/cpus/timebase-frequency` | `board.timer_freq` |
| RAM regions | `/memory@*` reg | `board.ram_base` + 256 MB |
| CPU count | `/cpus/cpu@*` count | 4 |
| Ethernet | `/soc/ethernet@*` (compatible `"starfive,jh7110-dwmac"`) | none |
| MMC | `/soc/mmc@*` (compatible `"starfive,jh7110-mmc"`) | none |

### 4001.3: Integration with Boot

In `boot.zig:riscv64KernelMain`:
1. Parse full FDT (a1 register = FDT pointer, already passed)
2. Store results in global `fdt_config: FdtConfig`
3. Serial init uses `fdt_config.uart_base` (or board fallback)
4. PMM uses `fdt_config.ram_regions`
5. PLIC uses `fdt_config.plic_base`
6. Timer uses `fdt_config.timer_freq` for interval calculation

### 4001.4: CPU Topology

Parse `/cpus` to discover:
- Hart IDs and their ISA strings (filter out harts without `"rv64"` — the S7 monitor core is rv32)
- `timebase-frequency` property (JH7110: 4 MHz vs QEMU: 10 MHz)
- Pass valid hart list to SMP init instead of scanning 0-15 blindly

## Files Modified

| File | Change |
|------|--------|
| `src/arch/riscv64/fdt.zig` | Major expansion: string block, property lookup, compatible matching |
| `src/arch/riscv64/boot.zig` | Use FdtConfig for all hardware addresses |
| `src/serial.zig` | Accept UART base from FDT |
| `src/arch/riscv64/plic.zig` | Accept PLIC base from FDT |
| `src/arch/riscv64/smp.zig` | Use FDT cpu list instead of 0-15 scan |

## Verify

1. QEMU virt: FDT discovery matches hardcoded values (no regression)
2. Dump FDT contents via serial on Mars (print discovered addresses)
3. Timer interval correct with FDT-discovered timebase frequency

## Depends On

- Phase 4000 (board config provides fallbacks)
