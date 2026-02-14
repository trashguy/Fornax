#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "==> Building aarch64 UEFI kernel..."
cd "$PROJECT_DIR"
zig build aarch64

# Find AAVMF/QEMU_EFI firmware
AAVMF=""
for candidate in \
    /opt/homebrew/share/qemu/edk2-aarch64-code.fd \
    /opt/homebrew/share/AAVMF/AAVMF_CODE.fd \
    /usr/share/AAVMF/AAVMF_CODE.fd \
    /usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
    /usr/share/edk2/aarch64/QEMU_EFI.fd \
    /usr/share/edk2-armvirt/aarch64/QEMU_EFI.fd \
    ; do
    if [ -f "$candidate" ]; then
        AAVMF="$candidate"
        break
    fi
done

if [ -z "$AAVMF" ]; then
    echo "Error: Could not find AAVMF/QEMU_EFI firmware."
    echo "Install with: brew install qemu  (includes AAVMF on macOS)"
    echo "Or on Linux: apt install qemu-efi-aarch64"
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
    -no-shutdown
