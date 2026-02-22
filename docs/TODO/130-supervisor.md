# Phase 130: VMS-Style Fault Supervisor

## Status: Not started

## Goal

Extend the basic supervisor (Phase 13) into a full VMS-inspired fault supervision system. The current supervisor can detect crashes, respawn from saved ELF, and give up after max retries. This phase adds dependency-aware restart ordering, exponential backoff, health probes, client reconnection, and a supervision tree — making userspace server crashes truly transparent to clients.

## Depends On

- Phase 13 (basic supervisor — done)
- Phase 200 (/proc — done)

## Background

The current `src/supervisor.zig` provides:
- `SupervisedService` struct (name, elf_data, mount_path, pid, channel_id, restart_count, max_restarts)
- `register()` / `spawnService()` / `handleProcessFault()` / `restartService()`
- Simple linear retry with a hard `max_restarts` cap

What's missing for VMS-grade durability:
- Clients holding open fds to a crashed server get silent errors — no reconnection
- No dependency ordering (restarting fxfs before partfs would break things)
- Fixed retry count with no backoff — transient failures exhaust retries quickly
- No proactive health monitoring — only crash detection
- No supervision hierarchy — flat list, no parent/child relationships
- No ctl interface — can't inspect or control supervisor at runtime

---

## 130.1: Exponential Backoff + Retry Window

Modify `SupervisedService` to track restart timing:

```zig
last_restart_tick: u64,    // timer tick of last restart
backoff_ticks: u64,        // current backoff delay (doubles each crash)
restart_window_start: u64, // start of current retry window
```

- Backoff starts at 100ms, doubles on each crash, caps at 30s
- If the service runs for >60s without crashing, reset `restart_count` and `backoff_ticks` to 0
- `restartService()` defers restart if within backoff window (timer callback triggers actual spawn)

**Files**: `src/supervisor.zig`
**~40 lines changed**

## 130.2: Dependency Graph

Add a dependency field to `SupervisedService`:

```zig
depends_on: [4]?u8,  // indices into services[] array
depends_on_len: u8,
```

- `register()` accepts optional dependency list
- `restartService()` checks that all dependencies are alive before spawning
- If a dependency is dead, defer restart until dependency comes back (re-check on each `handleProcessFault` return)
- Init registers services in order: partfs → fxfs → netd (dependencies encode this)

**Files**: `src/supervisor.zig`, `cmd/init/main.zig` (pass dependency info)
**~60 lines changed**

## 130.3: Client Reconnection

When a server is restarted, its IPC channel is recycled. Clients holding the old channel get errors. Add transparent reconnection:

- `sysIpcSend` detects `R_ERROR` with a "server restarted" code
- Userspace `fx.ipc_send()` retries once on server-restart error (reopen mount path, retry send)
- Supervisor assigns the restarted server the same channel slot when possible
- Kernel `namespace.zig`: after server restart, `mount()` the new channel at the same path

**Files**: `src/supervisor.zig`, `src/ipc.zig`, `src/namespace.zig`, `lib/syscall.zig`
**~80 lines**

## 130.4: Health Probes

Proactive liveness checking via file reads (Plan 9 style):

- Supervisor periodically reads `/mount_path/ctl` from each registered service
- If read times out (>2s) or returns error, treat as fault → same path as crash
- Check interval: 10s per service, staggered (don't probe all at once)
- Implemented as a kernel thread or timer callback in `timer.handleIrq()`
- Health check results visible in `/proc/supervisor`

**Files**: `src/supervisor.zig`, `src/timer.zig`
**~70 lines**

## 130.5: Supervisor Ctl Interface

Expose supervisor state via `/proc/supervisor` (kernel-intercepted, like `/proc/meminfo`):

**Read `/proc/supervisor`** — returns text:
```
NAME        PID  STATE    RESTARTS  BACKOFF  DEPS
partfs        3  running         0       0   -
fxfs          4  running         0       0   partfs
netd          6  running         1     200   -
crond         8  running         0       0   fxfs
```

**Write `/proc/supervisor/ctl`** — commands:
- `restart <name>` — force restart a service
- `stop <name>` — stop without restart
- `start <name>` — start a stopped service
- `reset <name>` — clear restart count and backoff

Add FdType `.proc_supervisor` to `src/syscall.zig` read/write handlers.

**Files**: `src/supervisor.zig`, `src/syscall.zig`
**~100 lines**

## 130.6: Cascade Restart

When a dependency restarts, optionally restart dependents:

- `SupervisedService` gains `restart_on_dep: bool` flag
- If partfs restarts and fxfs has `restart_on_dep=true`, fxfs is also restarted (in order)
- Prevents stale state from surviving a dependency restart
- Cascade is depth-limited (max 3 levels) to prevent infinite loops

**Files**: `src/supervisor.zig`
**~40 lines**

---

## Files

| File | Change |
|------|--------|
| `src/supervisor.zig` | Backoff, dependencies, health probes, cascade, ctl |
| `src/syscall.zig` | `/proc/supervisor` read/write handlers |
| `src/ipc.zig` | Server-restart error code, channel slot recycling |
| `src/namespace.zig` | Re-mount after restart |
| `src/timer.zig` | Health probe timer callback |
| `lib/syscall.zig` | Retry-on-restart in ipc_send wrapper |
| `cmd/init/main.zig` | Pass dependency info to supervisor registration |

**Phase 130 total: ~390 lines across 7 files.**

---

## Verify

1. Kill fxfs (`echo kill > /proc/N/ctl`) → supervisor restarts it, clients reconnect
2. Kill fxfs 3 times rapidly → backoff increases (100ms, 200ms, 400ms)
3. Let fxfs run 60s → restart_count resets to 0
4. Kill partfs → fxfs waits for partfs to come back before restarting
5. `cat /proc/supervisor` → shows all services with state and restart counts
6. `echo restart netd > /proc/supervisor/ctl` → force restart
7. Health probe: make fxfs hang (infinite loop) → supervisor detects timeout and restarts
