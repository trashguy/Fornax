# Suggested Commands

## Build
- `zig build x86_64` — Build x86_64 UEFI kernel
- `zig build aarch64` — Build aarch64 UEFI kernel
- `zig build` — Build both architectures
- `make clean` — Remove build artifacts

## Run
- `make run` or `make run-x86_64` — Run in QEMU (x86_64)
- `make run-aarch64` — Run in QEMU (aarch64)

## Disk Images
- `make disk` — Create bootable disk image (x86_64)
