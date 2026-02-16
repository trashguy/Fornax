# Phase 204: Process & System Management Utilities

## Status: Done

## Goal

Utilities that read from `/proc` to display process and system information. Depends on Phase 200 (`/proc` file tree).

## Depends On

- Phase 200 (/proc file tree)

---

## 204.1: `cmd/ps/main.zig` (NEW — ~70 lines)

`ps` — open `/proc`, read DirEntry list for PIDs. For each PID, open `/proc/N/status`, read text, parse fields. Format table:
```
  PID  PPID  STATE     PAGES
    1     0  running      12
    3     1  blocked       8
```

## 204.2: `cmd/kill/main.zig` (NEW — ~30 lines)

`kill pid` — open `/proc/N/ctl`, write `"kill"`, close. Check return for errors.

## 204.3: `cmd/free/main.zig` (NEW — ~40 lines)

`free` — open `/proc/meminfo`, read text, parse page counts, format:
```
total: 128 MB (32768 pages)
free:   96 MB (24576 pages)
used:   32 MB  (8192 pages)
```

## 204.4: `cmd/df/main.zig` (NEW — ~50 lines)

`df` — open `/` directory, iterate entries, stat each, sum sizes. Show usage.

## 204.5: `cmd/du/main.zig` (NEW — ~60 lines)

`du [path]` — walk directory, stat files, report per-entry size. Recursive with depth limit.

## 204.6: `cmd/top/main.zig` (NEW — ~80 lines)

`top` — keyboard-driven process monitor (no sleep syscall, so: Enter=refresh, q=quit). Raw mode, clear screen via ANSI escape, read `/proc`, format table. Same as `ps` but in a loop.

---

## Files

| File | Change |
|------|--------|
| `cmd/ps/main.zig` | New file |
| `cmd/kill/main.zig` | New file |
| `cmd/free/main.zig` | New file |
| `cmd/df/main.zig` | New file |
| `cmd/du/main.zig` | New file |
| `cmd/top/main.zig` | New file |
| `build.zig` | Add 6 build targets + initrd entries |

**Phase 204 total: ~330 lines, 6 new files. No kernel changes.**

---

## Verify

1. `ps` → process table
2. `free` → memory stats
3. `kill 5` → terminates PID 5
4. `df` → filesystem usage
5. `du /boot` → per-file sizes
6. `top` → live process view, q to quit
