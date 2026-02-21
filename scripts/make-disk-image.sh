#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

ARCH="${1:-x86_64}"
IMAGE_NAME="fornax-${ARCH}.img"
IMAGE_SIZE=8192 # MB (8 GB)

case "$ARCH" in
    x86_64)
        EFI_SRC="$PROJECT_DIR/zig-out/esp/EFI/BOOT/BOOTX64.EFI"
        EFI_DEST="::EFI/BOOT/BOOTX64.EFI"
        ;;
    aarch64)
        EFI_SRC="$PROJECT_DIR/zig-out/esp-aarch64/EFI/BOOT/BOOTAA64.EFI"
        EFI_DEST="::EFI/BOOT/BOOTAA64.EFI"
        ;;
    *)
        echo "Usage: $0 [x86_64|aarch64]"
        exit 1
        ;;
esac

if [ ! -f "$EFI_SRC" ]; then
    echo "Error: EFI binary not found at $EFI_SRC"
    echo "Run 'zig build $ARCH' first."
    exit 1
fi

# Check for required tools
for cmd in dd mkfs.fat mmd mcopy; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: '$cmd' not found."
        case "$(uname -s)" in
            Darwin) echo "Install with: brew install mtools dosfstools" ;;
            Linux)  echo "Install with: pacman -S mtools dosfstools  (Arch) / apt install mtools dosfstools  (Debian)" ;;
            *)      echo "Install mtools and dosfstools for your platform" ;;
        esac
        exit 1
    fi
done

echo "==> Creating ${IMAGE_SIZE}MB disk image: $IMAGE_NAME"
cd "$PROJECT_DIR"

# Create blank image
dd if=/dev/zero of="$IMAGE_NAME" bs=1M count="$IMAGE_SIZE" 2>/dev/null

# Create FAT32 filesystem (entire image as ESP — simplest approach)
mkfs.fat -F 32 "$IMAGE_NAME"

# Create EFI directory structure and copy binary
mmd -i "$IMAGE_NAME" ::EFI
mmd -i "$IMAGE_NAME" ::EFI/BOOT
mcopy -i "$IMAGE_NAME" "$EFI_SRC" "$EFI_DEST"

echo "==> Done: $IMAGE_NAME"
echo "Write to USB: dd if=$IMAGE_NAME of=/dev/sdX bs=1M (replace sdX with your device)"
