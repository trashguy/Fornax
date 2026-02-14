# Fornax

A microkernel operating system written in Zig, inspired by Plan 9, with first-class container support and optional clustering.

## Why Fornax?

**Everything is a file.** GPU drivers, network stacks, block devices — they all run as userspace file servers. Write `"resolution 1920 1080"` to `/dev/gpu/ctl`. Read your ARP table from `/net/arp`. No `ioctl`, no magic numbers, no binary protocols. Every device speaks plain text over the same file interface.

**Crash-proof drivers.** Your GPU driver segfaults? The kernel restarts it. Your network stack panics? It comes back. VMS-style fault supervision means a buggy driver never takes down the system — it just gets a fresh start.

**Containers without containers.** In Fornax, a container is just `rfork` + `bind` + `mount` — existing kernel primitives. Each process already has its own namespace (file tree), so isolation is the default, not an afterthought bolted on with cgroups and seccomp filters.

**Optional clustering.** Build with `-Dcluster=true` to enable multi-node support. Nodes discover each other via UDP gossip and import remote namespaces over 9P. Mount another machine's `/dev/` into your local tree. Schedule containers across a cluster. Disabled by default — zero overhead when you don't need it.

**One language, top to bottom.** Kernel, drivers, userspace, and build system — all Zig. Memory-safe where it matters, bare-metal where it counts.

**Built with AI.** Fornax is developed collaboratively between a human and Claude Code. Architecture decisions, code, documentation, and debugging — all done in conversation. AI-assisted development taken to its logical conclusion: an entire operating system.

## Design

```
User Programs / Containers
────────────────────────────────────────────
Userspace File Servers (console, net, gpu...)
────────────────────────────────────────────
Microkernel (~17 syscalls)
├── Memory       PMM + paging + address spaces
├── IPC          synchronous channels (L4-style)
├── Namespaces   per-process mount tables
├── Supervisor   crash recovery for servers
└── Containers   namespace + quotas + rootfs
```

Programs interact with the system through ~17 Plan 9-style syscalls: `open`, `read`, `write`, `close`, `mount`, `bind`, `rfork`, and friends. IPC is synchronous message passing over channels. File servers handle `T_OPEN`/`T_READ`/`T_WRITE` messages and reply with `R_OK` or `R_ERROR`.

## Current State

Fornax boots on x86_64 UEFI, sets up 4-level paging with a higher-half kernel, loads an ELF binary into Ring 3 via IRETQ, and responds to ICMP pings over a virtio-net NIC.

| Layer | What works |
|-------|-----------|
| Boot | UEFI boot, GOP framebuffer, serial console |
| Memory | PMM, kernel heap, 4-level paging, per-process address spaces |
| Processes | ELF loader, SYSCALL/SYSRET, Ring 3 execution |
| IPC | Synchronous channels with 9P message tags |
| Namespaces | Per-process mount tables, longest-prefix resolution |
| Supervision | Fault supervisor with auto-restart from saved ELF |
| Containers | Namespace isolation, resource quotas |
| Networking | PCI enumeration, virtio-net, Ethernet, ARP, IPv4, ICMP, UDP |

## Building

Requires [Zig 0.15.x](https://ziglang.org/download/).

```sh
zig build x86_64     # x86_64 UEFI kernel
zig build aarch64    # aarch64 UEFI kernel
zig build            # both

# With clustering support
zig build x86_64 -Dcluster=true
```

## Running

Requires QEMU with OVMF firmware.

```sh
./scripts/run-x86_64.sh
```

This builds the kernel, finds OVMF, and launches QEMU with a framebuffer, serial on stdio, and a virtio-net NIC.

## Documentation

| Doc | Contents |
|-----|----------|
| [Architecture](docs/architecture.md) | Kernel subsystems, syscall table, boot sequence |
| [Networking](docs/networking.md) | Protocol stack, virtio driver, packet flow |
| [Roadmap](docs/TODO/00-overview.md) | Phase tracking, milestones, dependency graph |

## Project Structure

```
src/
├── main.zig             kernel entry + init chain
├── boot.zig             UEFI boot services
├── console.zig          framebuffer + serial console
├── pmm.zig              physical memory manager
├── heap.zig             kernel bump allocator
├── arch/x86_64/
│   ├── paging.zig       4-level paging
│   ├── gdt.zig          GDT + TSS
│   ├── interrupts.zig   exception handling
│   ├── syscall_entry.zig SYSCALL/SYSRET
│   └── pci.zig          PCI bus enumeration
├── ipc.zig              synchronous channels
├── process.zig          process management
├── namespace.zig        per-process mount tables
├── supervisor.zig       fault supervisor
├── container.zig        container primitives
├── virtio.zig           virtio device/queue
├── virtio_net.zig       virtio-net NIC driver
├── net.zig              network stack integration
└── net/                 protocol modules
    ├── ethernet.zig
    ├── arp.zig
    ├── ipv4.zig
    ├── icmp.zig
    └── udp.zig
user/
├── fornax.zig           syscall library
├── hello.zig            hello world (Ring 3)
├── console_server.zig   console file server
└── oci_import.zig       OCI image import
```

## License

TBD
