# Fornax Architecture

## Overview

```
User Programs / Containers (native or OCI-imported)
────────────────────────────────────────────────────
Userspace File Servers (console, net, block, gpu...)
────────────────────────────────────────────────────
Microkernel
├── Memory: PMM + heap + paging + address spaces
├── Scheduling: process model with per-process state
├── IPC: synchronous message passing (channels)
├── Namespaces: per-process mount tables
├── Syscalls: Plan 9-inspired (~17 calls)
├── Fault supervisor: monitor + restart crashed servers
└── Containers: namespace + quotas + rootfs isolation
```

Fornax is a microkernel. All drivers (console, network, block devices, GPU) run as userspace file servers. The kernel provides only memory management, scheduling, IPC, and namespace resolution. Programs interact with hardware by reading and writing files — there is no `ioctl`.

## Design Principles

### Plan 9-Pure Kernel, POSIX via Userspace

The kernel exposes only Plan 9-style syscalls. There is no POSIX compatibility in the kernel — no `socket()`, no `ioctl()`, no signals, no `fork()`. The native userspace (`init`, shell, file servers, utilities) speaks the kernel's native interface directly via `lib/fornax.zig`.

POSIX compatibility is provided as a **userspace shim library** (`libposix`) that translates POSIX calls to Fornax equivalents:

| POSIX | Fornax translation |
|-------|-------------------|
| `socket()` + `connect()` | `open("/net/tcp/clone")` + `write(ctl, "connect ...")` |
| `fork()` | `rfork(RFPROC\|RFMEM)` or `spawn()` |
| `kill(pid, sig)` | `write("/proc/{pid}/note", "kill")` |
| `ioctl(fd, TIOCGWINSZ)` | `read("/dev/console/ctl")` |
| `signal(SIGTERM, handler)` | note handler via `/proc/self/note` |

### POSIX Namespaces vs Containers

POSIX programs run in two modes, using different levels of isolation:

**POSIX realms** are for interactive/CLI programs (gcc, python, etc.). When
the kernel loads an ELF with `PT_INTERP = /lib/posix-realm`, the posix-realm
loader (a native Fornax program) calls `rfork(RFNAMEG)` to create a new
namespace, mounts musl/libposix and POSIX /dev, then loads the real binary.
The realm is ephemeral — lives and dies with the process. The shell doesn't
know or care; it just calls exec. This is standard Plan 9 namespace
customization — not a special feature.

**Containers** are for managed, long-running services (nginx, postgres). They
have their own rootfs image, resource quotas, lifecycle management
(create/start/stop/destroy), and potentially their own init process. Created
explicitly by a container manager.

```
┌───────────────────────────────────────────────────────────┐
│ Containers (managed)       POSIX realms (ephemeral)       │
│ ┌───────────┐              ┌───────────┐                  │
│ │ nginx     │              │ gcc       │                  │
│ │ own rootfs│              │ musl      │                  │
│ │ quotas    │              │ libposix  │                  │
│ └─────┬─────┘              └─────┬─────┘                  │
│       └──────────────────────────┘                        │
│            fornax syscalls                                │
├───────────────────────────────────────────────────────────┤
│ Native Fornax userspace                                   │
│ init, sh, ramfs, console, net srv...                      │
│ lib/fornax.zig (native syscall API)                       │
├───────────────────────────────────────────────────────────┤
│ Fornax microkernel                                        │
│ Plan 9 syscalls only — no POSIX, no ioctl                 │
└───────────────────────────────────────────────────────────┘
```

## Kernel Subsystems

### Memory

- **Physical memory manager** (`src/pmm.zig`): Bitmap allocator providing page-granularity (4 KB) alloc/free.
- **Kernel heap** (`src/heap.zig`): Bump allocator backed by PMM. Auto-grows by requesting contiguous pages. No free for now.
- **4-level paging** (`src/arch/x86_64/paging.zig`): PML4 -> PDPT -> PD -> PT.
  - Identity maps first 4 GB with 2 MB huge pages.
  - Higher-half kernel mapping at `0xFFFF_8000_0000_0000`.
  - Per-process address spaces: new PML4 with kernel half (entries 256-511) pre-copied.
  - 4 KB page mapping/unmapping for userspace segments.

### Processes

- **Process model** (`src/process.zig`): Per-process address space, kernel stack, FD table (32 entries), namespace, resource quotas.
- **ELF64 loader** (`src/elf.zig`): Parses PT_LOAD segments, allocates pages, copies data, maps with correct flags. Returns entry point and program break. Userspace ELFs are currently embedded into the kernel binary at compile time via `@embedFile` in `build.zig` and loaded by the supervisor or `main.zig` directly.
- **SYSCALL/SYSRET** (`src/arch/x86_64/syscall_entry.zig`): MSR-configured fast syscall entry. Assembly stub saves RIP/RSP/RFLAGS to per-CPU globals, switches to kernel stack, calls Zig dispatch. Returns via `sysretq` (restoring RCX=RIP, R11=RFLAGS). Blocking syscalls (ipc_recv) save context to Process struct and call `scheduleNext()` instead of returning.
- **Exception handling** (`src/arch/x86_64/interrupts.zig`): Distinguishes Ring 0 (fatal) vs Ring 3 (kill process) faults by checking `CS & 3`.

### IPC

Synchronous message passing over channels (L4/Plan 9 inspired).

- Channels are bidirectional message pipes between two processes.
- 9P-style message tags: `T_OPEN`, `T_READ`, `T_WRITE`, `T_CLOSE`, `T_STAT`, `T_CTL`, `T_CREATE`, `T_REMOVE`.
- Response tags: `R_OK` (success + data), `R_ERROR` (error + message).
- Messages carry up to 4 KB of inline data.
- 256 max channels system-wide.
- `ipc_recv` blocks: the calling process is marked blocked, its context is saved, and the scheduler runs the next process. When a message arrives, the receiver is unblocked.
- Message delivery is deferred to `switchTo()` — the kernel copies the message into the target's address space only when switching to that process, ensuring the correct page tables are active.

