#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

KERNEL="$PROJECT_DIR/zig-out/esp-riscv64/fornax-riscv64"
INITRD="$PROJECT_DIR/zig-out/esp-riscv64/INITRD"

# Build if not already built (use `make run-riscv64` to build+run).
if [ ! -f "$KERNEL" ]; then
    echo "==> Building riscv64 kernel..."
    zig build riscv64 "$@"
fi

# ── Disk image: always recreate with fresh rootfs ─────────────────────
DISK_IMG="$PROJECT_DIR/fornax-riscv64-disk.img"
ROOTFS_DIR="$PROJECT_DIR/zig-out/rootfs-riscv64"

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
mkdir -p "$ROOTFS_DIR/etc" "$ROOTFS_DIR/tmp" "$ROOTFS_DIR/proc"

# Create placeholder fstab
cat > "$ROOTFS_DIR/etc/fstab" << 'FSTAB'
# /etc/fstab - Fornax filesystem table
# Root (/) and /dev/ are kernel-mounted
FSTAB

# GPT partition table
echo "==> Creating GPT partition table..."
"$MKGPT" "$DISK_IMG"

# Format with fxfs + populate from rootfs
DISK_SIZE=$(stat -c%s "$DISK_IMG" 2>/dev/null || stat -f%z "$DISK_IMG" 2>/dev/null)
PART_OFFSET=1048576
PART_SIZE=$(( DISK_SIZE - PART_OFFSET - 33 * 512 ))
echo "==> Formatting partition 1 with fxfs (offset=$PART_OFFSET, size=$PART_SIZE)..."
"$MKFXFS" "$DISK_IMG" --offset "$PART_OFFSET" --size "$PART_SIZE" --populate "$ROOTFS_DIR"

echo "==> Launching QEMU (OpenSBI + freestanding kernel)..."

# QEMU virt machine includes OpenSBI firmware by default (-bios default).
# The kernel is loaded with -kernel, and the initrd with -device loader
# at the well-known address 0x84000000 (see src/arch/riscv64/boot.zig).
#
# NOTE: QEMU 10.x riscv64 virt has a bug where -kernel + -device <pci>
# triggers "drive with bus=0, unit=0 exists" unless a -drive is present.
# The disk image drive satisfies this requirement.
exec qemu-system-riscv64 \
    -machine virt \
    -cpu rv64 \
    -m 256M \
    -bios default \
    -kernel "$KERNEL" \
    -device loader,file="$INITRD",addr=0x84000000,force-raw=on \
    -nographic \
    -drive file="$DISK_IMG",format=raw,if=none,id=blk0 \
    -device virtio-blk-pci,drive=blk0 \
    -netdev user,id=n0 \
    -device virtio-net-pci,netdev=n0 \
    "$@"
