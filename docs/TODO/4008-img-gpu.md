# Phase 4008: Imagination BXE-4-32 GPU

## Status: Not Started

## Goal

GPU driver for the Imagination Technologies BXE-4-32 MC1 (PowerVR Rogue) in the JH7110. Targets framebuffer output first, then GPU command submission for accelerated rendering.

## Hardware

- Imagination BXE-4-32 MC1 GPU
- Up to 600 MHz clock, default 400 MHz
- MIPS-based firmware processor (2 KB I-cache, 2 KB D-cache)
- Tile-based deferred renderer
- Virtual memory addressing up to 64 GB (GPU MMU)
- System Level Cache (SLC)
- Firmware: `powervr/rogue_36.50.54.182_v1.fw` (124 KiB, in linux-firmware)

Display pipeline:
- VeriSilicon DC8200 display controller
- DW HDMI TX (Synopsys DesignWare HDMI Transmitter)
- Inno HDMI PHY
- VOUTCRG clock domain (`0x295C0000`)

## Driver Landscape

Two reference implementations exist:

### Upstream `drm/imagination` (clean, 32k lines)
- Location: `drivers/gpu/drm/imagination/` in mainline Linux
- License: GPL-2.0
- Does NOT support BXE-4-32 today (supports AXE-1-16M, BXS-4-64, BXM-4-64)
- BUT: same Rogue architecture, same firmware interface, MIPS FW path exists (`pvr_fw_mips.c`)
- Clean, modern DRM driver — best architectural reference

### StarFive DDK `pvrsrvkm` (working, large)
- Location: `drivers/gpu/drm/img/img-rogue/` in StarFive kernel fork (`JH7110_VisionFive2_devel`)
- License: Dual MIT/GPL-2.0 (kernel module source available)
- WORKS with BXE-4-32 — this is what Ubuntu on Mars uses
- Userspace side is proprietary blobs (not usable for Fornax)
- Large codebase (DDK), harder to learn from but has exact BXE-4-32 register values

### Mesa PVR Vulkan
- BXE-4-32 device info uploaded to Mesa, marked "unsupported, not under active development"
- Firmware interface headers available in Mesa source

## Implementation Plan

### Phase 4008a: Display Controller (DC8200 Framebuffer)

Dumb framebuffer — no GPU acceleration, just pixel output to HDMI.

1. Enable VOUTCRG clocks (DC8200 AXI/core/AHB, HDMI master/bit/sys)
2. Deassert VOUT resets
3. Configure DC8200 display controller:
   - Set framebuffer base address, stride, pixel format (XRGB8888)
   - Configure display timing for target resolution (1080p60 or 720p60)
   - Enable output pipeline
4. Configure DW HDMI TX:
   - Set video mode, color depth
   - Enable TMDS output
5. Configure Inno HDMI PHY:
   - Set PLL for pixel clock
   - Enable PHY
6. Allocate framebuffer memory (contiguous physical pages)
7. Expose as `/dev/draw` or similar Fornax device

Reference: StarFive out-of-tree `vs_drv.c`, `vs_dc.c`, `inno_hdmi.c`.

**Known issue**: JH7110 has a circular dependency between HDMI PHY and clock generator. StarFive's out-of-tree driver works around this. Study their approach.

### Phase 4008b: GPU Firmware Loading

Load and boot the Rogue GPU firmware processor:

1. Map GPU MMIO registers into kernel space
2. Load firmware blob (`rogue_36.50.54.182_v1.fw`) from initrd/filesystem
3. Parse firmware header (FW layout, segment addresses)
4. Configure GPU MMU for firmware memory
5. Write firmware segments to GPU-accessible memory
6. Configure MIPS boot registers (entry point, stack)
7. Release MIPS processor reset
8. Poll firmware ready status
9. Verify firmware responds to init command

Reference: upstream `pvr_fw.c` + `pvr_fw_mips.c` for clean firmware loading sequence.

### Phase 4008c: GPU MMU Setup

The GPU has its own MMU (separate from CPU MMU):

1. Allocate page tables for GPU virtual address space
2. Map firmware memory, command buffers, render targets
3. Configure MMU registers (base address, context)
4. Handle GPU page faults

Reference: upstream `pvr_mmu.c` + `pvr_vm.c`.

### Phase 4008d: Command Submission

Submit render/compute jobs to the GPU via firmware:

1. Allocate Circular Command Buffers (CCB/CCCB)
2. Build job descriptors (geometry, fragment, compute)
3. Write commands to CCB
4. Kick firmware to process commands
5. Poll or wait for completion (GPU interrupt via PLIC)
6. Handle GPU hangs and recovery

Reference: upstream `pvr_job.c`, `pvr_queue.c`, `pvr_ccb.c`, `pvr_cccb.c`.

### Phase 4008e: srv/gpu Integration

Integrate with Fornax's GPU server architecture:

1. GPU driver exposes `/dev/gpu` device with modesetting + command submission
2. Connect to existing srv/gpu infrastructure (Phase 2000+)
3. Framebuffer scanout from GPU-rendered surfaces
4. Potentially: simple 2D acceleration (blit, fill) via GPU compute

## Estimated Complexity

| Sub-phase | Lines | Difficulty |
|-----------|-------|------------|
| 4008a Display/HDMI | ~800-1200 | Medium (register bashing, timing tables) |
| 4008b Firmware load | ~400-600 | Medium (firmware format, MIPS boot) |
| 4008c GPU MMU | ~500-800 | Hard (GPU page tables, coherency) |
| 4008d Command submission | ~1000-1500 | Hard (firmware protocol, job descriptors) |
| 4008e Integration | ~300-500 | Medium (Fornax-specific plumbing) |

## Notes

- 4008a (display) can work WITHOUT the GPU — DC8200 can scanout from a CPU-written framebuffer
- 4008b-d are the "real" GPU driver — significant effort, can be deferred
- The upstream `drm/imagination` driver is the primary reference — study it thoroughly before starting
- Extract BXE-4-32 device info and register specifics from the StarFive DDK
- GPU firmware is freely redistributable (already in linux-firmware repo)

## Files Modified

| File | Change |
|------|--------|
| `src/drivers/dc8200.zig` | New: VeriSilicon DC8200 display controller |
| `src/drivers/dw_hdmi.zig` | New: DesignWare HDMI TX |
| `src/drivers/inno_hdmi_phy.zig` | New: Inno HDMI PHY |
| `src/drivers/pvr_rogue.zig` | New: Imagination Rogue GPU driver |
| `src/drivers/pvr_fw.zig` | New: Firmware loading (MIPS boot) |
| `src/drivers/pvr_mmu.zig` | New: GPU MMU management |
| `srv/gpud/main.zig` | Integrate Rogue GPU backend (or new Mars-specific gpud) |

## Verify

- 4008a: HDMI output shows colored rectangle or boot text
- 4008b: Firmware version string printed to serial after boot
- 4008c: GPU can access mapped memory without faults
- 4008d: Simple triangle rendered to framebuffer via GPU
- 4008e: Fornax `/dev/draw` shows GPU-accelerated content

## Depends On

- Phase 4003 (VOUTCRG clocks for display, GPU clocks)
- Phase 4002 (serial for debug)
- Phase 2000 (srv/gpu architecture, for 4008e)
