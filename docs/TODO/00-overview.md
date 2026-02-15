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
| 17 | `spawn` syscall (create child process from userspace) | Done |
| 18 | `exec` syscall (replace current process image) | Done |
| 19 | `wait`/`exit` lifecycle (parent-child, reaping, orphan kill) | Done |
| 20 | Initrd (FXINITRD flat namespace image, UEFI-loaded) | Done |
| 21 | Init process (PID 1, kernel-backed /boot/, SMF-style wait) | Done |
| 22 | Ramfs (in-memory filesystem server, userspace) | Done |
| 23 | TTY / interactive console (keyboard input) | Done |
| 24 | Shell (fsh — Fornax shell, builtins + spawn) | Done |

## Next: Userspace Separation (Phases 22-25)

The kernel can create processes and run ELFs, but everything is baked in at
compile time via `@embedFile`. These phases decouple userspace from the kernel
and build toward an interactive shell.

**Each phase has explicit decision points** — questions about approach and
tradeoffs to discuss before implementing.

| Phase | Description | Depends On | Key Decision |
|-------|-------------|------------|--------------|
| 17 | `spawn` syscall (create child process from userspace) | 10 | **Done** |
| 18 | `exec` syscall (replace current process image) | 17 | **Done** |
| 19 | `wait`/`exit` lifecycle (parent-child, reaping) | 17 | **Done** |
| 20 | Initrd (ramdisk loaded by UEFI) | 17 | **Done** |
| 21 | Init process (PID 1, userspace service spawning) | 19, 20 | **Done** |
| 22 | Ramfs (in-memory filesystem server) | 21, 9 | **Done** |
| 23 | TTY / interactive console (keyboard input) | 12, 22 | **Done** |
| 24 | Shell (command prompt, spawn+wait loop) | 23, 17, 19 | **Done** |
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

## Future: Language Support (1000-series)

| Phase | Description | Depends On |
|-------|-------------|------------|
| 1000 | C/C++/Go support — freestanding C, minimal libc, musl port, POSIX realms | 17-25 |

## Future: Deployment + Orchestration (3000-series, optional, `-Dviceroy=true`)

Production deployment tooling — all userspace. Turns a Fornax cluster into a
hardened service platform. No Kubernetes, no etcd, no YAML — just text manifests,
9P namespaces, and file operations. Builds on 200-series cluster primitives.

Deployment is an optional build-time feature. `-Dviceroy=true` implies `-Dcluster=true`.
When disabled (default), none of the deployment tooling is compiled — zero overhead.

Build with: `zig build x86_64 -Dviceroy=true`

| Phase | Description | Depends On |
|-------|-------------|------------|
| 3000 | Service manifests + cmd/deploy (declarative text-based deployment) | 202 |
| 3001 | Health checks + auto-recovery (liveness via file reads) | 3000 |
| 3002 | Rolling updates (zero-downtime deployments) | 3000, 3001 |
| 3003 | Service routing (namespace-based discovery + load balancing) | 3000, 3001, 201 |
| 3004 | Secrets + config (encrypted namespace for service credentials) | 3000, 201 |
| 3005 | Image registry (srv/registry — 9P-based container image store) | 201, 14 |
| 3006 | Observability (structured logs + metrics via /deploy/* files) | 3000, 3001 |

## Future: Graphics Stack (2000-series)

From bare GPU hardware to Chrome rendering in a Fornax window.
All drivers and servers in userspace, composited via Plan 9 namespaces,
with POSIX realm bridging for legacy GUI apps.

| Phase | Description | Depends On |
|-------|-------------|------------|
| 2000 | srv/gpu — modesetting + framebuffer (UEFI GOP backend) | 17 |
| 2001 | srv/draw — 2D drawing server (Plan 9 /dev/draw) | 2000 |
| 2002 | srv/input — input devices (/dev/mouse, /dev/kbd) | 17 |
| 2003 | srv/wm — window manager (namespace multiplexing) | 2001, 2002 |
| 2004 | Native GUI apps (cmd/clock, cmd/term) | 2003 |
| 2005 | srv/gpu+ — GPU command submission (stretch, not gating) | 2000 |
| 2006 | Wayland bridge (sommelier in POSIX realm) | 1000, 2003 |
| 2007 | Chrome in a Fornax window | 2006 |

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


                Phase 17 (spawn)
              ┌──────┼──────────┐
              v      v          v
         Ph 1000  Ph 2000    Ph 2002
         (POSIX   (srv/gpu)  (srv/input)
          Realms)    |          |
              |   Ph 2001      |
              |   (srv/draw)   |
              |      |         |
              |      └────┬────┘
              |           v
              |        Ph 2003
              |        (srv/wm)
              |           |
              |        Ph 2004
              |        (native GUI apps)
              |           |
              └─────┬─────┘
                    v
                Ph 2006 (Wayland bridge)
                    |
                Ph 2007 (Chrome in realm)

       Ph 2005 (GPU accel) is independent,
       enhances performance but not required


  Phase 202 (Cluster Scheduler)
       |
       v
  Ph 3000 (Service Manifests + cmd/deploy)
       |
       ├──────────────────────┐
       v                      v
  Ph 3001 (Health Checks)  Ph 3004 (Secrets)
       |                   Ph 3005 (Image Registry)
       ├──────────┐
       v          v
  Ph 3002      Ph 3003
  (Rolling     (Service
   Updates)     Routing)
       |          |
       └────┬─────┘
            v
       Ph 3006 (Observability)
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
| 7 | Userspace spawns a child process | 17 | Done |
| 8 | Init process boots the system from userspace | 21 | Done |
| 8.5 | Ramfs serves files, init creates/reads/writes via IPC | 22 | Done |
| 9 | Interactive shell prompt | 24 | Done |
| 10 | TCP connection to/from Fornax | 100 | Not started |
| 11 | Two Fornax nodes discover each other | 200 | Not started (requires `-Dcluster=true`) |
| 12 | Mount remote node's namespace | 201 | Not started (requires `-Dcluster=true`) |
| 13 | Schedule container across cluster | 202 | Not started (requires `-Dcluster=true`) |
| 14 | Compile and run a C program on Fornax | 1000 | Not started |
| 15 | Framebuffer accessible from userspace srv/gpu | 2000 | Not started |
| 16 | Native app draws in a window | 2004 | Not started |
| 17 | Chrome renders in a Fornax window | 2007 | Not started |
| 18 | `deploy apply` schedules a service across cluster | 3000 | Not started |
| 19 | Service auto-recovers after crash | 3001 | Not started |
| 20 | Zero-downtime rolling update | 3002 | Not started |
| 21 | `deploy top` shows live cluster overview | 3006 | Not started |
