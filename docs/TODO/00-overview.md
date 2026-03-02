# Fornax Implementation Plan

## Next Up

| Phase | Description | Depends On |
|-------|-------------|------------|
| 202 | File management (cp/mv/rmdir/touch) | 24 |
| 207 | envfs — environment variable virtual filesystem | 24 |

## Future: Package Manager (1001-series)

| Phase | Description | Depends On |
|-------|-------------|------------|
| 1001e-k | fay package manager (sync, install, build, zig compiler) | 1001a-d |

## Future: Containers + POSIX (1000-series)

| Phase | Description | Depends On |
|-------|-------------|------------|
| 1003 | Dynamic linker support (ET_DYN / PIE, PT_INTERP, auxv) | 1000, 1002 |

## Completed: Network Dekernel + Container Externalization (1010-series)

Migrated kernel networking and container orchestration to userspace.

| Phase | Description | Status |
|-------|-------------|--------|
| ~~1010~~ | ~~Socket shim — rewrite linux_socket.zig to use Plan 9 /net/ file ops via IPC to netd~~ | **Done** |
| ~~1011~~ | ~~Delete kernel network stack — gut src/net.zig, remove FdType.net, NetFdKind~~ | **Done** |
| ~~1012~~ | ~~Container orchestration to userspace~~ | **Done** |

## Future: NIC Drivers (2100-series)

Userspace NIC drivers via shared 2000-series device-driver primitives (PCI enhancement, device mmap, DMA alloc).

| Phase | Description | Depends On |
|-------|-------------|------------|
| 2100 | RTL8125 NIC driver (r8169) — PCI cfg syscall, mmap_device, DMA alloc, ether driver mode | 2000a, 2000c |

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
├── 130 VMS supervisor (done)
├── 150 login/getty (done)
├── 200 /proc (done) ── 201 seek+getpid (done) ── 204 ps/kill/top (done)
├── 203 text processing (done)
├── 205 shell enhancements (done)
├── 206 permissions (done)
├── 210 fe editor (done)
├── 215 virtual consoles (done)
├── 300-313 fxfs filesystem (done)
├── 400-405 xHCI USB (done)
├── 500-501 NVMe + AHCI/SATA (done)
├── A-G SMP (done) ── H-K threads (done)
├── 1000 POSIX realms (done) ── 1001i TCC (done)
├── 1001a-d,l foundation libs (done)
├── 1002 containers (done) ── 1010 socket shim (done) ── 1011 dekernel net (done) ── 1012 container userspace (done)
├── 3A-3D userspace networking (done)
├── TLS + OCI registry pull (done)
├── Kernel trace, time/cron, ctl files, RISC-V port (done)
│
├── Next:
│   ├── 202 file management
│   ├── 207 envfs
│   ├── 1001e-k fay package manager
│   └── 1003 dynamic linker (ET_DYN, PT_INTERP, auxv)
│
├── Future: NIC Drivers
│   └── 2000a + 2000c ── 2100 RTL8125 r8169 driver
│
├── Future: Graphics
│   ├── 2000 srv/gpu ── 2001 srv/draw ──┐
│   ├── 2002 srv/input ─────────────────┤
│   │                                    v
│   │                              2003 srv/wm ── 2004 native apps
│   │                                    |
│   └── 1000 (done) ───────────── 2006 Wayland bridge ── 2007 Chrome
│
└── Future: Clustering + Deployment (-Dcluster / -Dviceroy)
    ├── 3000 gossip discovery
    ├── 3001 9P remote namespaces
    ├── 3002 cluster scheduler
    └── 3003-3009 viceroy (manifests, health, rolling updates, routing,
                           secrets, registry, observability)
```

## Future Milestones

| # | Goal | Phases | Status |
|---|------|--------|--------|
| 20 | `fay install` fetches and installs a package | 1001e-k | Not started |
| 29 | Container iperf3 uses container IP (10.0.1.x) | 1010 | **Done** |
| 30 | Kernel has no TCP/IP stack — all networking via netd | 1011 | **Done** |
| 31 | Container lifecycle managed entirely from userspace fnx | 1012 | **Done** |
| 21 | RTL8125 NIC driver serves /dev/ether0 on real hardware | 2100 | Not started |
| 22 | Framebuffer accessible from userspace srv/gpu | 2000 | Not started |
| 23 | Native app draws in a window | 2004 | Not started |
| 24 | Chrome renders in a Fornax window | 2007 | Not started |
| 25 | Two Fornax nodes discover each other | 3000 | Not started (requires `-Dcluster=true`) |
| 26 | Mount remote node's namespace | 3001 | Not started (requires `-Dcluster=true`) |
| 27 | `deploy apply` schedules a service across cluster | 3003 | Not started (requires `-Dviceroy=true`) |
| 28 | Zero-downtime rolling update | 3005 | Not started (requires `-Dviceroy=true`) |
