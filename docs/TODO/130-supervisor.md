# Phase 130: VMS-Style Fault Supervisor

## Status: Done

## Goal

Extend the basic supervisor (Phase 13) into a full VMS-inspired fault supervision system with dependency-aware restart ordering, exponential backoff, health probes, cascade restart, and a ctl interface.

## Depends On

- Phase 13 (basic supervisor — done)
- Phase 200 (/proc — done)

---

## Implementation Summary

### 130.1: Exponential Backoff + Retry Window

`SupervisedService` tracks restart timing:

```zig
last_restart_tick: u64,    // timer tick of last restart
backoff_ticks: u64,        // current backoff delay (doubles each crash)
stable_since: u64,         // tick when service became stable
```

- `INITIAL_BACKOFF` = 2 ticks (~110ms), doubles on each crash, caps at `MAX_BACKOFF` = 540 ticks (~30s)
- `STABILITY_WINDOW` = 1080 ticks (~60s) — if service runs this long without crashing, restart_count and backoff reset
- `timerTick()` handles deferred restarts and stability resets

### 130.2: Dependency Graph

```zig
depends_on: [4]u8,     // indices into services[] array
depends_on_len: u8,
restart_on_dep: bool,  // cascade restart when dependency restarts
```

- `register()` accepts dependency list; init registers partfs → fxfs with dependency edges
- `attemptRestart()` checks all dependencies are alive before spawning
- fxfs depends_on partfs

### 130.3: Health Probes

IPC activity tracking via `updateActivity()` called from `sysIpcReply`:

- `last_ipc_tick` tracks last IPC activity per service
- `HEALTH_WARN_THRESHOLD` / `HEALTH_KILL_THRESHOLD` (~5s without IPC reply) detects hung services
- `checkHealth()` called from `timerTick()` at `HEALTH_CHECK_INTERVAL` intervals

### 130.4: Supervisor Ctl Interface

Exposed via `/proc/supervisor` and `/proc/supervisor/ctl` (kernel-intercepted):

**Read `/proc/supervisor`** — returns text table:
```
NAME        PID  STATE            RESTARTS  BACKOFF  DEPS
partfs        3  running                 0       0  -
fxfs          4  running                 0       0  partfs
```

**Write `/proc/supervisor/ctl`** — commands:
- `restart <name>` — force restart (kills old process, spawns new)
- `stop <name>` — stop without restart
- `start <name>` — start a stopped service
- `reset <name>` — clear restart count and backoff

ProcFdKind `.supervisor` and `.supervisor_ctl` in `src/process.zig`.

### 130.5: Cascade Restart

When a dependency restarts, dependents with `restart_on_dep=true` are also restarted:
- Depth-limited to 3 levels to prevent infinite loops
- `cascadeRestart()` walks the dependency graph

### 130.6: Service State Machine

`ServiceState` enum: `running`, `stopped`, `dead`, `pending_restart`

### Extra Fd Support

`ExtraFd` struct allows services to receive additional fds on restart (e.g., fxfs needs blk device fd). Registered in `main.zig` after initial spawn.

---

## Files Modified

| File | Change |
|------|--------|
| `src/supervisor.zig` | Backoff, dependencies, health probes, cascade, state machine, ctl helpers |
| `src/devfiles.zig` | `supervisorRead()` / `supervisorWrite()` handlers |
| `src/process.zig` | `ProcFdKind.supervisor` / `.supervisor_ctl` variants |
| `src/syscall/fs.zig` | `/proc/supervisor` path interception |
| `src/timer.zig` | `timerTick()` callback |
| `src/main.zig` | Service registration with dependencies after spawn |

---

## Verify

1. Kill fxfs (`echo kill > /proc/N/ctl`) — supervisor restarts it
2. Kill fxfs rapidly — backoff increases (2, 4, 8, ... ticks)
3. Let fxfs run 60s — restart_count resets to 0
4. Kill partfs — fxfs waits for partfs to come back before restarting
5. `cat /proc/supervisor` — shows all services with state and restart counts
6. `echo restart fxfs > /proc/supervisor/ctl` — force restart
7. `echo stop fxfs > /proc/supervisor/ctl` / `echo start fxfs > /proc/supervisor/ctl`
