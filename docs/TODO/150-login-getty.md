# Phase 150: Login / Getty

**Moved from phase 25.** Deferred until after networking (TCP, phase 100).

## Goal

Add an authentication layer before the shell. Plan 9-style: authentication
is handled by an auth server (network service), not local `/etc/passwd` files.

## Depends On

- Phase 24 (shell) — done
- Phase 100 (TCP) — needed for auth server communication

## Design (Plan 9-style)

```
init spawns: getty /dev/console

getty:
  1. Print "fornax login: "
  2. Read username
  3. exec login {username}

login:
  1. Contact auth server (factotum-style) over network
  2. Verify credentials
  3. exec /bin/fsh
```

For MVP, login can just accept any username and spawn fsh (no real auth).
Real authentication comes when we have an auth server.

## Decision Points

- **Auth server vs local**: Plan 9 uses factotum + auth server. Do we
  follow that exactly, or start with simple local auth?
- **User identity**: Do we need UIDs/permissions, or just identity for
  namespace separation?

## Verify

1. Boot → see "fornax login: " prompt
2. Type username → see shell prompt
3. Exit shell → getty restarts, shows login prompt again
