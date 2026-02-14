# Phase 19: wait / exit Process Lifecycle

## Goal

Complete the process lifecycle: parent spawns child, child exits, parent
collects exit status. Without this, exited processes leak (zombie problem)
and parents can't know when children finish.

## Decision Points (discuss before implementing)

- **Blocking vs polling**: Should `wait()` block until a child exits (like Unix
  `waitpid`)? Or should it be non-blocking with a separate "child exited"
  notification via IPC? Blocking is simpler. Non-blocking is more microkernel.
- **What happens to orphans?** When a parent exits before its children:
  1. Re-parent to init (PID 1) — Unix model
  2. Kill the children — simpler, more contained
  3. Children become independent (no parent) — needs careful design
- **Exit codes**: Simple integer? Or richer status (killed by signal, faulted, etc.)?

## What Already Exists

- `exit` syscall exists but just marks process as `.exited`
- No parent-child relationship tracked in Process struct
- No wait mechanism

## Needs

- `parent_pid` field in Process struct
- `children` list or count
- `wait(pid)` syscall — blocks until child exits, returns status
- `exit(status)` — wake parent if blocked in wait, store status
- Zombie state (exited but not yet waited on)

## Verify

1. Parent spawns child, calls wait → blocks
2. Child calls exit(42) → parent unblocks, gets 42
3. Parent exits before child → child gets re-parented (or killed, TBD)
