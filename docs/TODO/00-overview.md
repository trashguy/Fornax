# Fornax Implementation Plan

## Completed Phases

| Phase | Description | Status |
|-------|-------------|--------|
| 1-6 | UEFI boot, GOP framebuffer, console, PMM, GDT, IDT | Done |
| 7 | Kernel heap (bump allocator) + serial console (COM1) | Done |
| 8 | Virtual memory / 4-level paging + higher-half kernel | Done |
| 9 | IPC foundation (synchronous channels, 9P message tags) | Done |
| 10 | Process model + user mode + SYSCALL/SYSRET + ELF loader | Done |
| 11 | Per-process namespaces (mount tables, longest-prefix match) | Done |
| 12 | Console file server (first userspace driver) | Done |
| 13 | Fault supervisor (VMS-style crash recovery) | Done |
| 14 | Container primitives + OCI import tool | Done |
| 15 | PCI enumeration + virtio-net NIC driver | Done |
| 16 | IP stack: Ethernet + ARP + IPv4 + UDP + ICMP | Done |

## Next: Userspace Separation (Phases 17-25)

The kernel can create processes and run ELFs, but everything is baked in at
compile time via `@embedFile`. These phases decouple userspace from the kernel
and build toward an interactive shell.

**Each phase has explicit decision points** — questions about approach and
tradeoffs to discuss before implementing.

| Phase | Description | Depends On | Key Decision |
|-------|-------------|------------|--------------|
| 17 | `spawn` syscall (create child process from userspace) | 10 | fork vs spawn? Who provides ELF bytes? |
| 18 | `exec` syscall (replace current process image) | 17 | Do we need this now, or defer? |
| 19 | `wait`/`exit` lifecycle (parent-child, reaping) | 17 | Blocking vs async? Orphan policy? |
| 20 | Initrd (ramdisk loaded by UEFI) | 17 | Format? Who parses it? |
| 21 | Init process (PID 1, userspace service spawning) | 19, 20 | How much policy? Supervisor role? |
| 22 | Ramfs (in-memory filesystem server) | 21, 9 | Backed by initrd? Full 9P? |
| 23 | TTY / interactive console (keyboard input) | 12, 22 | Keyboard driver? Line vs raw mode? |
| 24 | Shell (command prompt, spawn+wait loop) | 23, 17, 19 | How minimal? Builtins? |
| 25 | Login / getty (authentication layer) | 24 | Defer? Single-user OK for now? |

## Later: Networking (100-series)

| Phase | Description | Depends On |
|-------|-------------|------------|
| 100 | TCP | 16 |
| 101 | DNS resolver | 16 |

## Later: Clustering (200-series, optional, `-Dcluster=true`)

Clustering is an optional build-time feature. When disabled (default), none of the
clustering code is compiled into the kernel — zero overhead.

Build with: `zig build x86_64 -Dcluster=true`

| Phase | Description | Depends On |
|-------|-------------|------------|
| 200 | Cluster discovery (UDP gossip, /cluster/* namespace) | 16 |
| 201 | Remote namespace import (9P over TCP) | 100, 200 |
| 202 | Cluster scheduler (container placement across nodes) | 201 |

## Dependency Graph

```
Phases 1-16 (done)
    |
    v
Phase 17: spawn syscall ──────────────────────────────┐
    |                                                  |
    ├──────────────┐                                   |
    v              v                                   v
Phase 18: exec   Phase 19: wait/exit         Phase 20: initrd
    |              |                                   |
    |              └──────────┬────────────────────────┘
    |                         v
    |                  Phase 21: init (PID 1)
    |                         |
    |                         v
    |                  Phase 22: ramfs
    |                         |
    |                         v
    |                  Phase 23: TTY / console
    |                         |
    v                         v
    └───────────────> Phase 24: shell
                              |
                              v
                      Phase 25: login/getty (optional)


Phase 16 (done) ─────┐
                      ├──────────────┐
                      v              v
              Phase 100: TCP  Phase 101: DNS
                      |
                      ├────────────────────────────────┐
                      v                                |
                                                       |
  ┌───── only with -Dcluster=true ──────┐              |
  |                                     |              |
  | Phase 200: Cluster Discovery <──────┘              |
  |     |                                              |
  |     v                                              |
  | Phase 201: 9P over TCP <──────────────────────────┘
  |     |
  |     v
  | Phase 202: Cluster Scheduler
  |                                     |
  └─────────────────────────────────────┘
```

## Milestones

| # | Goal | Phases | Status |
|---|------|--------|--------|
| 1 | Hello world from Ring 3 | 7-10 | Code complete, needs QEMU test |
| 2 | Hello world via IPC to console file server | 12 | Done |
| 3 | Crash a file server, kernel restarts it | 13 | Done |
| 4 | Run a container with namespace isolation | 14 | Done |
| 5 | Ping reply from Fornax | 15-16 | Code complete, needs QEMU test |
| 6 | Two Fornax instances exchange UDP | 16 | Code complete, needs QEMU test |
| 7 | Userspace spawns a child process | 17 | Not started |
| 8 | Init process boots the system from userspace | 21 | Not started |
| 9 | Interactive shell prompt | 24 | Not started |
| 10 | TCP connection to/from Fornax | 100 | Not started |
| 11 | Two Fornax nodes discover each other | 200 | Not started (requires `-Dcluster=true`) |
| 12 | Mount remote node's namespace | 201 | Not started (requires `-Dcluster=true`) |
| 13 | Schedule container across cluster | 202 | Not started (requires `-Dcluster=true`) |
