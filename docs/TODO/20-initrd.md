# Phase 20: Initial Ramdisk (initrd)

## Goal

Decouple userspace binaries from the kernel image. Instead of `@embedFile`
for each program, ship a single ramdisk blob that UEFI loads alongside the
kernel. The kernel (or an early userspace process) can find and load programs
from it.

## Decision Points (discuss before implementing)

- **Format**: Options:
  1. **tar** — standard, tools exist, easy to pack/unpack on host
  2. **cpio** — Linux uses this for initramfs, slightly simpler than tar
  3. **Custom flat format** — simplest to parse (header + file table + data),
     but non-standard
  4. **Just embed one big tar as @embedFile** — incremental step, still one
     binary but structured internally
- **Who parses it?**
  1. Kernel parses initrd, provides files to userspace via a built-in initrd
     filesystem server
  2. Kernel maps the raw initrd into init's address space, init parses it
     itself (keeps kernel simpler)
- **UEFI loading**: The UEFI boot stub needs to load a second file from the
  EFI system partition. Currently `boot.zig` only loads the kernel itself.

## Minimal Design

```
EFI System Partition:
  /EFI/BOOT/BOOTX64.EFI    (kernel)
  /EFI/BOOT/INITRD          (ramdisk image)

Kernel boot:
  1. UEFI loads kernel + initrd into memory
  2. Kernel receives initrd base address + size via boot info
  3. Kernel (or init) can read files from the initrd
```

## Verify

1. Build produces separate kernel and initrd images
2. UEFI loads both
3. Kernel can find and load `/sbin/init` from the initrd
4. No more `@embedFile("user_hello_elf")` in kernel code
