# Phase G5: Core GPU Server

## Status: Planning

## Summary

Implement `lib/gpu/` framework library and `srv/gpud/` server with three generic backends: UEFI GOP framebuffer (always-available fallback), Bochs/BGA VGA (QEMU simple display with resolution changes), and virtio-gpu (QEMU paravirtual 2D — validates full kernel infrastructure).

## Motivation

Provides display output through Plan 9 `/dev/gpu/*` interface before any vendor-specific GPU driver exists. The virtio-gpu backend is the single most important de-risking step — it exercises PCI enumeration, MSI-X, device mmap, shared memory, and IRQ forwarding all together in QEMU.

## Architecture

### `lib/gpu/` Framework (~550 lines)

```
lib/gpu/
  interface.zig   — /dev/gpu/* protocol types, IPC message constants (~200 lines)
  memory.zig      — buffer handle allocation/tracking abstraction (~200 lines)
  fence.zig       — fence sequence number tracking (~100 lines)
  backend.zig     — backend vtable interface (~50 lines)
```

Backend vtable:
```zig
const Backend = struct {
    init: *const fn (self: *Backend) bool,
    getInfo: *const fn (self: *Backend, buf: []u8) usize,
    setMode: *const fn (self: *Backend, width: u32, height: u32) bool,
    getFramebuffer: *const fn (self: *Backend) ?[]u32,
    submitDraw: *const fn (self: *Backend, cmd: DrawCmd) bool,
    pollFence: *const fn (self: *Backend, seq: u64) bool,
    deinit: *const fn (self: *Backend) void,
};
```

### `srv/gpud/` Server (~1200 lines)

```
srv/gpud/
  main.zig    — IPC dispatch, /dev/gpu/* Plan 9 interface, autodetect (~400 lines)
  gop.zig     — UEFI GOP backend (~100 lines)
  bochs.zig   — Bochs/BGA VGA backend (~200 lines)
  virtio.zig  — virtio-gpu backend (~500 lines)
```

### Plan 9 Interface

Served via IPC at `/dev/gpu/`:

| File | Mode | Description |
|------|------|-------------|
| `/dev/gpu/ctl` | RW | `init`, `reset`, `info` (backend name, resolution, memory) |
| `/dev/gpu/draw` | W | Submit draw commands (rect fill, blit, etc.) |
| `/dev/gpu/fence` | R | Read latest completed fence value |
| `/dev/gpu/fb0` | RW | Primary framebuffer (shared memory backed) |
| `/dev/gpu/vram` | RW | `alloc <size>` / `free <handle>` — buffer management |
| `/dev/gpu/display` | RW | `mode <W> <H>` / `modes` — mode setting and enumeration |

### Backend: UEFI GOP (`gop.zig`)

- Captures framebuffer physical address + resolution from UEFI boot info
- Maps framebuffer via device mmap (write-combining)
- No mode setting (fixed at UEFI-selected resolution)
- Always available on UEFI systems — the fallback of last resort

### Backend: Bochs/BGA VGA (`bochs.zig`)

- Detects Bochs VGA via PCI (vendor 0x1234, device 0x1111)
- Mode setting via VBE dispi I/O ports (0x01CE/0x01CF)
- Framebuffer at BAR 0
- Supports arbitrary resolutions up to VRAM size
- Default QEMU display device (`-vga std`)

### Backend: virtio-gpu (`virtio.zig`)

- Detects virtio-gpu via PCI (subsystem ID 16)
- Full virtqueue protocol: CTRL_SET_SCANOUT, RESOURCE_CREATE_2D, RESOURCE_ATTACH_BACKING, TRANSFER_TO_HOST_2D, RESOURCE_FLUSH
- MSI-X for completion notifications
- Shared memory for framebuffer resource backing
- Tests the entire kernel infrastructure stack (PCI caps, MSI-X, device mmap, IRQ forwarding)
- QEMU flag: `-device virtio-gpu-pci`

### Autodetect Order

```
1. Probe PCI for virtio-gpu (class 0x03, subsystem 16) → virtio backend
2. Probe PCI for Bochs VGA (0x1234:0x1111) → bochs backend
3. Check UEFI boot info for GOP framebuffer → gop backend
4. No display available → log warning, serve /dev/gpu/ctl with "none" info
```

### Init Integration

`cmd/init/main.zig` spawns gpud after fxfs:
```
spawn gpud with: IPC server fd → 3, device fds as needed
mount at /dev/gpu/
```

## Files

- New: `lib/gpu/interface.zig`, `lib/gpu/memory.zig`, `lib/gpu/fence.zig`, `lib/gpu/backend.zig`
- New: `srv/gpud/main.zig`, `srv/gpud/gop.zig`, `srv/gpud/bochs.zig`, `srv/gpud/virtio.zig`
- Modified: `cmd/init/main.zig` — spawn gpud
- Modified: `build.zig` — add gpud build target

## Testing

| Test | Backend | Validates |
|------|---------|-----------|
| `cat /dev/gpu/ctl` shows backend info | All | Basic IPC + autodetect |
| `echo "mode 1024 768" > /dev/gpu/display` | Bochs | Mode setting |
| Colored rectangle appears in QEMU window | virtio | Full infrastructure (PCI, MSI-X, mmap, IRQ) |
| GOP shows pixels on real UEFI hardware | GOP | Framebuffer fallback |

## Dependencies

- Phase G0 (PCI enhancement — device detection)
- Phase G1 (IOAPIC + MSI-X — virtio-gpu interrupts)
- Phase G2 (Device mmap — framebuffer/MMIO access)
- Phase G3 (Shared memory — framebuffer resource backing for virtio-gpu)
- Phase G4 (IRQ forwarding — virtio-gpu completion notifications)

GOP and Bochs backends can work with just G0 + G2 (no MSI-X or shared memory needed).

## Estimated Size

~1500 lines total. ~20-40 KB binary (ReleaseSmall).
