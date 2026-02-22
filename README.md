# Fornax

A microkernel operating system written in Zig. Plan 9's "everything is a file" design meets VMS-style fault tolerance — clean interfaces with the durability to match.

## Why Fornax?

**Everything is a file.** GPU drivers, network stacks, block devices — they all run as userspace file servers. Write `"resolution 1920 1080"` to `/dev/gpu/ctl`. Read your ARP table from `/net/arp`. No `ioctl`, no magic numbers, no binary protocols. Every device speaks plain text over the same file interface.

**VMS-grade durability.** Your GPU driver segfaults? The kernel restarts it. Your network stack panics? It comes back. Inspired by OpenVMS — which ran phone networks and stock exchanges for decades without rebooting — Fornax's fault supervisor monitors every userspace server and transparently restarts crashed services from their saved ELF. A buggy driver never takes down the system. The microkernel itself is the only code that *must* be correct; everything else is recoverable.

**Containers without containers.** In Fornax, a container is just `rfork` + `bind` + `mount` — existing kernel primitives. Each process already has its own namespace (file tree), so isolation is the default, not an afterthought bolted on with cgroups and seccomp filters.

**Run POSIX software without compromising the kernel.** The kernel speaks only Plan 9-style syscalls — no `socket()`, no `ioctl()`, no signals. Native Fornax programs are clean and simple. POSIX software runs transparently via a userspace shim: type `gcc main.c` and it just works — the ELF interpreter detects the POSIX binary and sets up a POSIX realm automatically. CLI tools get ephemeral realms (created on exec, gone on exit). Daemons like nginx get full containers with their own rootfs and resource quotas. `socket() + connect()` becomes `open("/net/tcp/clone")`. POSIX complexity lives in userspace where bugs can't crash the system.

**Orchestration without the orchestrator.** Kubernetes exists because Linux can't express "this service's `/db` is a TCP mount to that machine's postgres." So you need kube-proxy to fake routing with iptables, CoreDNS to fake service discovery, etcd to fake distributed state, and an API server to glue it together — ~100 binaries and a million lines of Go papering over a missing OS primitive. Fornax has the primitive: `mount("tcp!10.0.0.3!564", "/svc/db", "")`. Service discovery is `ls /svc/`. Health checks are `read /svc/web/health`. Deployment is writing a text file. The entire orchestration layer — deployment, health checks, rolling updates, routing, secrets, observability — is a handful of small file servers doing what Plan 9 showed was possible in 1992. Build with `-Dviceroy=true` to include it, or leave it off for zero overhead.

**Optional clustering.** Build with `-Dcluster=true` to enable multi-node support. Nodes discover each other via UDP gossip and import remote namespaces over 9P. Mount another machine's `/dev/` into your local tree. Schedule containers across a cluster. Disabled by default — zero overhead when you don't need it. Add `-Dviceroy=true` to layer production deployment tooling on top.

**One language, top to bottom.** Kernel, drivers, userspace, and build system — all Zig. Memory-safe where it matters, bare-metal where it counts.

**Built with AI.** Fornax is developed collaboratively between a human and Claude Code. Architecture decisions, code, documentation, and debugging — all done in conversation. AI-assisted development taken to its logical conclusion: an entire operating system.

## Design

```
Containers (managed)        POSIX realms            Native Fornax
┌──────────┐                ┌──────────┐         ┌──────┐ ┌──────┐
│ nginx    │                │ gcc      │         │ sh   │ │ init │ ...
│ own root │                │ musl     │         │      │ │      │
│ quotas   │                │ libposix │         │      │ │      │
└────┬─────┘                └────┬─────┘         └──┬───┘ └──┬───┘
     └───────────────────────────┴──────────────────┴────────┘
              fornax syscalls / lib/fornax.zig
────────────────────────────────────────────────────────────────
Userspace File Servers (console, net, ramfs...)
────────────────────────────────────────────────────────────────
Microkernel (Plan 9 syscalls only)
├── Memory       PMM + paging + address spaces
├── IPC          synchronous channels (L4-style)
├── Namespaces   per-process mount tables
├── Supervisor   crash recovery for servers
└── Containers   namespace + quotas + rootfs
```

Programs interact with the system through Plan 9-style syscalls: `open`, `read`, `write`, `close`, `mount`, `bind`, `rfork`, and friends. IPC is synchronous message passing over channels. File servers handle `T_OPEN`/`T_READ`/`T_WRITE` messages and reply with `R_OK` or `R_ERROR`.

The kernel has no POSIX. POSIX programs run in two modes:
- **POSIX realms** — for CLI tools (gcc, python, etc.). The ELF interpreter auto-detects POSIX binaries and sets up a realm with musl/libposix. Ephemeral — lives and dies with the process.
- **Containers** — for daemons (nginx, postgres). Managed environments with own rootfs, resource quotas, and lifecycle. Created explicitly.

### SMP

Fornax supports symmetric multiprocessing on x86_64 (up to 128 logical CPUs, including hyperthreads/SMT). Cores are detected dynamically via ACPI MADT at boot. Each core has its own run queue, kernel stack, and syscall save area. There is no big kernel lock — shared resources use fine-grained ticket spinlocks.

