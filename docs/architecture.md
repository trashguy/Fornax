# Fornax Architecture

## Overview

```
User Programs / Containers (native or OCI-imported)
────────────────────────────────────────────────────
Userspace File Servers (netd, fxfs, partfs, crond, bridge...)
────────────────────────────────────────────────────
Microkernel
├── Memory: PMM + heap + paging + address spaces
├── Scheduling: SMP with per-core run queues + work stealing
├── IPC: synchronous message passing (channels)
├── Namespaces: per-process mount tables
├── Syscalls: Plan 9-inspired (~41 calls)
├── Fault supervisor: VMS-style monitor + restart + backoff
├── Containers: namespace + quotas + rootfs + Linux compat
├── Threads: clone + futex + thread groups
└── Drivers: virtio-blk, NVMe, AHCI, xHCI USB, virtio-net
```

Fornax is a microkernel. All drivers (console, network, block devices, GPU) run as userspace file servers. The kernel provides only memory management, scheduling, IPC, and namespace resolution. Programs interact with hardware by reading and writing files — there is no `ioctl`.

## Design Principles

### Plan 9-Pure Kernel, POSIX via Userspace

The kernel exposes only Plan 9-style syscalls. There is no POSIX compatibility in the kernel — no `socket()`, no `ioctl()`, no signals, no `fork()`. The native userspace (`init`, shell, file servers, utilities) speaks the kernel's native interface directly via `lib/fornax.zig`.

POSIX compatibility is provided as a **userspace shim library** (`lib/posix/shim.c`) that translates Linux syscalls to Fornax equivalents via musl libc:

| POSIX | Fornax translation |
|-------|-------------------|
| `socket()` + `connect()` | `open("/net/tcp/clone")` + `write(ctl, "connect ...")` |
| `fork()` | `rfork(RFPROC\|RFMEM)` or `spawn()` |
| `kill(pid, sig)` | `write("/proc/{pid}/ctl", "kill")` |
| `ioctl(fd, TIOCGWINSZ)` | `read("/dev/consctl")` |
| `mmap()` | SYS 32 mmap (bump allocator at 0x4000_0000_0000) |

### POSIX Namespaces vs Containers

POSIX programs run in two modes, using different levels of isolation:

**POSIX realms** are for interactive/CLI programs (tcc, etc.). The crt0 calls `rfork(RFNAMEG)` to create a new namespace, mounts musl/libposix and POSIX /dev, then loads the real binary. The realm is ephemeral — lives and dies with the process.

**Containers** are for managed, long-running services (nginx, postgres). They have their own rootfs image, resource quotas, lifecycle management (create/start/stop/destroy), and potentially their own init process. Created explicitly via `fnx` CLI or `/cntr/` virtual filesystem.

```
┌───────────────────────────────────────────────────────────┐
│ Containers (managed)       POSIX realms (ephemeral)       │
│ ┌───────────┐              ┌───────────┐                  │
│ │ nginx     │              │ tcc       │                  │
│ │ own rootfs│              │ musl      │                  │
│ │ quotas    │              │ shim.c    │                  │
│ └─────┬─────┘              └─────┬─────┘                  │
│       └──────────────────────────┘                        │
│            fornax syscalls                                │
├───────────────────────────────────────────────────────────┤
│ Native Fornax userspace                                   │
│ init, fsh, fxfs, partfs, netd, crond...                   │
│ lib/fornax.zig (native syscall API)                       │
├───────────────────────────────────────────────────────────┤
│ Fornax microkernel                                        │
│ Plan 9 syscalls only — no POSIX, no ioctl                 │
└───────────────────────────────────────────────────────────┘
```

## Kernel Subsystems

### Memory

- **Physical memory manager** (`src/pmm.zig`): Bitmap allocator providing page-granularity (4 KB) alloc/free. `search_hint` for O(1) amortized allocation.
- **Kernel heap** (`src/heap.zig`): Bump allocator backed by PMM. Auto-grows by requesting contiguous pages. No free.
- **4-level paging** (`src/arch/x86_64/paging.zig` / `src/arch/riscv64/paging.zig`): PML4 -> PDPT -> PD -> PT (x86_64) or Sv48 (riscv64).
  - Identity maps first 4 GB with 2 MB huge pages.
  - Higher-half kernel mapping at `0xFFFF_8000_0000_0000`.
  - Per-process address spaces: new PML4 with kernel half (entries 256-511) pre-copied.
  - 4 KB page mapping/unmapping for userspace segments.

### Processes & Scheduling

- **Process model** (`src/process.zig`): Per-process address space, kernel stack, FD table (32 entries), namespace, uid/gid, thread group, container id, core affinity. MAX_PROCESSES=128.
- **SMP scheduling** (`src/percpu.zig`): Per-core run queues with CAS-based state transitions. Work stealing (`stealHalf`). Least-loaded core assignment for new processes. TLB shootdown via IPI.
- **Kernel threads** (`src/thread_group.zig`): SYS 37 clone, SYS 38 futex. Shared page tables, fd table, namespace within a thread group. 128 futex waiters.
- **ELF64 loader** (`src/elf.zig`): Parses PT_LOAD segments, allocates pages, maps with correct flags. Returns entry point and program break.
- **SYSCALL/SYSRET** (`src/arch/x86_64/syscall_entry.zig`): Per-CPU entry via `swapgs` + `%gs:offset`. Assembly stub saves context to per-CPU `AsmState`, switches to kernel stack, calls Zig dispatch. Returns via `sysretq`.

