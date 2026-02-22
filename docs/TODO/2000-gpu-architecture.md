# Phase 2000: GPU Architecture Overview

## Status: Planning

## Summary

Three-tier GPU support architecture: kernel primitives (Phases G0-G4), core GPU server with generic backends (Phase G5), and vendor-specific AMD backends in a separate `fornax-amdgpu` repo (Phases G6-G7).

## Architecture

### Tier 1: Kernel — Minimal Primitives (Microkernel Philosophy)

General-purpose additions to Fornax core (not GPU-specific):
- Enhanced PCI: BAR probing, capabilities, MSI-X (Phase G0)
- IOAPIC + MSI-X interrupt delivery (Phase G1)
- Device-backed mmap + write-combining (Phase G2)
- Plan 9 shared memory segments (Phase G3)
- IRQ forwarding to userspace (Phase G4)

### Tier 2: Core GPU Server — `lib/gpu/` + `srv/gpud/`

Generic GPU server with always-available backends:

```
lib/gpu/
  interface.zig       — /dev/gpu/* protocol types, IPC message parsing (~200 lines)
  memory.zig          — buffer allocation abstraction (~200 lines)
  fence.zig           — fence tracking abstraction (~100 lines)
  backend.zig         — backend vtable/interface (~50 lines)

srv/gpud/
  main.zig            — IPC dispatch, Plan 9 interface, autodetect backend (~400 lines)
  gop.zig             — UEFI GOP framebuffer (always-available fallback) (~100 lines)
  bochs.zig           — Bochs/BGA VGA (QEMU simple display, resolution changes) (~200 lines)
  virtio.zig          — virtio-gpu (QEMU paravirtual 2D) (~500 lines)
```

Autodetect order: virtio-gpu PCI device > Bochs VGA > GOP framebuffer fallback.

Plan 9 interface at `/dev/gpu/`:
```
/dev/gpu/ctl      - RW: init, reset, info, power state
/dev/gpu/draw     - W:  submit command buffers (metadata only, data in shared mem)
/dev/gpu/fence    - R:  completed fence values
/dev/gpu/fb0      - RW: primary framebuffer (shared-memory-backed)
/dev/gpu/vram     - RW: "alloc <size>" / "free <handle>"
/dev/gpu/display  - RW: mode setting, resolution, refresh
```

Core size impact: ~1500 lines, ~20-40 KB binary (ReleaseSmall).

### Tier 3: `fornax-amdgpu` — Separate Repo (fay package)

Vendor-specific AMD GPU driver, installed via `fay install fornax-amdgpu`. Replaces core `gpud` with AMD-capable version. Contains PSP firmware loading, IP Discovery, command ring management, display engine drivers (DCN 3.x/4.x), and Mesa Gallium3D winsys.

Target hardware:
- **Stepping stone**: Ryzen 9 7950X iGPU (RDNA 2, GFX 10.3) — legacy CP, simpler bring-up
- **Primary**: RX 9070 XT (RDNA 4, GFX 12) — MES required, ~70-80% code reuse from RDNA 2

### Tier 4: Mesa Gallium3D (in `fornax-amdgpu`)

Mesa `src/amd/` + `src/gallium/drivers/radeonsi/` with custom Fornax winsys:
- Buffer alloc via IPC to `/dev/gpu/vram`
- Command submit via IPC to `/dev/gpu/draw` (32 bytes metadata; bulk data in shared memory)
- Fence poll via shared memory (zero IPC)
- Shader compilation via ACO (~50K lines C++, no LLVM dependency)
- Cross-compiled on host Linux targeting Fornax musl sysroot

## RDNA 4 vs Older GPUs

| Component | RDNA 2 (GFX 10.3) | RDNA 4 (GFX 12) |
|-----------|-------------------|------------------|
| GPU init | PSP firmware | PSP firmware |
| Register offsets | IP Discovery table | IP Discovery table |
| Command submission | Legacy CP (simpler) | MES required |
| Power management | SMU firmware | SMU firmware |
| Display | DCN 3.x + DMCUB | DCN 4.x + DMCUB |
| Memory | UMA (iGPU) | Dedicated VRAM (16GB) |

## Current Infrastructure Gaps

### PCI (`src/arch/x86_64/pci.zig`)
- **Has**: Bus 0 enumeration, 64-bit BAR detection, `configRead`/`configWrite`, `enableBusMastering()`
- **Missing**: BAR size probing, multi-bus scan, PCI capabilities list traversal, MSI-X

### MMIO/Paging (`src/arch/x86_64/paging.zig`)
- **Has**: `mapMmioRegion()` (4K pages, higher-half, NO_CACHE)
- **Missing**: Device-backed mmap (userspace MMIO), PAT/write-combining, bulk huge-page mapping

