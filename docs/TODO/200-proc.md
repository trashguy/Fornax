# Phase 200: Kernel-Internal `/proc` File Tree

## Status: Done

## Goal

Intercept `/proc/*` paths in `sysOpen`/`sysRead`/`sysWrite` exactly like `/net/*`. No userspace server, no new syscall. The kernel already has all process info in `process.zig`.

## Depends On

- Phase 24 (shell) — done

---

## 200.1: `/proc` directory listing

**File:** `src/syscall.zig` (add `/proc` interception alongside `/net`)

- `open("/proc")` → allocate fd with new `NetFdKind` variant `.proc_dir`
- `read(proc_dir_fd, buf)` → serialize active process PIDs as `DirEntry` structs (same format `ls` already parses)
- Follows exact pattern of `netfs.netOpen()` dispatch

## 200.2: `/proc/N/status` — per-process info

- `open("/proc/5/status")` → fd with `.proc_status` kind, stores target PID
- `read()` → returns text: `pid 5\nppid 2\nstate running\npages 12\n`
- Read from `process.process_table[N]` directly (kernel code, has access)

## 200.3: `/proc/N/ctl` — process control

- `open("/proc/5/ctl")` → fd with `.proc_ctl` kind
- `write(fd, "kill")` → terminate target process (mark zombie, wake parent, clean up fds/pipes)
- Only allowed if caller is parent/ancestor (or no restriction for now — teaching OS)
- This is the Plan 9 way — no `kill` syscall needed

## 200.4: `/proc/meminfo` — system memory

- `open("/proc/meminfo")` → fd with `.proc_meminfo` kind
- `read()` → returns text: `total_pages 32768\nfree_pages 24576\npage_size 4096\n`
- Reads directly from `pmm.free_pages` / `pmm.total_pages`

---

## Files to Modify

| File | Change |
|------|--------|
| `src/syscall.zig` | Add `/proc` interception in `sysOpen`, handlers in `sysRead`/`sysWrite` |
| `src/process.zig` | Add `pub fn getByPid(pid: u32) ?*Process` helper if not exists |
| `lib/syscall.zig` | No changes needed (uses existing open/read/write) |

**Est: ~150 lines added to kernel. Zero new syscall numbers.**

---

## Verify

1. `ls /proc` → lists PIDs of active processes
2. `cat /proc/1/status` → shows PID/state/pages
3. `cat /proc/meminfo` → shows memory stats
4. `echo kill > /proc/5/ctl` → terminates PID 5 (via shell redirect)
