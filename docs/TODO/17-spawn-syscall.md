# Phase 17: spawn Syscall — DONE

## Goal

Let userspace create new processes. This is the first step toward the kernel
not needing to know what programs exist — userspace decides what to run.

## Decisions (resolved)

- **spawn (not fork)**: No COW needed. Simpler, fits the microkernel model.
- **Buffer-based**: `spawn(elf_ptr, elf_len, fd_map_ptr, fd_map_len)` — userspace
  passes ELF bytes directly. Path-based spawn deferred to Phase 22 when ramfs exists.
- **FD mapping**: Parent specifies which of its fds the child inherits, and at which
  child fd slots. Child also inherits parent's namespace.

## Design

```zig
// Kernel: SYS.spawn = 19
// spawn(elf_ptr, elf_len, fd_map_ptr, fd_map_len) → child pid or error
//
// FdMapping = extern struct { child_fd: u32, parent_fd: u32 };
//
// Validates pointers are in user space, ELF <= 4MB.
// Creates process, clones parent namespace, loads ELF, allocates stack,
// copies FD mappings, returns child PID.
```

## What Was Implemented

- `src/syscall.zig`: Added `spawn = 19` to SYS enum, `FdMapping` struct,
  `sysSpawn()` with full validation and error handling
- `src/process.zig`: Made `MAX_FDS` pub for cross-module access
- `lib/fornax.zig`: Added `spawn = 19`, `FdMapping`, `syscall4` helper,
  `spawn()` wrapper

## Key Design Notes

- ELF reading works because parent's page table is active during syscall
- On failure after `process.create()`, child is marked `.dead` (leak cleanup is future work)
- No wait syscall yet — parent gets child PID but can't wait for exit (Phase 19)

## Verify

1. `zig build x86_64` — compiles without errors
2. QEMU test deferred — no userspace program calls spawn yet (Phase 21: init)
