# Phase 1012 — Container Orchestration to Userspace [COMPLETED]

## Status

**Completed.** Implemented ahead of Phase 1011 (dekernel net) since it had no hard dependency on network dekerneling.

## Depends On

Phase 1002 (container system). Originally listed as depending on Phase 1011, but the migration was independent of network dekerneling.

## Problem

Container lifecycle management is embedded in the kernel:
- `src/container.zig` — container struct, allocate/start/stop/destroy, process tracking
- `src/syscall/container.zig` — `sysCntrOp` (op=0 start, op=1 stop, op=2 destroy, op=3 exec, op=4 start_netd)
- `src/devfiles.zig` — `cntrRead()`/`cntrWrite()` handlers for `/cntr/*` virtual files
- `src/syscall/fs.zig` — `/cntr/*` path interception with `FdType.cntr` and `CntrFdKind`
- `src/process.zig` — `FdType.cntr`, `CntrFdKind`, `allocCntrFd()`

This is ~800 lines of kernel code for what is fundamentally a policy decision (container
lifecycle, namespace setup, compat mode selection, netd spawning) that belongs in userspace.

The `cmd/fnx` tool currently uses `sysCntrOp` to drive everything. It should instead be an
IPC server that owns `/cntr/` and uses lightweight kernel primitives.

## Solution

### New Kernel Primitives

Replace the monolithic `sysCntrOp` (SYS 40) with two composable primitives:

#### `sysSpawn(elf_ptr, elf_len, group_id, flags)` → pid

Creates a new process in **blocked** state. Does not make it runnable.
- Loads ELF, allocates address space, allocates kernel + user stacks
- Assigns the process to process group `group_id` (0 = host group)
- `flags`: `SPAWN_COMPAT_LINUX = 1` (sets compat=1)
- Returns PID of blocked process
- Reuses SYS 19 (`.spawn`), extending it. Current `sysSpawn` already creates processes;
  this adds group_id and flags parameters (currently unused arg slots)

#### `sysProcSetup(pid, op, arg0, arg1)` → 0 or error

Configures a blocked process before making it runnable. Ops:

| Op | Name | Args | Effect |
|----|------|------|--------|
| 0 | MOUNT | path_ptr, channel_id | Mount in child's namespace |
| 1 | SETFD | child_fd, parent_fd | Copy parent's fd → child's fd table |
| 2 | SETCOMPAT | mode, 0 | Set compat mode (0=fornax, 1=linux) |
| 3 | SETQUOTA | pages, children | Set resource quotas |
| 4 | READY | 0, 0 | Mark process runnable (must be last) |
| 5 | SETARGV | argv_ptr, 0 | Copy argv from caller's memory to child stack |
| 6 | SETGROUP | group_id, 0 | (Re)assign process group |

Uses a new SYS number (46 = `proc_setup`).

### Process Groups (replaces Containers)

`src/container.zig` shrinks to `src/process_group.zig`:

```zig
pub const ProcessGroup = struct {
    id: u8,
    active: bool,
    process_count: u16,
    pages_used_total: u32,
    quotas: process.ResourceQuotas,
    lock: SpinLock,
};
```

No name, no rootfs path, no compat mode, no netd_pid, no state machine, no IP address.
Just quota tracking + group kill. All policy lives in fnx.

### fnx as IPC Server

`cmd/fnx/main.zig` becomes an IPC server registered at `/cntr/`:

```
/cntr/clone          → allocate group, return ID
/cntr/N/ctl          → write commands (name, rootfs, compat, start, stop, destroy, exec, ...)
/cntr/N/status       → read container status
/cntr/N/procs        → read process list
```

The server:
1. Receives IPC open/read/write/close messages
2. Maintains container metadata in userspace (name, rootfs, compat, state, netd pid, IP)
3. Uses `sysSpawn` + `sysProcSetup` to create container processes
4. Uses `sysSpawn` to launch container netd instances
5. Mounts `/net/` in child namespace via `sysProcSetup(MOUNT)`

### fnx → fay package

Move `cmd/fnx/` to `../fornax-core/fnx/` as a fay package. The build system installs it
like any other fay package. Remove the `-Dcontainers` build gate — fnx is always available
as an optional userspace tool.

## Files Deleted

None (just shrunk/rewritten).

## Files Modified

### Kernel

| File | Change |
|------|--------|
| `src/container.zig` | Rename to `src/process_group.zig`. Strip to: id, active, quotas, process_count, pages_used, lock. Remove name/rootfs/compat/state/netd_pid/net_ip/cmd fields. Remove start/stop/destroy/findByName. Keep: alloc/free/addProcess/removeProcess/addPages/subPages/canAlloc/groupKill |
| `src/syscall/container.zig` | Replace `sysCntrOp` with `sysProcSetup`. Remove ELF loading, namespace setup, argv layout, netd spawning. Just dispatch on op to configure a blocked process |
| `src/syscall/root.zig` | Replace `.cntr_op` dispatch with `.proc_setup → sysProcSetup`. Add `SYS.proc_setup = 46`. Extend `.spawn` handler to accept group_id + flags |
| `src/process.zig` | Remove `FdType.cntr`, `CntrFdKind`, `allocCntrFd()`, cntr FdEntry fields. Add `group_id: u8` field (replaces `container_id`). Keep `compat` field (set via `sysProcSetup(SETCOMPAT)`) |
| `src/devfiles.zig` | Remove `cntrRead()`, `cntrWrite()` |
| `src/syscall/fs.zig` | Remove `/cntr/*` path interception and `FdType.cntr` handling in sysRead/sysWrite/sysClose/sysStat |
| `src/main.zig` | Replace `container.init()` with `process_group.init()` |
| `lib/syscall.zig` | Add `proc_setup()` wrapper. Extend `spawn()` with group_id + flags params |
| `build.zig` | Remove fnx from `-Dcontainers` gate |

