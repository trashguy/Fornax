# Phase 4000: Milk-V Mars Build Target

## Status: Complete

## Goal

Add `-Dboard=milkv-mars` build option to produce a kernel binary targeting the StarFive JH7110 SoC (Milk-V Mars). Establish the board configuration pattern for real RISC-V hardware.

## Background

Fornax's RISC-V target currently hardcodes QEMU virt addresses (UART 0x10000000, PLIC 0x0C000000, ECAM 0x30000000). The Milk-V Mars uses a StarFive JH7110 SoC with different peripherals and memory map. The build system needs a board selection mechanism that conditionally compiles board-specific constants and drivers.

Reference SDK: https://github.com/milkv-mars/mars-buildroot-sdk

## Implementation

### 4000.1: Board Config Module

Create `src/arch/riscv64/board/` with per-board configuration:

```
src/arch/riscv64/board/
    qemu_virt.zig      # current defaults (UART 0x10000000, etc.)
    milkv_mars.zig     # JH7110 constants, excluded harts, clock rates
    board.zig          # comptime switch on build option
```

`board.zig` selects the active board at comptime:

```zig
const config = @import("config");
pub const active = switch (config.board) {
    .qemu_virt => @import("qemu_virt.zig"),
    .milkv_mars => @import("milkv_mars.zig"),
};
```

Each board module exports:
- `uart_base: u64` — fallback if FDT discovery fails
- `plic_base: u64` — fallback if FDT discovery fails
- `timer_freq: u32` — timebase frequency (QEMU: 10 MHz, JH7110: 4 MHz)
- `excluded_harts: []const u8` — harts to skip during SMP (JH7110 S7 monitor core)
- `ram_base: u64` — default RAM base
- `kernel_load_addr: u64` — where OpenSBI places the kernel
- `has_pci_ecam: bool` — whether raw ECAM is available (false for JH7110, needs PLDA init)
- `drivers: []const Driver` — board-specific drivers to include (dwmmc, dwmac, etc.)

### 4000.2: Build System Changes (`build.zig`)

Add build option:
```
-Dboard=<qemu-virt|milkv-mars>  (default: qemu-virt)
```

Pass board selection to kernel compilation as a build-time config module. When `milkv-mars` is selected:
- Include JH7110 clock/reset driver source
- Include DW-MMC, DW-GMAC driver source
- Exclude virtio drivers (or keep as fallback)
- Adjust linker script if load address differs

### 4000.3: Replace Hardcoded Addresses

Audit all RISC-V arch files for hardcoded QEMU addresses and replace with `board.active.*` references:
- `src/serial.zig` — UART_BASE
- `src/arch/riscv64/plic.zig` — PLIC_BASE
- `src/arch/riscv64/pci.zig` — ECAM_BASE
- `src/arch/riscv64/boot.zig` — RAM defaults, initrd address
- `src/arch/riscv64/smp.zig` — hart iteration range, excluded harts

### 4000.4: Linker Script

Verify `kernel.ld` load address (0x80200000) works for Mars. JH7110 OpenSBI typically loads payloads at 0x40200000 — if different, the board config must override or a separate linker script is needed.

Check Mars U-Boot `boot_targets` and `kernel_addr_r` to confirm actual load address.

## Files Modified

| File | Change |
|------|--------|
| `build.zig` | Add `-Dboard` option, conditional driver inclusion |
| `src/arch/riscv64/board/board.zig` | New: comptime board selector |
| `src/arch/riscv64/board/qemu_virt.zig` | New: extract current QEMU defaults |
| `src/arch/riscv64/board/milkv_mars.zig` | New: JH7110 constants |
| `src/serial.zig` | Use `board.active.uart_base` |
| `src/arch/riscv64/plic.zig` | Use `board.active.plic_base` |
| `src/arch/riscv64/pci.zig` | Use `board.active` or gate on `has_pci_ecam` |
| `src/arch/riscv64/smp.zig` | Filter `excluded_harts` |
| `src/arch/riscv64/boot.zig` | Use board defaults for RAM base/size fallback |

## Verify

1. `zig build riscv64` still produces working QEMU kernel (no regression)
2. `zig build riscv64 -Dboard=milkv-mars` compiles without errors
3. Board config values are correct at comptime (test with `@compileLog`)

## Depends On

- None (first phase in series)
