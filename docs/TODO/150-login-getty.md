# Phase 150: Login / Getty / Users & Groups

## Status: Done

## Goal

Add authentication, user identity, and multi-user support. Init spawns login on each VT, which authenticates against `/etc/passwd` and spawns the user's shell with proper uid/gid.

## Depends On

- Phase 24 (shell) — done
- Phase 215 (virtual consoles) — done

---

## Implementation Summary

### Authentication

- `cmd/login/main.zig` — prompts for username/password, authenticates against `/etc/passwd`, calls `setuid(uid, gid)`, execs user's shell
- `lib/crypt.zig` — FNV-1a salted password hashing (`$fx$` format)
- `lib/passwd.zig` — `/etc/passwd` parser (format: `user:hash:uid:gid:gecos:home:shell`)
- `lib/group.zig` — `/etc/group` parser
- Root has `x` hash (no password check)

### Kernel Support

- SYS 30 `setuid(uid, gid)` — sets `Process.uid` and `Process.gid`
- SYS 31 `getuid` — returns packed `uid | (gid << 16)`
- `Process.uid` (u16) and `Process.gid` (u16) fields, inherited by children via `sysSpawn`

### Init + VT Integration

- Init spawns login on each VT (0-3) with respawn loop
- Login reads credentials, authenticates, sets uid/gid, execs shell
- Shell displays dynamic prompt: `user@fornax#` (root) or `user@fornax$` (normal)
- HOME/USER/PWD environment set from passwd entry

### User Management Commands

- `adduser` — creates new user (appends to /etc/passwd)
- `su` — switch user (re-authenticate + setuid + exec shell)
- `id` / `whoami` — display current user identity
- `chown` / `chgrp` — change file ownership (accepts usernames via passwd lookup)
- `ls -l` — shows owner/group names from passwd/group files

---

## Verify

1. Boot → see login prompt on each VT
2. Login as root (no password) → `root@fornax#` prompt
3. `adduser alice` → create user with password
4. Login as alice → `alice@fornax$` prompt
5. `id` → shows uid/gid
6. Exit shell → login respawns