### Namespaces

Each process has its own mount table (`src/namespace.zig`). When a process calls `open("/dev/console")`:

1. Kernel finds the longest matching mount entry in the process's namespace.
2. The mount entry maps a path prefix to an IPC channel connected to a file server.
3. The kernel sends a `T_OPEN` message over that channel.
4. The file server responds with `R_OK`.

Union mount flags: `REPLACE`, `BEFORE` (searched first), `AFTER` (searched after existing).

`rfork(RFNAMEG)` gives a child a copy of the parent's namespace that can be modified independently.

### Console File Server

The first userspace driver (will be `srv/console/main.zig`). Runs as a supervised service, mounted at `/dev/console`. Handles IPC messages in a loop:

- `T_WRITE` — relays data to stdout (kernel framebuffer path), replies with bytes written
- `T_OPEN` — acknowledges open requests
- `T_READ` — returns 0 bytes (no keyboard input yet)
- Unknown tags — replies `R_ERROR`

Spawned by the supervisor with fd 3 as the server-side channel endpoint.

### Fault Supervisor

VMS-inspired crash recovery (`src/supervisor.zig`). File servers are registered for supervision with their ELF binary and mount path. On crash:

1. Kernel catches exception from user process.
2. Supervisor checks if the PID belongs to a registered service.
3. If under max restart count (default 5), spawns a new instance from the saved ELF.
4. Re-mounts at the same path in the root namespace.
5. Existing clients receive `R_ERROR` on pending operations (they can reconnect).

### Containers

A container is not a special kernel concept — it combines existing primitives (`src/container.zig`):

```
rfork(RFNAMEG)                    isolated namespace
bind("/rootfs", "/", REPLACE)     new root filesystem
mount(console_chan, "/dev/con")   give it a console
mount(net_chan, "/net")           give it networking
exec("/init")                    run container init
```

Resource quotas enforce limits on memory pages, channels, children, and CPU priority.

OCI/Docker images can be imported and converted to native format by the userspace `oci_import` tool.

## Syscall Interface

Plan 9-inspired. NOT Linux-compatible. No `ioctl` — device control via text writes to control files (e.g., write `"resolution 1920 1080"` to `/dev/gpu/ctl`).

| Nr | Name | Description | Status |
|----|------|-------------|--------|
| 0 | `open` | Open a file by path (namespace → IPC to file server) | Implemented |
| 1 | `create` | Create a new file | Planned |
| 2 | `read` | Read from file descriptor (IPC to file server) | Implemented |
| 3 | `write` | Write to file descriptor (fd 1/2 → console, or IPC) | Implemented |
| 4 | `close` | Close file descriptor | Implemented |
| 5 | `stat` | Get file metadata | Planned |
| 6 | `seek` | Seek within file | Planned |
| 7 | `remove` | Delete a file | Planned |
| 8 | `mount` | Mount a file server at a path | Planned |
| 9 | `bind` | Bind a path to another path | Planned |
| 10 | `unmount` | Unmount a path | Planned |
| 11 | `rfork` | Fork with flags (RFMEM, RFNAMEG, etc.) | Planned |
| 12 | `exec` | Execute a program | Planned |
| 13 | `wait` | Wait for child process | Planned |
| 14 | `exit` | Terminate process | Implemented |
| 15 | `pipe` | Create a channel pair | Planned |
| 16 | `brk` | Adjust program break | Planned |
| 17 | `ipc_recv` | Receive IPC message on a channel (blocks) | Implemented |
| 18 | `ipc_reply` | Reply to an IPC message on a channel | Implemented |

## Hardware Support

### x86_64

- UEFI boot with GOP framebuffer
- GDT with 7 entries: null, kernel code/data, user data/code, TSS (64-bit)
- IDT with 32 CPU exception handlers
- COM1 serial (0x3F8, 115200 8N1)
- PCI bus enumeration (bus 0, config space via 0xCF8/0xCFC)
- virtio-net NIC (legacy I/O port interface)

### aarch64

- UEFI boot with GOP framebuffer
- Exception vector setup
- Builds but hardware drivers are x86_64-only for now

## Boot Sequence

```
UEFI firmware
  │
  v
main.zig: EfiMain via Zig runtime
  ├── UEFI text output ("Fornax booting...")
  ├── GOP framebuffer + exit boot services
  ├── Serial init (COM1)
  ├── Framebuffer console init
  ├── PMM init (from UEFI memory map)
  ├── Kernel heap init
  ├── Architecture init (GDT, IDT, paging, CR3 switch)
  ├── IPC init
  ├── Process manager init
  ├── SYSCALL MSR setup (x86_64 only)
  ├── Fault supervisor init
  ├── Container init
  ├── PCI enumeration + virtio-net init (x86_64 only)
  ├── Network stack init (set IP/gateway/mask)
  ├── Spawn userspace services:
  │   ├── Console server (supervised, mounted at /dev/console)
  │   └── Hello process (standalone)
  └── scheduleNext() — picks first ready process, SYSRET to Ring 3 (never returns)
```

## Build Options

Compile-time feature flags are passed via `build.zig` and accessed in kernel code as `@import("build_options")`.

| Flag | Default | Description |
|------|---------|-------------|
| `-Dcluster=true` | `false` | Enable clustering (gossip discovery, 9P remote namespaces, scheduler). When disabled, cluster code is not compiled — zero binary overhead. |
