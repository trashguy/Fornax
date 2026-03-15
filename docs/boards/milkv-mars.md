# Milk-V Mars

StarFive JH7110 SoC, 4x SiFive U74 RV64GC cores, 4/8 GiB LPDDR4.

## Status

Fornax boots on the Milk-V Mars with all 4 application cores online, Sv39 paging,
and full PLIC interrupt routing. No userspace devices yet (virtio not available on
real hardware) — JH7110-specific drivers are in progress (phases 4003+).

## Requirements

- Milk-V Mars board (V1.2 or later recommended for DIP boot mode switches)
- USB-to-UART adapter (CP210x, FTDI, or CH341) connected to the 40-pin header UART
- Ethernet cable between host and Mars (direct or via switch)
- Host machine with Zig 0.15.x and Python 3 with pyserial

## Firmware

The stock U-Boot 2021.10 only initializes 4 GiB of RAM. Upstream U-Boot 2025.10+
initializes all 8 GiB. Building and flashing instructions:

### Build U-Boot + OpenSBI

```sh
# Cross toolchain (Arch Linux)
sudo pacman -S riscv64-linux-gnu-gcc riscv64-linux-gnu-binutils swig

# OpenSBI
git clone https://github.com/riscv-software-src/opensbi.git
cd opensbi
make CROSS_COMPILE=riscv64-linux-gnu- PLATFORM=generic FW_TEXT_START=0x40000000

# U-Boot
git clone https://github.com/u-boot/u-boot.git
cd u-boot
git checkout v2026.01  # or latest stable
echo "CONFIG_SYS_SPI_U_BOOT_OFFS=0x100000" >> configs/starfive_visionfive2_defconfig
make CROSS_COMPILE=riscv64-linux-gnu- starfive_visionfive2_defconfig
make CROSS_COMPILE=riscv64-linux-gnu- OPENSBI=../opensbi/build/platform/generic/firmware/fw_dynamic.bin -j$(nproc)
```

**Critical:** `CONFIG_SYS_SPI_U_BOOT_OFFS=0x100000` must be set. The upstream default
(0x0) places U-Boot at the same offset as SPL, bricking the board on SPI boot.

### Flash to SPI NOR

From the U-Boot prompt, with a TFTP server hosting the built binaries:

```
setenv ipaddr <mars-ip>
setenv serverip <host-ip>
sf probe
tftpboot 0x48000000 u-boot-spl.bin.normal.out
sf update 0x48000000 0x0 $filesize
tftpboot 0x48000000 u-boot.itb
sf update 0x48000000 0x100000 $filesize
```

A multi-file TFTP server is included: `sudo python3 scripts/tftp-serve.py /path/to/firmware/`

### SPI NOR flash layout

| Offset | Content |
|--------|---------|
| 0x000000 | SPL (`u-boot-spl.bin.normal.out`) |
| 0x100000 | U-Boot FIT (`u-boot.itb`, includes OpenSBI) |

### Boot mode DIP switches

| GPIO1 | GPIO0 | Mode |
|-------|-------|------|
| 0 (ON) | 0 (ON) | SPI Flash (default) |
| 0 (ON) | 1 (OFF) | SD card |
| 1 (OFF) | 0 (ON) | eMMC |
| 1 (OFF) | 1 (OFF) | UART (XMODEM recovery) |

"ON" on the DIP switch = GPIO low (0). Factory default is both ON (SPI Flash).

### UART recovery (bricked SPI)

If the SPI flash has bad firmware, set both DIP switches to OFF (UART mode),
power cycle, and the boot ROM will output `CCC` (XMODEM handshake):

```sh
# Install XMODEM tools
sudo pacman -S lrzsz

# Send SPL
sudo lrzsz-sx --xmodem u-boot-spl.bin.normal.out < /dev/ttyUSB0 > /dev/ttyUSB0

# Watch for second round of CCC, then send U-Boot
sudo lrzsz-sx --xmodem u-boot.itb < /dev/ttyUSB0 > /dev/ttyUSB0

# Connect and reflash SPI from the recovered U-Boot prompt
sudo picocom -b 115200 /dev/ttyUSB0
```

## Building Fornax

```sh
zig build riscv64 -Dboard=milkv_mars
```

## Booting

The included boot script handles build, TFTP transfer, U-Boot automation, and
serial console:

```sh
sudo ./scripts/mars-boot.py --ip <host-ip> --mars-ip <mars-ip>

# Skip build step
sudo ./scripts/mars-boot.py --no-build --ip <host-ip> --mars-ip <mars-ip>

# Monitor serial only (no boot sequence)
sudo ./scripts/mars-boot.py --monitor

# Log serial output to file
sudo ./scripts/mars-boot.py --no-build --ip <host-ip> --mars-ip <mars-ip> --log boot.log
```

## Known issues

- **USB-serial DTR reset:** Some USB-serial adapters assert DTR on connect, which
  resets the Mars. The boot script disables DTR automatically. If using picocom
  directly, use `--noreset`.
- **USB hubs:** Flaky USB hubs can cause the serial adapter to disconnect during
  boot, triggering DTR resets that look like boot loops. Plug the adapter directly
  into the host.
- **FDT RAM regions:** The new U-Boot FDT includes a 0-size reserved memory region
  before the real RAM. Fornax selects the largest region automatically.
- **Sv39 only:** The SiFive U74 cores only support Sv39 (3-level, 39-bit VA).
  Sv48 SATP writes are silently ignored. User VA space is 256 GiB.
- **Hart 0:** The JH7110 has a 5th hart (S7 monitor core, rv32). It is excluded
  from SMP — only harts 1-4 are U74 application cores.

## Hardware reference

| Peripheral | Address | Driver status |
|-----------|---------|---------------|
| DW APB UART | 0x10000000 | Working (reg-shift=2) |
| PLIC | 0x0C000000 | Working |
| DW GMAC (Ethernet) | 0x16030000 | Planned (phase 4005) |
| DW-MMC (SD/MMC) | 0x16020000 | Planned (phase 4004) |
| PLDA PCIe | 0x940000000 | Planned (phase 4006) |
| Cadence USB3 | 0x10100000 | Planned (phase 4007) |
| IMG BXE-4-32 GPU | — | Planned (phase 4008) |
| SYSCRG (clocks) | 0x13020000 | Planned (phase 4003) |
