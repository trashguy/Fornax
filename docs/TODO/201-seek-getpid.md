# Phase 201: Implement Declared-but-Unimplemented Syscalls

## Status: Planned

## Goal

These syscalls are already in the `SYS` enum (numbers 6, 8) but return ENOSYS. Implementing them is completing existing design, not adding new surface area.

## Depends On

- Phase 24 (shell) — done

---

## 201.1: `seek` (SYS=6)

**File:** `src/syscall.zig`

`sysSeek(fd, offset, whence)` — update `entry.read_offset`. Whence: 0=SET, 1=CUR.
Needed for `head`/`tail` and correct multi-read patterns.
~25 lines.

## 201.2: `getpid` (SYS=20, new)

**Files:** `src/syscall.zig`, `lib/syscall.zig`, `lib/root.zig`

The one truly new syscall. Returns `proc.pid`. Fundamental — even L4 and Plan 9 have this.
~15 lines total.

## 201.3: `mount` (SYS=8) — optional, deferred

Already declared. Implementation: take channel fd + path, call `proc.ns.mount()`.
**Defer until persistent FS branch merges** — mounting is more relevant when there's something beyond ramfs + initrd to mount.

---

## Verify

1. `getpid` available in `lib/syscall.zig`
2. `seek` no longer returns ENOSYS
