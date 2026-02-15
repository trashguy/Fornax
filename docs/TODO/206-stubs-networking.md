# Phase 206: Permission Stubs & Networking

## Status: Planned

## Goal

Placeholder permission commands (until Phase 150 + persistent FS) and an `ip` command for network info.

## Depends On

- Phase 24 (shell) — done

---

## 206.1–206.3: `cmd/chmod/main.zig`, `cmd/chown/main.zig`, `cmd/chgrp/main.zig` (NEW — ~15 lines each)

Stub commands that print `"<cmd>: not yet implemented (no permission model)"` and exit 0. Placeholders until Phase 150 (login/auth) + persistent FS with metadata lands. The `Stat._reserved[56]` is reserved for future mode/uid/gid/timestamps.

## 206.4: `cmd/ip/main.zig` (NEW — ~40 lines)

`ip` — display network config. Add `/net/status` path handling in `src/net/netfs.zig` (~20 lines) that returns MAC/IP/gateway as text. Command reads and prints it.

---

## Files

| File | Change |
|------|--------|
| `cmd/chmod/main.zig` | New file (stub) |
| `cmd/chown/main.zig` | New file (stub) |
| `cmd/chgrp/main.zig` | New file (stub) |
| `cmd/ip/main.zig` | New file |
| `src/net/netfs.zig` | Add `/net/status` handler (~20 lines) |
| `build.zig` | Add 4 build targets + initrd entries |

**Phase 206 total: ~85 lines, 4 new files + minor netfs addition.**

---

## Verify

1. `ip` → shows 10.0.2.15
2. `chmod 755 /tmp/x` → prints "not yet implemented"
3. `chown root /tmp/x` → prints "not yet implemented"
