#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "==> Building aarch64 UEFI kernel..."
cd "$PROJECT_DIR"
zig build aarch64

DISK_IMG="$PROJECT_DIR/fornax-disk-aarch64.img"
ROOTFS_DIR="$PROJECT_DIR/zig-out/rootfs-aarch64"

# Build host tools (always rebuild to pick up changes)
MKGPT="$PROJECT_DIR/zig-out/bin/mkgpt"
MKFXFS="$PROJECT_DIR/zig-out/bin/mkfxfs"
echo "==> Building mkgpt + mkfxfs..."
(cd "$PROJECT_DIR" && zig build mkgpt mkfxfs)

# Always recreate disk with fresh binaries
rm -f "$DISK_IMG"
echo "==> Creating 64 MB disk image..."
dd if=/dev/zero of="$DISK_IMG" bs=1M count=64 status=none

# Create rootfs staging directories
mkdir -p "$ROOTFS_DIR/etc" "$ROOTFS_DIR/tmp" "$ROOTFS_DIR/proc" "$ROOTFS_DIR/dev" "$ROOTFS_DIR/net" "$ROOTFS_DIR/home"

# Create placeholder fstab
cat > "$ROOTFS_DIR/etc/fstab" << 'FSTAB'
# /etc/fstab - Fornax filesystem table
# Root (/) and /dev/ are kernel-mounted
FSTAB

# Create default /etc/passwd (root has no password)
cat > "$ROOTFS_DIR/etc/passwd" << 'PASSWD'
root:x:0:0:System Administrator:/:/bin/fsh
PASSWD

# Create default /etc/shadow (root has no password)
cat > "$ROOTFS_DIR/etc/shadow" << 'SHADOW'
root:x
SHADOW

# Create default /etc/group
cat > "$ROOTFS_DIR/etc/group" << 'GROUP'
root:x:0:root
users:x:100:
GROUP

# GPT partition table
echo "==> Creating GPT partition table..."
"$MKGPT" "$DISK_IMG"

# Format with fxfs + populate from rootfs
DISK_SIZE=$(stat -c%s "$DISK_IMG" 2>/dev/null || stat -f%z "$DISK_IMG" 2>/dev/null)
PART_OFFSET=1048576
PART_SIZE=$(( DISK_SIZE - PART_OFFSET - 33 * 512 ))
echo "==> Formatting partition 1 with fxfs (offset=$PART_OFFSET, size=$PART_SIZE)..."
"$MKFXFS" "$DISK_IMG" --offset "$PART_OFFSET" --size "$PART_SIZE" --populate "$ROOTFS_DIR"

# Detect platform and find AAVMF/QEMU_EFI firmware
AAVMF=""
case "$(uname -s)" in
    Darwin)
        for candidate in \
            /opt/homebrew/share/qemu/edk2-aarch64-code.fd \
            /opt/homebrew/share/AAVMF/AAVMF_CODE.fd \
            /usr/local/share/qemu/edk2-aarch64-code.fd \
            /usr/local/share/AAVMF/AAVMF_CODE.fd \
            ; do
            [ -f "$candidate" ] && AAVMF="$candidate" && break
        done
        INSTALL_HINT="Install with: brew install qemu"
        ;;
    Linux)
        for candidate in \
            /usr/share/edk2/aarch64/QEMU_CODE.fd \
            /usr/share/edk2/aarch64/QEMU_EFI.fd \
            /usr/share/edk2-armvirt/aarch64/QEMU_CODE.fd \
            /usr/share/edk2-armvirt/aarch64/QEMU_EFI.fd \
            /usr/share/AAVMF/AAVMF_CODE.fd \
            /usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
            ; do
            [ -f "$candidate" ] && AAVMF="$candidate" && break
        done
        INSTALL_HINT="Install with: pacman -S edk2-aarch64  (Arch) / apt install qemu-efi-aarch64  (Debian) / dnf install edk2-aarch64  (Fedora)"
        ;;
    *)
        INSTALL_HINT="Install AAVMF/QEMU_EFI for your platform"
        ;;
esac

if [ -z "$AAVMF" ]; then
    echo "Error: Could not find AAVMF/QEMU_EFI firmware."
    echo "$INSTALL_HINT"
    exit 1
fi

echo "==> Using AAVMF: $AAVMF"
echo "==> Launching QEMU..."

exec qemu-system-aarch64 \
    -machine virt \
    -cpu cortex-a72 \
    -drive if=pflash,format=raw,readonly=on,file="$AAVMF" \
    -drive format=raw,file=fat:rw:"$PROJECT_DIR/zig-out/esp-aarch64" \
    -device ramfb \
    -m 256M \
    -serial stdio \
    -no-reboot \
    -no-shutdown \
    -drive file="$DISK_IMG",format=raw,if=none,id=disk0 \
    -device virtio-blk-pci,drive=disk0 \
    -netdev user,id=net0 \
    -device virtio-net-pci,netdev=net0 \
    "$@"
