# Phase 19: wait / exit Process Lifecycle — **Done**

## Goal

Complete the process lifecycle: parent spawns child, child exits, parent
collects exit status. Without this, exited processes leak (zombie problem)
and parents can't know when children finish.

## Decisions Made

- **Blocking wait**: `wait(pid)` blocks until child exits, consistent with
  blocking `ipc_recv` pattern. Simpler, fits cooperative scheduler.
- **Kill orphans**: When a parent exits, all children die recursively
  (Plan 9/L4/VMS style). No re-parenting. Clean ownership trees.
- **Exit codes**: `u8` — simple integer, matches existing `exit(status: u8)`.

## What Was Implemented

### Process struct additions (`src/process.zig`)
- `parent_pid: ?u32` — set to current process's pid on `create()`
- `exit_status: u8` — stored on exit for parent to collect
- `waiting_for_pid: ?u32` — which child pid parent is waiting for (0 = any)
- `.zombie` state in `ProcessState` — exited but not yet reaped

### Kernel functions
- `process.killChildren(pid)` — recursive orphan kill
- `process.getProcessTable()` — exposes table for syscall iteration
- `sysWait(pid)` — scan for zombie child (immediate reap) or block
- `sysExit(status)` — store status, kill children, wake parent or zombie

### Userspace (`lib/fornax.zig`)
- `wait(pid: u32) u64` — syscall wrapper

## Verify

1. Parent spawns child, calls wait → blocks
2. Child calls exit(42) → parent unblocks, gets 42
3. Parent exits before child → children killed recursively
