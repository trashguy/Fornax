# Phase 18: exec Syscall — DONE

## Goal

Replace the current process's image with a new ELF. Combined with `spawn`,
this enables the classic spawn-then-exec pattern, or a shell can exec directly.

## Resolved Decisions

- **FDs**: Inherit all — Plan 9 style, no close-on-exec
- **Namespace**: Inherited unchanged (mount table preserved)
- **Address space teardown**: Old PML4 + user pages leaked (matches Phase 17 pattern; cleanup is future work)
- **Failure mode**: Kill process on unrecoverable error (ELF load failure after commit)

## Implementation

- `src/syscall.zig`: `sysExec(elf_ptr, elf_len)` — validates args, creates fresh address space, loads ELF, allocates user stack, swaps process state, calls `scheduleNext()`
- `src/process.zig`: Made `USER_STACK_PAGES` pub
- `lib/fornax.zig`: `exec(elf_data: []const u8) i32` userspace wrapper

### Key insight

During `sysExec`, CR3 still points to old PML4. `elf.load(new_pml4, elf_data)` reads ELF from old user space (accessible) and maps into new PML4. No kernel buffer needed.

## Verify

1. `zig build x86_64` — compiles without errors
2. Process calls exec with a different ELF → old code gone, new code running
3. PID, FDs, and namespace stay the same