### Userspace

| File | Change |
|------|--------|
| `cmd/fnx/main.zig` | Add IPC server loop. On T_OPEN/T_READ/T_WRITE for `/cntr/*` paths, implement clone/status/ctl/procs handlers. Use `sysSpawn` + `sysProcSetup` for lifecycle. Maintain container metadata array in userspace memory |

## Implementation Steps

### 1. Add Process Groups

Create `src/process_group.zig` with minimal struct. Migrate `container_id` → `group_id`
in process.zig.

### 2. Extend sysSpawn

Add `group_id` (arg3) and `flags` (arg4) to existing `sysSpawn`. Process starts blocked.
Assign to process group.

### 3. Add sysProcSetup

New SYS 46. Validates caller owns the target PID (parent_pid match). Dispatches on op
to configure the blocked process.

### 4. Rewrite fnx as IPC Server

Add server loop: `ipc_recv()` → dispatch → `ipc_reply()`. Maintain per-container state
in userspace arrays. Use new primitives for lifecycle.

### 5. Clean Kernel

Remove `FdType.cntr`, `CntrFdKind`, `allocCntrFd()`, `cntrRead()`, `cntrWrite()`,
`/cntr/*` interception. Remove old `sysCntrOp`.

### 6. Move fnx to fay Package

Move `cmd/fnx/` to `../fornax-core/fnx/`. Update build.zig. Remove `-Dcontainers` gate.

## Container Lifecycle (After)

```
fnx run alpine:latest
  1. fnx opens /cntr/clone → reads group_id
  2. fnx reads rootfs from image, writes ctl commands to set metadata
  3. fnx calls sysSpawn(elf, len, group_id, SPAWN_COMPAT_LINUX) → pid
  4. fnx calls sysProcSetup(pid, MOUNT, "/", rootfs_channel)
  5. fnx calls sysProcSetup(pid, MOUNT, "/net/", netd_channel)
  6. fnx calls sysProcSetup(pid, SETARGV, argv_ptr, 0)
  7. fnx calls sysProcSetup(pid, READY, 0, 0)
  8. fnx calls wait(pid) for foreground, or returns for detached
```

vs. current:
```
fnx run alpine:latest
  1. fnx opens /cntr/clone → reads id
  2. fnx writes ctl commands (name, rootfs, compat)
  3. fnx calls sysCntrOp(0=start, id, elf_ptr, elf_len, argv_ptr) → pid
     (kernel does: load ELF, create process, copy namespace, mount rootfs,
      set compat, set argv/auxv, mount /net/, spawn netd, assign IP, markReady)
  4. fnx calls wait(pid)
```

## Verification

- `fnx run` / `fnx create` / `fnx start` / `fnx exec` / `fnx stop` / `fnx rm` all work
- `fnx ps` / `fnx inspect` report correct status
- `tests/run_container_iperf.py` — container iperf3 works
- Container namespace isolation: processes see only their mounts
- Resource quotas enforced: process group limits memory + children
- `zig build x86_64` / `aarch64` / `riscv64` — cross-arch build check

## Migration Path

The old `sysCntrOp` (SYS 40) is removed. The new `sysProcSetup` (SYS 46) is added.
Since only `cmd/fnx/main.zig` calls `sysCntrOp`, the migration is contained to one file.

The `/cntr/*` file interface is preserved — it just moves from kernel interception to
a dedicated `srv/cntrd` IPC server. Existing scripts that open/read/write `/cntr/*` files
continue to work unchanged.

## Implementation Notes

### What was done

1. **`src/process_group.zig`** (new) — lightweight kernel-side resource tracking replacing `src/container.zig`. ProcessGroup struct with id, active, quotas, process_count, pages_used_total, net_ip, lock.

2. **`container_id` → `group_id`** — mechanical rename across ~30 locations in all 3 arches.

3. **`src/syscall/proc_setup.zig`** (new) — SYS 46 handler with 14 ops. Mount ops accept caller fds (not raw channel_ids) — kernel resolves via `getFdEntry()`.

4. **`sysSpawn` blocked mode** — bit 31 flag in arg3. Returns blocked pid for `proc_setup` configuration. ELF load info stored on Process struct.

5. **`srv/cntrd/main.zig`** (new) — userspace IPC server at `/cntr/`. Handles clone/status/ctl/procs. Tracks container metadata (name, rootfs, compat, state, init_pid, netd_pid).

6. **`cmd/fnx/main.zig`** — rewrote cmdRun/cmdStart/cmdExec/buildRun to use `spawn_blocked` + `proc_setup` primitives. Added helpers: spawnContainerProcess, spawnContainerNetd, setupRootfsMount.

7. **Removed old code** — deleted `src/container.zig`, `src/syscall/container.zig`, `cntrRead/cntrWrite` from devfiles, `/cntr/*` interception from fs.zig, `FdType.cntr`/`CntrFdKind`/`allocCntrFd` from process.zig, CNTR_* constants from lib/syscall.zig.

8. **Build system** — added cntrd build target for all 3 arches.

### Key design decisions during implementation

- **fd-based mount ops**: Original plan had mount ops taking raw channel_ids, but userspace can't know channel_ids. Changed to accept caller fd indices with kernel-side resolution.
- **Separate cntrd server**: Container metadata (name, rootfs, state, cmd) lives in `srv/cntrd` rather than in fnx itself, so the file interface is always available.
- **net_ip on ProcessGroup**: Added to maintain backward compatibility with sysSysinfo IP reporting.

### Files deleted
- `src/container.zig`
- `src/syscall/container.zig`

### Build verification
All 3 architectures (x86_64, aarch64, riscv64) build cleanly.
