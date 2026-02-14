# Phase 21: Init Process (PID 1) — DONE

## Goal

Move all service/process spawning out of the kernel into a userspace init
program. The kernel's only job at startup is: init hardware, load init from
initrd, run it. Init handles everything else.

## What Was Implemented

### Kernel-side init spawning (`src/main.zig: spawnInit()`)
- Kernel finds "init" in initrd via `initrd.findFile("init")`
- Creates process, loads ELF into its address space
- Allocates 8KB user stack mapped at USER_STACK_TOP
- Sets parent_pid=null (kernel-spawned), inherits root namespace
- Scheduler picks up PID 1 as first ready process

### Kernel initrd file server (`src/initrd.zig: mountFiles()`)
- Each initrd file gets a kernel-backed IPC channel
- Channels mounted at `/boot/<filename>` in root namespace
- Plan 9 ethos: init accesses programs as files via open/read
- `sysRead()` handles kernel-backed channels directly (memcpy, no IPC round-trip)

### Init program (`cmd/init/main.zig`)
- Minimal PID 1: announces itself, enters wait-loop for children
- SMF-style: will restart critical services on crash (future)
- Exits cleanly when no children remain

### Build integration (`build.zig`)
- Freestanding x86_64 target for userspace programs
- `fornax` module (lib/fornax.zig) shared across userspace
- Init compiled as ELF, packed into INITRD by mkinitrd

## Architecture Decisions

- **Plan 9 style**: Init accesses initrd files through the namespace (`/boot/`),
  not raw memory. Everything is a file.
- **Kernel-backed channels**: Kernel serves file reads directly for initrd data,
  avoiding the need for a separate file server process at this stage.
- **SMF-style lifecycle**: Init's wait-loop is modeled after Solaris SMF —
  monitor children, restart critical ones on crash (future phases).
- **FMA deferred**: Hardware fault management (Solaris FMA) goes to Phase 400+
  series since it requires hardware abstraction layers.

## Verify

1. `zig build x86_64` compiles kernel + init + initrd
2. QEMU serial output shows:
   ```
   initrd: 1 files
     init (2514274 bytes)
   initrd: mounted /boot/init
   [init: pid=1 entry=0x10425D0]
   Spawned init (PID 1)
   Kernel initialized.
   init: started (PID 1)
   init: all children exited, halting
   [Process 1 exited with status 0]
   [All processes exited. System halting.]
   ```
3. Full lifecycle: kernel boot → init spawn → init runs → wait loop → clean exit → halt
