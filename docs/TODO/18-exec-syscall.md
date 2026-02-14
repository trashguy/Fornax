# Phase 18: exec Syscall

## Goal

Replace the current process's image with a new ELF. Combined with `spawn`,
this enables the classic spawn-then-exec pattern, or a shell can exec directly.

## Decision Points (discuss before implementing)

- **Do we even need exec?** If `spawn` creates a new process from an ELF blob,
  `exec` is only needed for the case where a process wants to replace *itself*
  (e.g., login → shell). We could defer this and use spawn-only initially.
- **Address space teardown**: exec needs to unmap all existing user pages and
  reload. This requires tracking which pages belong to the process (we currently
  don't do this cleanly).
- **What about open file descriptors?** Unix preserves FDs across exec (except
  close-on-exec). Should Fornax?

## Minimal Design

```zig
// Syscall: exec(elf_ptr, elf_len) -> noreturn (or error)
// - Tears down current user address space
// - Loads new ELF
// - Resets stack
// - Jumps to new entry point
// - FDs/namespace: TBD (preserve? close? configurable?)
```

## Verify

1. Process calls exec with a different ELF → old code gone, new code running
2. PID stays the same
3. Parent (if any) still sees the same child PID