### IPC

Synchronous message passing over channels (L4/Plan 9 inspired).

- Channels are bidirectional message pipes between two processes.
- 9P-style message tags: `T_OPEN`, `T_READ`, `T_WRITE`, `T_CLOSE`, `T_STAT`, `T_CTL`, `T_CREATE`, `T_REMOVE`, `T_RENAME`, `T_TRUNCATE`, `T_WSTAT`.
- Response tags: `R_OK` (success + data), `R_ERROR` (error + message).
- Messages carry up to 4 KB of inline data.
- 256 max channels system-wide.
- 16-entry pending client ring buffer per channel end. Multi-threaded server support via `server_waiters[8]`.
- Message delivery is deferred to `switchTo()` — the kernel copies the message into the target's address space only when switching to that process, ensuring the correct page tables are active.

### Namespaces

Each process has its own mount table (`src/namespace.zig`). When a process calls `open("/dev/console")`:

1. Kernel finds the longest matching mount entry in the process's namespace.
2. The mount entry maps a path prefix to an IPC channel connected to a file server.
3. The kernel sends a `T_OPEN` message over that channel.
4. The file server responds with `R_OK`.

Union mount flags: `REPLACE`, `BEFORE` (searched first), `AFTER` (searched after existing).

`rfork(RFNAMEG)` gives a child a copy of the parent's namespace that can be modified independently.

### Fault Supervisor

VMS-inspired crash recovery (`src/supervisor.zig`). Services are registered for supervision with their ELF binary, mount path, and dependencies. On crash:

1. Kernel catches exception / exit from supervised process.
2. Exponential backoff (initial ~110ms, doubles each crash, caps ~30s).
3. Dependency check — waits for dependencies to be alive before respawning.
4. Re-mounts at the same path in the root namespace.
5. Cascade restart — optionally restarts dependents (depth-limited to 3).
6. Stability window (~60s) — resets restart count if service stays up.
7. Health probes — IPC activity tracking detects hung services (~5s timeout).

Runtime control via `/proc/supervisor` (read status table) and `/proc/supervisor/ctl` (write restart/stop/start/reset commands).

### Containers

Container system (`src/container.zig`, `-Dcontainers=true`):

```
/cntr/clone                       allocate container slot
write(/cntr/N/ctl, "rootfs ...")  set isolated rootfs
write(/cntr/N/ctl, "compat ...")  set compat mode (fornax/linux)
SYS 40 cntr_start(N, elf, argv)  load ELF + start init process
```

Resource quotas enforce container-wide limits on memory pages and process count. Per-container networking via bridge server. Linux syscall compatibility (`src/linux_compat.zig`) enables running Alpine/musl binaries.

The `fnx` CLI provides a podman-familiar interface (`fnx run`, `fnx ps`, `fnx build`, `fnx pull`). OCI registry pull with Docker Hub support (bearer auth, manifest list, streaming extraction). See `docs/containers.md`.

### Virtual Filesystems

Kernel-intercepted virtual paths (no userspace server needed):

| Path | Description |
|------|-------------|
| `/proc` | Process listing, per-PID status/ctl, meminfo, supervisor |
| `/dev/null`, `/dev/zero`, `/dev/random` | Standard virtual devices |
| `/dev/pci` | PCI device listing |
| `/dev/cpu` | CPU info (CPUID / SBI) |
| `/dev/usb`, `/dev/mouse` | USB HID devices |
| `/dev/ether0` | Raw Ethernet access (ring buffer, per-client) |
| `/dev/trace` | Per-CPU kernel trace buffer |
| `/dev/sysname`, `/dev/osversion` | System identity |
| `/dev/time` | Wall clock + uptime (RW for root) |
| `/dev/kmesg` | Kernel log ring buffer |
| `/dev/reboot` | System reboot (root-only write) |
| `/dev/drivers` | Loaded subsystem list |
| `/dev/sysstat` | Per-core counters (ctx_switches, syscalls, interrupts) |
| `/dev/pid`, `/dev/user` | Current process info |
| `/dev/consctl` | Console raw/echo mode |
| `/cntr/` | Container management |
| `/net/*` | Network stack (when netd not mounted) |

### Kernel Pipes

Ring-buffer pipes (`src/pipe.zig`): 32 slots, 4 KB each, refcounted read/write ends. `sysPipe(result_ptr)` creates pipe, returns `[read_fd, write_fd]`. Wake pattern: waker marks process `.ready`; data delivery in `switchTo` after CR3 switch.

## Syscall Interface

Plan 9-inspired. NOT Linux-compatible. No `ioctl` — device control via text writes to control files.