```
Core 0 (BSP)         Core 1              Core 2              Core 3
┌──────────┐         ┌──────────┐        ┌──────────┐        ┌──────────┐
│ RunQueue │         │ RunQueue │        │ RunQueue │        │ RunQueue │
│ [fxfs]   │         │ [login]  │        │ [fsh]    │        │ [cat]    │
│ [partfs] │         │          │        │          │        │          │
├──────────┤         ├──────────┤        ├──────────┤        ├──────────┤
│ PerCpu   │         │ PerCpu   │        │ PerCpu   │        │ PerCpu   │
│ GS_BASE  │         │ GS_BASE  │        │ GS_BASE  │        │ GS_BASE  │
└──────────┘         └──────────┘        └──────────┘        └──────────┘
     ↕ IPI (schedule, TLB shootdown)  ↕
```

- **AP startup**: ACPI MADT discovery, INIT-SIPI-SIPI sequence, per-core GDT/IDT/TSS
- **Scheduling**: Per-core run queues with work stealing. Idle cores steal half of a busy core's queue
- **IPC wakeup**: `markReady()` pushes to the target core's run queue and sends a schedule IPI if remote
- **TLB coherence**: `cores_ran_on` bitmap per process; page table teardown sends shootdown IPIs to affected cores

See [docs/smp.md](docs/smp.md) for the full design.

## Current State

Fornax boots on x86_64 UEFI and riscv64 freestanding, runs a shell with users, a CoW filesystem, and a TCP/IP stack. The system includes 50+ userspace programs.

| Layer | What works |
|-------|-----------|
| Boot | UEFI boot (x86_64), OpenSBI boot (riscv64), GOP framebuffer, serial console |
| Memory | PMM with spinlock, kernel heap, 4-level paging, per-process address spaces |
| SMP | Up to 128 CPUs, per-core run queues, work stealing, TLB shootdown, ticket spinlocks |
| Processes | ELF loader, SYSCALL/SYSRET, Ring 3, per-core scheduling, sleep, getpid |
| IPC | Synchronous blocking channels with 9P message tags, per-channel spinlocks |
| Namespaces | Per-process mount tables, longest-prefix resolution |
| Filesystem | fxfs (CoW B-tree), GPT partitions, virtio-blk, pread/pwrite |
| Shell | fsh with pipes, redirects, quoting, variables, if/while, history |
| Networking | virtio-net, ARP, IPv4, ICMP, UDP, TCP, DNS |
| USB | xHCI driver, USB keyboard and mouse |
| Users | Login, /etc/passwd, uid/gid, permissions, chown/chmod |
| Virtual consoles | 4 VTs (Alt+F1-F4), per-VT ANSI terminal |
| Utilities | cat, ls, grep, sed, awk, less, vi (fe), ps, top, and 40+ more |

## Building

Requires [Zig 0.15.x](https://ziglang.org/download/).

```sh
zig build x86_64     # x86_64 UEFI kernel
zig build aarch64    # aarch64 UEFI kernel
zig build            # both

# With clustering support
zig build x86_64 -Dcluster=true

# With deployment/orchestration tooling (implies cluster)
zig build x86_64 -Ddeploy=true
```

## Running

Requires QEMU with OVMF firmware.

```sh
make run             # x86_64, single core
make run-smp         # x86_64, 4 cores
make run-riscv64     # riscv64 on QEMU virt
make run-release     # ReleaseSafe kernel
```

This builds the kernel and userspace, creates a disk image with fxfs, and launches QEMU with framebuffer, serial on stdio, virtio-net, virtio-blk, and USB devices.

## Documentation

| Doc | Contents |
|-----|----------|
| [Architecture](docs/architecture.md) | Kernel subsystems, syscall table, boot sequence |
| [SMP](docs/smp.md) | Multi-core design, scheduling, locking, work stealing |
| [Filesystem](docs/fxfs.md) | fxfs CoW B-tree filesystem design |
| [Networking](docs/networking.md) | Protocol stack, virtio driver, packet flow |
| [Roadmap](docs/TODO/00-overview.md) | Phase tracking, milestones, dependency graph |

## Project Structure

```
src/                         kernel
├── main.zig                 entry + init chain
├── process.zig              process management + scheduler
├── syscall.zig              syscall dispatch + implementations
├── ipc.zig                  synchronous channels
├── pipe.zig                 kernel pipes (ring buffer, refcounted)
├── namespace.zig            per-process mount tables
├── supervisor.zig           fault supervisor
├── percpu.zig               per-CPU state, run queues
├── spinlock.zig             ticket spinlocks
├── elf.zig                  ELF64 loader
├── net.zig + net/           IP stack (Ethernet, ARP, IPv4, TCP, UDP, DNS)
├── virtio_blk.zig           virtio block device driver
├── virtio_net.zig           virtio-net NIC driver
├── xhci.zig                 xHCI USB 3.0 host controller
└── arch/x86_64/
    ├── entry.S              syscall entry, ISR/IPI stubs, resume (asm)
    ├── apic.zig             LAPIC, ACPI MADT, AP trampoline, IPI
    ├── paging.zig           4-level paging
    ├── gdt.zig              GDT + per-core TSS
    ├── interrupts.zig       exception + IRQ + IPI handling
    ├── syscall_entry.zig    SYSCALL/SYSRET, per-CPU save area
    └── pci.zig              PCI bus enumeration
lib/
└── fornax.zig               userspace syscall library ("libc")
cmd/                         userspace commands (fsh, ls, cat, grep, ...)
srv/                         userspace servers (fxfs, partfs)
docs/                        design documentation
```

## License

[MIT](LICENSE)
