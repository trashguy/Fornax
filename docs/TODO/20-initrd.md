# Phase 20: Initial Ramdisk (initrd) — **Done**

## Goal

Decouple userspace binaries from the kernel image. Ship a single ramdisk
image that UEFI loads alongside the kernel. The kernel can find and load
programs from it by name.

## Decisions Made

- **Format**: Fornax-native flat namespace image (FXINITRD), not tar/cpio.
  Dead-simple: 8-byte magic + u32 count + entries (64-byte name + offset +
  size) + file data. Trivial to parse, trivial to pack.
- **Who parses**: Kernel provides `initrd.findFile(name)` lookup API.
  Returns a `[]const u8` slice into the mapped image. No file server needed
  yet — direct memory access since UEFI loaded it into RAM.
- **UEFI loading**: `boot.zig` loads `\EFI\BOOT\INITRD` via Simple File
  System protocol before ExitBootServices. Optional — boot proceeds without it.

## What Was Implemented

### Image format (`src/initrd.zig`)
- Magic: `FXINITRD` (8 bytes)
- Header: u32 entry_count, then Entry[count]
- Entry: 64-byte null-padded name + u32 offset + u32 size (72 bytes)
- `initrd.init(base, size)` — validates and indexes the image
- `initrd.findFile(name)` — returns `?[]const u8` slice

### UEFI loader (`src/boot.zig`)
- `loadInitrd()` uses SimpleFileSystem + File protocols
- Allocates as `.loader_data` (persists after ExitBootServices)
- `BootInfo` extended with `initrd_base` and `initrd_size`

### Pack tool (`tools/mkinitrd.zig`)
- Host-side tool: `mkinitrd <output> [file1 file2 ...]`
- Integrated into `build.zig` — packs `sysroot/` contents
- Empty sysroot produces valid 12-byte empty image (0 entries)
- `zig build x86_64` produces both BOOTX64.EFI and INITRD on ESP

### Build integration (`build.zig`)
- mkinitrd compiled for host, runs as build step
- Scans `sysroot/` directory for files to pack
- INITRD installed to `zig-out/esp/EFI/BOOT/INITRD`

## Verify

1. `zig build x86_64` produces INITRD alongside kernel — **verified**
2. Empty sysroot produces valid empty initrd — **verified**
3. Files in sysroot/ are packed with correct format — **verified** (hex dump)
4. UEFI loads initrd and kernel can look up files — needs QEMU test
