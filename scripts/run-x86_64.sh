#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

# Build if not already built (use `make run` or `make run-release` to build+run).
if [ ! -f "$PROJECT_DIR/zig-out/esp/EFI/BOOT/BOOTX64.EFI" ]; then
    echo "==> Building x86_64 UEFI kernel..."
    zig build x86_64 "$@"
fi

# Detect platform and find OVMF firmware
OVMF=""
case "$(uname -s)" in
    Darwin)
        for candidate in \
            /opt/homebrew/share/qemu/edk2-x86_64-code.fd \
            /opt/homebrew/share/OVMF/OVMF_CODE.fd \
            /usr/local/share/qemu/edk2-x86_64-code.fd \
            /usr/local/share/OVMF/OVMF_CODE.fd \
            ; do
            [ -f "$candidate" ] && OVMF="$candidate" && break
        done
        INSTALL_HINT="Install with: brew install qemu"
        ;;
    Linux)
        for candidate in \
            /usr/share/edk2/x64/OVMF_CODE.4m.fd \
            /usr/share/edk2/x64/OVMF.4m.fd \
            /usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
            /usr/share/OVMF/OVMF_CODE.fd \
            /usr/share/edk2/ovmf/OVMF_CODE.fd \
            /usr/share/qemu/OVMF.fd \
            ; do
            [ -f "$candidate" ] && OVMF="$candidate" && break
        done
        INSTALL_HINT="Install with: pacman -S edk2-ovmf  (Arch) / apt install ovmf  (Debian) / dnf install edk2-ovmf  (Fedora)"
        ;;
    *)
        INSTALL_HINT="Install OVMF/edk2 for your platform"
        ;;
esac

if [ -z "$OVMF" ]; then
    echo "Error: Could not find OVMF firmware."
    echo "$INSTALL_HINT"
    exit 1
fi

echo "==> Using OVMF: $OVMF"
echo "==> Launching QEMU..."

DISK_IMG="$PROJECT_DIR/fornax-disk.img"
if [ ! -f "$DISK_IMG" ]; then
    echo "==> Creating blank 64 MB disk image..."
    dd if=/dev/zero of="$DISK_IMG" bs=1M count=64 status=none
fi

# Auto-format if disk lacks FXFS magic
if ! head -c 8 "$DISK_IMG" | grep -q "FXFS0001" 2>/dev/null; then
    MKFXFS="$PROJECT_DIR/zig-out/bin/mkfxfs"
    if [ ! -f "$MKFXFS" ]; then
        echo "==> Building mkfxfs..."
        (cd "$PROJECT_DIR" && zig build mkfxfs)
    fi
    if [ -f "$MKFXFS" ]; then
        echo "==> Formatting disk with fxfs..."
        "$MKFXFS" "$DISK_IMG"
    fi
fi

exec qemu-system-x86_64 \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF" \
    -drive format=raw,file=fat:rw:"$PROJECT_DIR/zig-out/esp" \
    -m 256M \
    -serial stdio \
    -device virtio-net-pci,netdev=net0 \
    -netdev user,id=net0 \
    -device virtio-keyboard-pci \
    -drive file="$DISK_IMG",format=raw,if=none,id=blk0 \
    -device virtio-blk-pci,drive=blk0 \
    -no-reboot \
    -no-shutdown