### Interrupts (`src/arch/x86_64/interrupts.zig`, `apic.zig`)
- **Has**: 8259 PIC, LAPIC for SMP IPIs, MADT parsing (discovers IOAPIC base but ignores it)
- **Missing**: IOAPIC driver, MSI/MSI-X, interrupt forwarding to userspace

### IPC/Memory (`src/ipc.zig`, `src/syscall.zig`)
- **Has**: 4KB synchronous copy-based IPC, multi-threaded servers, anonymous-only mmap
- **Missing**: Shared memory between processes, device-backed mmap

## Command Submission Fast Path

```
Client (Mesa winsys)                GPU Server                  Hardware

1. Write commands to shared
   memory buffer (zero-copy)
2. IPC: "submit ring=GFX,          3. Receive IPC msg
   ib_gpu_addr=X, size=N,          4. Write IB ptr to ring/MES
   fence=K"                         5. MMIO write: doorbell
                                    6. MSI-X on completion     <- interrupt
                                    7. Update fence in shared mem
8. Poll shared fence value
   (no IPC needed)
```

Total IPC per submission: 1 message, ~32 bytes. All bulk data in shared memory.

## Phase Ordering

### Kernel Prerequisites (Fornax core)
1. **G0**: PCI Enhancement — BAR probing, multi-bus, capabilities, MSI-X parsing
2. **G1**: IOAPIC + MSI-X — interrupt delivery infrastructure
3. **G2**: Device-Backed mmap — userspace MMIO access + write-combining
4. **G3**: Shared Memory — Plan 9 segments for zero-copy buffers
5. **G4**: IRQ Forwarding — userspace interrupt notification

### Core GPU Server (Fornax core)
6. **G5**: Core gpud — GOP/Bochs/virtio-gpu backends, Plan 9 `/dev/gpu/*` interface

### AMD Hardware (`fornax-amdgpu` repo)
7. **G6a**: IP Discovery + PSP Bootstrap (RDNA 2 iGPU)
8. **G6b**: GFX + SDMA (Legacy CP on RDNA 2)
9. **G6c**: SMU + Display (DCN 3.x on RDNA 2)
10. **G6d**: Extend to RDNA 4 (9070 XT — MES, DCN 4.x, discrete VRAM)

### Mesa Integration (`fornax-amdgpu` repo)
11. **G7a**: Software Rasterizer (softpipe, proves cross-compile pipeline)
12. **G7b**: Fornax Winsys (~2000 lines, replaces Linux DRM winsys)
13. **G7c**: ACO Shader Compiler (cross-compile with clang++)
14. **G7d**: Full radeonsi + ACO

## Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Core vs vendor split | `lib/gpu/` + `srv/gpud/` in core; AMD in separate repo | Core gets generic display; vendor logic is a fay package |
| GPU server MMIO | Direct via device-backed mmap | Thousands of register accesses; syscall per access is untenable |
| Early display | UEFI GOP in core gpud | Zero GPU work, immediate visual output, always-available fallback |
| Stepping stone | RDNA 2 iGPU first, then RDNA 4 | Legacy CP (no MES), same PSP framework, 70-80% reuse |
| Shader compilation | ACO (not LLVM) | ~50K lines C++ vs 30M+; no LLVM dependency |
| Shared memory | Plan 9 segments | Explicit, fits architecture, supports VRAM + system RAM |
| Command buffers | Shared memory + 32-byte IPC | Zero-copy for bulk data |

## Risk Summary

| Risk | Severity | Mitigation |
|------|----------|------------|
| No MSI-X in kernel | Showstopper | Must implement (Phase G1) |
| No device-backed mmap | Showstopper | Must implement (Phase G2) |
| No shared memory | Showstopper for Mesa | Must implement (Phase G3) |
| PSP firmware loading | High | Careful port from Linux psp_v13_0.c / psp_v14_0.c |
| RDNA 4 firmware blobs | High | Need latest linux-firmware; Navi 48 is very new |
| MES initialization (RDNA 4) | High | Required for GFX 12; no legacy fallback |
| VRAM BAR above 4GB | Medium | `mapMmioRegion()` handles this; needs bulk mapping extension |
| C++ cross-compilation | Medium | Need clang++ targeting musl for ACO |

## Supersedes

- `2000-gpu.md` (removed)
- `2001-draw.md` (removed)
- `2002-input.md` (removed)
- `2004-native-apps.md` (removed)
- `2005-gpu-accel.md` (removed)

## Related Docs (Future Work)

- `2003-wm.md` — window manager (depends on GPU server)
- `2006-wayland-bridge.md` — sommelier in POSIX realm
- `2007-chrome.md` — Chrome via Wayland bridge
