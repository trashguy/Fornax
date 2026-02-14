# Phase 21: Init Process (PID 1)

## Goal

Move all service/process spawning out of the kernel into a userspace init
program. The kernel's only job at startup is: init hardware, load init from
initrd, run it. Init handles everything else.

## Decision Points (discuss before implementing)

- **How much does init do?** Options:
  1. Simple script-like: hardcoded list of services to spawn (like early Unix)
  2. Config-driven: reads `/etc/init.conf` from the initrd
  3. Dependency-based: services declare dependencies, init resolves order
     (like systemd — probably overkill for now)
- **Should init be the supervisor too?** Currently `supervisor.zig` is a kernel
  module that restarts crashed services. Should init take over that role
  (monitoring children, restarting on crash)?
- **Namespace setup**: Init needs to set up the root namespace — mount the
  filesystem servers, device servers, etc. Should it inherit a minimal
  namespace from the kernel, or build everything from scratch?

## Minimal Design

```
init (PID 1):
  1. Mount ramfs at /
  2. Spawn console server → mount at /dev/console
  3. Spawn other services as needed
  4. Spawn getty on /dev/console
  5. Loop: wait() for children, restart critical ones on crash
```

## What Moves Out of Kernel

- `spawnServices()` in main.zig — replaced by init
- `supervisor.zig` crash recovery — optionally moved to init
- Service registration / mount setup — done by init via syscalls

## Verify

1. Kernel boots, spawns only init
2. Init spawns console server, hello process
3. Same behavior as today, but driven from userspace
