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

# Check for GPT signature ("EFI PART" at byte 512)
GPT_SIG=$(dd if="$DISK_IMG" bs=1 skip=512 count=8 2>/dev/null)
if [ "$GPT_SIG" != "EFI PART" ]; then
    MKGPT="$PROJECT_DIR/zig-out/bin/mkgpt"
    if [ ! -f "$MKGPT" ]; then
        echo "==> Building mkgpt..."
        (cd "$PROJECT_DIR" && zig build mkgpt)
    fi
    if [ -f "$MKGPT" ]; then
        echo "==> Creating GPT partition table..."
        "$MKGPT" "$DISK_IMG"
    fi
fi

# Check for FXFS at partition 1 start (LBA 2048 = byte 1048576)
FXFS_SIG=$(dd if="$DISK_IMG" bs=1 skip=1048576 count=8 2>/dev/null)
if [ "$FXFS_SIG" != "FXFS0001" ]; then
    MKFXFS="$PROJECT_DIR/zig-out/bin/mkfxfs"
    if [ ! -f "$MKFXFS" ]; then
        echo "==> Building mkfxfs..."
        (cd "$PROJECT_DIR" && zig build mkfxfs)
    fi
    if [ -f "$MKFXFS" ]; then
        # Get partition end from GPT: LBA 2048 to last_usable_lba
        # For a 64 MB disk (131072 sectors), partition ends at sector 131038
        # Size = (131038 - 2048 + 1) * 512 bytes
        DISK_SIZE=$(stat -c%s "$DISK_IMG" 2>/dev/null || stat -f%z "$DISK_IMG" 2>/dev/null)
        PART_OFFSET=1048576
        # Partition size = disk_size - offset - backup GPT overhead (33 sectors)
        PART_SIZE=$(( DISK_SIZE - PART_OFFSET - 33 * 512 ))
        echo "==> Formatting partition 1 with fxfs (offset=$PART_OFFSET, size=$PART_SIZE)..."
        "$MKFXFS" "$DISK_IMG" --offset "$PART_OFFSET" --size "$PART_SIZE"
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
