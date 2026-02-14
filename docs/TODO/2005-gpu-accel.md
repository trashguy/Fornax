# Phase 2005 — srv/gpu+ (GPU Command Submission)

## Status: Planned (Stretch)

## Goal
Extends srv/gpu with compute/3D command submission for hardware-accelerated rendering.

## Decisions (open)

- **Target GPU family**: AMD only (matches current PCI infra)? Or also virtio-gpu
  (QEMU virtual GPU, much simpler, great for testing)? virtio-gpu first would
  let us test the command submission path without real hardware.
- **API level**: Expose raw GPU command buffers (like DRM/KMS)? Or provide a
  higher-level 2D acceleration API (blit, fill, composite)? Raw is more
  flexible; high-level is easier for srv/draw to consume.
- **Memory model**: GPU memory allocation needs a real allocator. Does srv/gpu
  manage a pool? Or does the kernel provide a GPU memory allocator? Userspace
  pool in srv/gpu is more microkernel.
- **Synchronization**: Fence-based (GPU signals completion, CPU waits)? Or
  implicit sync (each command blocks until done)? Fences are needed for
  pipelining but add complexity. Implicit sync for MVP.

## Provides
- `/dev/gpu/cmd` — submit GPU command buffers
- `/dev/gpu/mem` — GPU memory allocation
- `/dev/gpu/fence` — synchronization primitives

## Enables
- Hardware-accelerated 2D rendering (blit, fill via GPU)
- OpenGL/Vulkan backends (future)
- GPU compute (OpenCL, future)

## Notes
This is the hard phase. Requires deep AMD GPU ISA knowledge.
Can be deferred — CPU rendering is sufficient for everything through Phase 2007.

## Dependencies
- Phase 2000: srv/gpu
