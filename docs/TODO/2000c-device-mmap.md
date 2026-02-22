# Phase G2: Device-Backed mmap + Write-Combining

## Status: Planning

## Summary

Add a syscall for mapping physical MMIO/VRAM ranges into userspace page tables, with PAT initialization for write-combining memory type and optional 2MB huge page support for large mappings.

## Motivation

GPU drivers need direct MMIO register access from userspace (thousands of register reads/writes per frame). Syscall-per-register is untenable. VRAM also needs to be mapped into the GPU server's address space. Write-combining is critical for VRAM performance (coalesces sequential writes into burst transfers).

## Current State

- `mapMmioRegion()` in `paging.zig` maps physical ranges into kernel higher-half (NO_CACHE, 4K pages)
- Proven working for xHCI USB (BARs above 4GB)
- `SYS_MMAP` (32) exists but only supports anonymous mappings (MAP_ANONYMOUS)
- No PAT initialization, no write-combining, no device-backed mmap

## Implementation

### New Syscall: `SYS_MMAP_DEVICE` (or extend SYS_MMAP)

```
mmap_device(phys_addr: u64, size: u64, flags: u32) -> ?[*]u8
```

Flags:
- `MMAP_NOCACHE` (0x1) — uncacheable (MMIO registers)
- `MMAP_WRITECOMBINE` (0x2) — write-combining (VRAM, framebuffers)
- `MMAP_HUGEPAGE` (0x4) — use 2MB pages when aligned

Behavior:
- Restricted to uid 0 (root) — device mapping is privileged
- Maps `phys_addr..phys_addr+size` into the calling process's page tables
- Returns userspace virtual address (allocated from `process.mmap_next` bump allocator)
- Physical pages are NOT refcounted (device memory, not RAM)

### PAT Initialization

Program MSR 0x277 (IA32_PAT) during boot:
```
PAT entry 0: WB  (06h) — default
PAT entry 1: WT  (04h)
PAT entry 2: UC- (07h)
PAT entry 3: UC  (00h)
PAT entry 4: WB  (06h)
PAT entry 5: WT  (04h)
PAT entry 6: WC  (01h) — write-combining
PAT entry 7: UC  (00h)
```

PTE encodes PAT index via bits: PAT (bit 7), PCD (bit 4), PWT (bit 3):
- UC:  PAT=0, PCD=1, PWT=1 → index 3
- WC:  PAT=1, PCD=1, PWT=0 → index 6
- WB:  PAT=0, PCD=0, PWT=0 → index 0 (default)

Add `Flags.WRITE_COMBINE` and `Flags.UNCACHEABLE` to paging flags.

### Bulk MMIO Mapping with 2MB Huge Pages

For large VRAM mappings (256MB+), 4K pages create 65K+ page table entries. 2MB pages reduce this to 128 entries.

Requirements for 2MB pages:
- Physical address 2MB-aligned
- Virtual address 2MB-aligned
- Set PS (page size) bit in PDE instead of pointing to PT

Add `mapMmioRegionHuge(phys, virt, size)` that uses 2MB pages when alignment allows, falling back to 4K.

### Cleanup on Process Exit

`sysExit` must unmap device-mapped regions. Track device mappings in a small per-process array (max ~8 device mappings per process).

## Files

- Modified: `src/arch/x86_64/paging.zig` — PAT init, WC/UC flags, huge page support
- Modified: `src/syscall.zig` — `SYS_MMAP_DEVICE` or extended `SYS_MMAP`
- Modified: `src/process.zig` — device mapping tracking for cleanup
- Modified: `lib/fornax.zig` or `lib/c/fornax.h` — userspace wrapper

## Testing

- Userspace process maps MMIO BAR of a known PCI device (e.g., virtio), reads device ID via pointer dereference
- Write-combining flag applied correctly (verify via PTE dump)
- Process exit cleans up device mappings
- Non-root process gets permission denied

## Dependencies

- Phase G0 (BAR size probing — need to know how much to map)

## Estimated Size

~200-300 lines total.
