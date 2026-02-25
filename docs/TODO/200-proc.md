# Phase 200: Kernel-Internal `/proc` File Tree

## Status: Done

## Goal

Intercept `/proc/*` paths in `sysOpen`/`sysRead`/`sysWrite` exactly like `/net/*`. No userspace server, no new syscall. The kernel already has all process info in `process.zig`.

## Depends On

- Phase 24 (shell) — done

---

## Implementation

All `/proc` handling is in `src/devfiles.zig` (`procRead` / `procWrite`), dispatched by `ProcFdKind` stored in each fd.

### 200.1: `/proc` directory listing

- `open("/proc")` → allocate fd with `ProcFdKind.dir`
- `read()` → serializes active process PIDs as `ProcDirEntry` structs (same format `ls` parses)
- Also lists `meminfo` and `supervisor` entries

### 200.2: `/proc/N` — per-process directory

- `open("/proc/5")` → fd with `ProcFdKind.pid_dir`
- `read()` → lists `status` and `ctl` as directory entries

### 200.3: `/proc/N/status` — per-process info

- `open("/proc/5/status")` → fd with `ProcFdKind.status`, stores target PID
- `read()` → returns key-value text:

```
pid 5
ppid 2
state running
pages 12
uid 0
gid 0
core 1
affinity any
vt 0
name fsh
```

Fields: pid, ppid, state (free/running/ready/blocked/zombie/dead), pages, uid, gid, assigned core, core affinity (number or "any"), virtual terminal, process name.

### 200.4: `/proc/N/ctl` — process control (write-only)

Commands written to ctl:

| Command | Effect |
|---------|--------|
| `kill` | Terminate process (exit status 137), kill children, wake waiting parent |
| `stop` | Suspend process (set blocked with no pending_op) |
| `start` | Resume a stopped process (markReady) |
| `killgrp` | Kill all children of target process |
| `wired N` | Pin process to core N |
| `wired any` | Clear core affinity (allow any core) |
| `close N` | Close fd N in target process |

Plan 9 style — no `kill` syscall needed.

### 200.5: `/proc/meminfo` — system memory

- `open("/proc/meminfo")` → fd with `ProcFdKind.meminfo`
- `read()` → returns:

```
total_pages 32768
free_pages 24576
page_size 4096
total_bytes 134217728
free_bytes 100663296
used_pages 8192
```

Reads directly from `pmm.getTotalPages()` / `pmm.getFreePages()`.

### 200.6: `/proc/supervisor` — fault supervisor status

See Phase 130. `ProcFdKind.supervisor` (read) and `.supervisor_ctl` (write).

---

## Files Modified

| File | Change |
|------|--------|
| `src/devfiles.zig` | `procRead()` / `procWrite()` — all `/proc` read/write handlers |
| `src/process.zig` | `ProcFdKind` enum, `FdType.proc`, `allocProcFd()`, `getByPid()` |
| `src/syscall/fs.zig` | `/proc` path interception in `sysOpen` |

**Zero new syscall numbers. Uses existing open/read/write.**

---

## Verify

1. `ls /proc` → lists PIDs of active processes + meminfo + supervisor
2. `cat /proc/1/status` → shows pid/ppid/state/pages/uid/gid/core/affinity/vt/name
3. `cat /proc/meminfo` → shows memory stats (pages + bytes)
4. `echo kill > /proc/5/ctl` → terminates PID 5
5. `echo stop > /proc/3/ctl` / `echo start > /proc/3/ctl` → suspend/resume
6. `echo wired 2 > /proc/3/ctl` → pin to core 2
7. `echo killgrp > /proc/3/ctl` → kill all children
8. `cat /proc/supervisor` → shows supervised services table