| Nr | Name | Description |
|----|------|-------------|
| 0 | `open` | Open file by path (namespace → IPC to file server) |
| 1 | `create` | Create a new file |
| 2 | `read` | Read from file descriptor |
| 3 | `write` | Write to file descriptor |
| 4 | `close` | Close file descriptor |
| 5 | `stat` | Get file metadata |
| 6 | `seek` | Seek within file |
| 7 | `remove` | Delete a file |
| 8 | `mount` | Mount a file server at a path |
| 9 | `bind` | Bind a path to another path |
| 10 | `unmount` | Unmount a path |
| 11 | `rfork` | Fork with flags (RFMEM, RFNAMEG, etc.) |
| 12 | `exec` | Execute a program |
| 13 | `wait` | Wait for child process |
| 14 | `exit` | Terminate process |
| 15 | `pipe` | Create a pipe pair |
| 16 | `brk` | Adjust program break |
| 17 | `ipc_recv` | Receive IPC message on channel (blocks) |
| 18 | `ipc_reply` | Reply to an IPC message |
| 19 | `spawn` | Create child process from ELF path |
| 20 | `pread` | Positional read (block devices) |
| 21 | `pwrite` | Positional write (block devices) |
| 22 | `klog` | Kernel debug log |
| 23 | `sysinfo` | System info (ncpu, npages, nfree, uptime) |
| 24 | `sleep` | Sleep for N milliseconds |
| 25 | `shutdown` | Power off system |
| 26 | `getpid` | Get current process ID |
| 27 | `rename` | Rename file (IPC to file server) |
| 28 | `truncate` | Truncate file to size |
| 29 | `wstat` | Set file mode/uid/gid |
| 30 | `setuid` | Set process uid and gid |
| 31 | `getuid` | Get process uid and gid (packed) |
| 32 | `mmap` | Map anonymous memory |
| 33 | `munmap` | Unmap memory |
| 34 | `dup` | Duplicate file descriptor |
| 35 | `dup2` | Duplicate fd to specific number |
| 36 | `arch_prctl` | Set FS_BASE (thread-local storage) |
| 37 | `clone` | Create kernel thread |
| 38 | `futex` | Fast userspace mutex (wait/wake) |
| 39 | `ipc_pair` | Create IPC channel pair |
| 40 | `cntr_op` | Container operations (start/stop/destroy/exec) |

## Hardware Support

### x86_64

- UEFI boot with GOP framebuffer
- GDT with per-core TSS entries
- IDT with 32 CPU exception handlers + IPI vectors (253-255)
- COM1 serial (0x3F8, 115200 8N1)
- PCI bus enumeration (config space via 0xCF8/0xCFC)
- LAPIC + ACPI MADT parsing for SMP
- AP startup via INIT-SIPI-SIPI (trampoline at 0x8000)
- PIT timer (IRQ 0, ~18.2 Hz)
- CMOS RTC for wall clock time
- virtio-net NIC (legacy I/O port interface)
- virtio-blk (legacy I/O port interface)
- NVMe (PCIe MMIO, admin+I/O queue pairs)
- AHCI/SATA (MMIO BAR5, DMA)
- xHCI USB (MMIO, boot protocol keyboard + mouse)
- 4 virtual consoles (Alt+F1-F4)

### riscv64

- Freestanding boot via OpenSBI on QEMU virt machine
- Sv48 4-level paging
- PLIC interrupt controller
- PCI ECAM configuration
- MMIO UART serial
- Goldfish RTC
- virtio-net + virtio-blk (MMIO)
- Boots to full fsh shell with filesystem

## Boot Sequence

```
UEFI firmware / OpenSBI
  │
  v
main.zig: Entry point
  ├── Serial init
  ├── Framebuffer console init
  ├── PMM init (from memory map)
  ├── Kernel heap init
  ├── Architecture init (GDT, IDT, paging, CR3 switch)
  ├── IPC init
  ├── Process manager init
  ├── SYSCALL MSR setup / per-CPU state init
  ├── Fault supervisor init
  ├── Container init
  ├── PCI enumeration
  ├── Block device init (NVMe > AHCI > virtio-blk)
  ├── Network init (virtio-net)
  ├── xHCI USB init
  ├── Kernel trace init
  ├── SMP: AP startup (INIT-SIPI-SIPI)
  ├── Spawn boot services:
  │   ├── partfs (GPT partition server at /dev/)
  │   ├── fxfs (filesystem server at /)
  │   └── init (PID 1, spawns netd, crond, login on VTs)
  └── scheduleNext() — picks first ready process (never returns)
```

## Build Options

Compile-time feature flags:

| Flag | Default | Description |
|------|---------|-------------|
| `-Dposix=true` | `false` | Enable POSIX/C programs (musl libc + shim + TCC) |
| `-Dcontainers=true` | `false` | Enable container system (fnx CLI, Linux compat, bridge, TLS) |
| `-Dcluster=true` | `false` | Enable clustering (gossip discovery, 9P remote namespaces) |
| `-Dviceroy=true` | `false` | Enable deployment tooling (implies `-Dcluster=true`) |
