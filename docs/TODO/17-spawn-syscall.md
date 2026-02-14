# Phase 17: spawn Syscall

## Goal

Let userspace create new processes. This is the first step toward the kernel
not needing to know what programs exist — userspace decides what to run.

## Decision Points (discuss before implementing)

- **fork vs spawn**: Unix uses `fork()` (clone current process, COW pages) then
  `exec()`. Microkernels like L4/seL4 typically use `spawn()` (create new empty
  process, load ELF into it). Fork requires copy-on-write page fault handling.
  Spawn is simpler but less Unix-compatible. Which model fits Fornax?
- **Who provides the ELF bytes?** Options:
  1. Kernel reads from initrd (kernel knows about the ramdisk format)
  2. Userspace reads bytes via IPC to a filesystem server, passes them to a
     `spawn(ptr, len)` syscall
  3. Kernel takes a path string, resolves it through the namespace (like Linux
     `execve("/bin/foo", ...)`)
- **Capability passing**: Should the parent be able to pass file descriptors /
  channels to the child at spawn time? (Plan 9 does this via `rfork` flags)

## Minimal Design (starting point for discussion)

```zig
// Syscall: spawn(elf_ptr, elf_len) -> pid or error
// - Creates a new process with its own address space
// - Loads ELF from the provided userspace buffer
// - Child inherits parent's namespace (or a copy?)
// - Returns child PID to parent
```

## What Already Exists

- `process.create()` — allocates PID, creates address space
- `elf.load()` — parses ELF, maps segments into an address space
- `supervisor.spawnServiceProcess()` — does create+load+stack setup (but from kernel)
- The main gap: no syscall interface, no way for userspace to trigger this

## Verify

1. Userspace program calls `spawn()` with an ELF blob
2. Child process runs, prints to console
3. Parent continues executing after spawn returns
