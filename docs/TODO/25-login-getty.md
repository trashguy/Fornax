# Phase 25: Login / Getty

## Goal

Add an authentication layer before the shell. Getty waits on a TTY, prompts
for a username, hands off to login for password check, login execs the shell.

## Decision Points (discuss before implementing)

- **Do we need this now?** A single-user OS doesn't strictly need login. We
  could just have init spawn the shell directly and add login later. But having
  it establishes the getty→login→shell pipeline that Unix systems use.
- **Users and passwords**: Where are they stored? `/etc/passwd` in the ramfs?
  Hardcoded for now? No passwords at all (just username)?
- **Multiple users**: Do we support multiple UIDs / permission levels, or is
  everyone root? Permissions are a big feature to add.

## Minimal Design (if we do it)

```
init spawns: getty /dev/console

getty:
  1. Print "fornax login: "
  2. Read username
  3. exec login {username}

login:
  1. Print "password: " (optional, could skip for MVP)
  2. Verify credentials (or just accept anything)
  3. exec /bin/sh
```

## Likely Deferral

This phase can be skipped initially. init can just spawn the shell directly
on /dev/console. Come back to this when we want multi-user support or
security boundaries.

## Verify

1. Boot → see "fornax login: " prompt
2. Type username → see shell prompt
3. Exit shell → getty restarts, shows login prompt again
