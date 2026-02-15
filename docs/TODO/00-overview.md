# Fornax Implementation Plan

## Next Up

| Phase | Description | Depends On |
|-------|-------------|------------|
| 150 | Login / getty (Plan 9-style auth) | 24, 100 |
| 200 | fe — minimal vi-like text editor | 24 |

## Future: Language Support (1000-series)

| Phase | Description | Depends On |
|-------|-------------|------------|
| 1000 | C/C++/Go support — freestanding C, minimal libc, musl port, POSIX realms | 17-24 |

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

## Future: Clustering + Deployment (3000-series, optional)

Clustering and deployment are optional build-time features. Clustering provides
node discovery, remote namespace import, and container scheduling. Deployment
layers on top with service manifests, health checks, rolling updates, and
observability. No Kubernetes, no etcd, no YAML — just text manifests, 9P
namespaces, and file operations.

- `-Dcluster=true` — enables clustering (phases 3000-3002)
- `-Dviceroy=true` — enables deployment tooling (implies `-Dcluster=true`, phases 3003-3009)

When disabled (default), none of this code is compiled — zero overhead.

Build with: `zig build x86_64 -Dviceroy=true`

| Phase | Description | Depends On |
|-------|-------------|------------|
| 3000 | Cluster discovery (UDP gossip, /cluster/* namespace) | 16 |
| 3001 | Remote namespace import (9P over TCP) | 100, 3000 |
| 3002 | Cluster scheduler (container placement across nodes) | 3001 |
| 3003 | Service manifests + cmd/deploy (declarative text-based deployment) | 3002 |
| 3004 | Health checks + auto-recovery (liveness via file reads) | 3003 |
| 3005 | Rolling updates (zero-downtime deployments) | 3003, 3004 |
| 3006 | Service routing (namespace-based discovery + load balancing) | 3003, 3004, 3001 |
| 3007 | Secrets + config (encrypted namespace for service credentials) | 3003, 3001 |
| 3008 | Image registry (srv/registry — 9P-based container image store) | 3001, 14 |
| 3009 | Observability (structured logs + metrics via /deploy/* files) | 3003, 3004 |

## Dependency Graph

```
Phases 1-24, 100-101 (done)
         |
         ├─────────────────────────────────────────┐
         v                                         v
  Phase 150: login/getty                   Phase 200: fe editor


         Phases 1-24 (done)
              |
              ├──────────────┐
              v              v
         Ph 1000          Ph 2000    Ph 2002
         (POSIX           (srv/gpu)  (srv/input)
          Realms)            |          |
              |           Ph 2001      |
              |           (srv/draw)   |
              |              |         |
              |              └────┬────┘
              |                   v
              |                Ph 2003
              |                (srv/wm)
              |                   |
              |                Ph 2004
              |                (native GUI apps)
              |                   |
              └─────────┬─────────┘
                        v
                    Ph 2006 (Wayland bridge)
                        |
                    Ph 2007 (Chrome in realm)

       Ph 2005 (GPU accel) is independent,
       enhances performance but not required


  ┌───── only with -Dcluster=true ─────────────┐
  |                                             |
  | Phase 3000: Cluster Discovery               |
  |     |                                       |
  |     v                                       |
  | Phase 3001: 9P over TCP                     |
  |     |                                       |
  |     v                                       |
  | Phase 3002: Cluster Scheduler               |
  |     |                                       |
  |     v  (-Dviceroy=true)                     |
  | Ph 3003 (Service Manifests + cmd/deploy)    |
  |     |                                       |
  |     ├──────────────────────┐                |
  |     v                      v                |
  | Ph 3004 (Health Checks)  Ph 3007 (Secrets)  |
  |     |                   Ph 3008 (Registry)  |
  |     ├──────────┐                            |
  |     v          v                            |
  | Ph 3005      Ph 3006                        |
  | (Rolling     (Service                       |
  |  Updates)     Routing)                      |
  |     |          |                            |
  |     └────┬─────┘                            |
  |          v                                  |
  |     Ph 3009 (Observability)                 |
  |                                             |
  └─────────────────────────────────────────────┘
```

## Future Milestones

| # | Goal | Phases | Status |
|---|------|--------|--------|
| 11 | Two Fornax nodes discover each other | 3000 | Not started (requires `-Dcluster=true`) |
| 12 | Mount remote node's namespace | 3001 | Not started (requires `-Dcluster=true`) |
| 13 | Schedule container across cluster | 3002 | Not started (requires `-Dcluster=true`) |
| 14 | Compile and run a C program on Fornax | 1000 | Not started |
| 15 | Framebuffer accessible from userspace srv/gpu | 2000 | Not started |
| 16 | Native app draws in a window | 2004 | Not started |
| 17 | Chrome renders in a Fornax window | 2007 | Not started |
| 18 | `deploy apply` schedules a service across cluster | 3003 | Not started |
| 19 | Service auto-recovers after crash | 3004 | Not started |
| 20 | Zero-downtime rolling update | 3005 | Not started |
| 21 | `deploy top` shows live cluster overview | 3009 | Not started |
