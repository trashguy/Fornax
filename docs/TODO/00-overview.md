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
| 12 | Console file server (first userspace driver) | Scaffolded |
| 13 | Fault supervisor (VMS-style crash recovery) | Scaffolded |
| 14 | Container primitives + OCI import tool | Scaffolded |
| 15 | PCI enumeration + virtio-net NIC driver | Done |
| 16 | IP stack: Ethernet + ARP + IPv4 + UDP + ICMP | Done |

## Planned: Networking

| Phase | Description | Depends On |
|-------|-------------|------------|
| 17 | TCP | 16 |
| 18 | DNS resolver | 16 |

## Planned: Clustering (optional, `-Dcluster=true`)

Clustering is an optional build-time feature. When disabled (default), none of the
clustering code is compiled into the kernel — zero overhead.

Build with: `zig build x86_64 -Dcluster=true`

Kernel code uses `@import("build_options").cluster` to gate cluster-related
initialization and imports at compile time.

| Phase | Description | Depends On |
|-------|-------------|------------|
| 19 | Cluster discovery (UDP gossip, /cluster/* namespace) | 16 |
| 20 | Remote namespace import (9P over TCP) | 17, 19 |
| 21 | Cluster scheduler (container placement across nodes) | 20 |

## Dependency Graph

```
Phases 1-14 (done)
    │
    v
Phase 15: PCI + virtio-net (/dev/ether0)
    │
    v
Phase 16: IP stack (ARP, IPv4, UDP, ICMP)   ← done
    │
    ├──────────────┐
    v              v
Phase 17: TCP    Phase 18: DNS
    │
    ├─────────────────────────────────────┐
    v                                     │
                                          │
  ┌───── only with -Dcluster=true ──────┐ │
  │                                     │ │
  │ Phase 19: Cluster Discovery  <──────┘ │
  │     │                                 │
  │     v                                 │
  │ Phase 20: 9P over TCP  <─────────────┘
  │     │
  │     v
  │ Phase 21: Cluster Scheduler
  │                                     │
  └─────────────────────────────────────┘
```

## Milestones

| # | Goal | Phases | Status |
|---|------|--------|--------|
| 1 | Hello world from Ring 3 | 7-10 | Code complete, needs QEMU test |
| 2 | Hello world via IPC to console file server | 12 | Scaffolded |
| 3 | Crash a file server, kernel restarts it | 13 | Scaffolded |
| 4 | Run a container with namespace isolation | 14 | Scaffolded |
| 5 | Ping reply from Fornax | 15-16 | Code complete, needs QEMU test |
| 6 | Two Fornax instances exchange UDP | 16 | Code complete, needs QEMU test |
| 7 | TCP connection to/from Fornax | 17 | Not started |
| 8 | Two Fornax nodes discover each other | 19 | Not started (requires `-Dcluster=true`) |
| 9 | Mount remote node's namespace | 20 | Not started (requires `-Dcluster=true`) |
| 10 | Schedule container across cluster | 21 | Not started (requires `-Dcluster=true`) |
