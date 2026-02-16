# Phase 202: File Management Utilities

## Status: Done

## Goal

Pure userspace file management commands. Use existing open/create/read/write/close/stat/remove. FS-agnostic — works against ramfs today, persistent FS tomorrow.

## Depends On

- Phase 24 (shell) — done

---

## 202.1: `cmd/cp/main.zig` (NEW — ~48 lines)

`cp src dst` — open src, create dst, read→write loop in 4 KB chunks, close both.

## 202.2: `cmd/mv/main.zig` (NEW — ~56 lines)

`mv src dst` — copy src to dst (cp logic), then remove src. No atomic rename in kernel.

## 202.3: `cmd/rm/main.zig` — add `-r` flag (~128 lines total)

`rm [-r] file...` — `-r` recursively removes directories by reading entries and deleting children first. Replaces standalone `rmdir`.

## 202.4: `cmd/touch/main.zig` (NEW — ~35 lines)

`touch file...` — try open; if fails, create with flags=0 then close. (No timestamps to update.)

## 202.5: `ln` — DEFERRED

Requires symlink support in the filesystem layer. Revisit after persistent FS.

---

## Files

| File | Change |
|------|--------|
| `cmd/cp/main.zig` | New file |
| `cmd/mv/main.zig` | New file |
| `cmd/rm/main.zig` | Add `-r` recursive directory removal |
| `cmd/touch/main.zig` | New file |
| `build.zig` | Add 3 build targets (cp, mv, touch) |

**Phase 202 total: ~270 lines, 3 new files + 1 modified. No kernel changes.**

---

## Verify

1. `touch /tmp/x && cp /tmp/x /tmp/y && ls /tmp` → shows both files
2. `mv /tmp/y /tmp/z && ls /tmp` → y gone, z present
3. `mkdir /tmp/d && rm -r /tmp/d && ls /tmp` → d gone
