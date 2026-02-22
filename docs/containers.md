# Fornax Container System

Fornax containers compose existing kernel primitives — namespaces, resource quotas, ELF loading, and IPC channels — into an isolated execution environment. A container is not a special kernel concept; it combines existing mechanisms behind a Plan 9-style file interface.

## Architecture

```
Host                           Container
┌─────────────────┐            ┌──────────────────────┐
│ /bin/fsh         │            │ /bin/sh (Alpine)     │
│ /bin/fnx         │            │ /usr/bin/...         │
│ host netd (/net/)│            │ container netd       │
│                  │            │   (/net/ in cntr ns) │
└────────┬─────────┘            └──────────┬───────────┘
         │ namespace: host                  │ namespace: isolated
         │                                  │ rootfs prefix:
         │                                  │  /var/lib/fnx/containers/<name>/rootfs/
┌────────▼──────────────────────────────────▼──────────┐
│                   Fornax Kernel                       │
│  /cntr/ virtual FS   │  container registry            │
│  SYS 40 cntr_op      │  linux_compat dispatch         │
│  namespace prefixes   │  quota enforcement             │
└──────────────────────────────────────────────────────┘
```

Feature-gated behind `-Dcontainers=true`. Independent of `-Dposix=true`.

## `/cntr/` Virtual Filesystem

Kernel-intercepted (like `/proc/`). Follows the Plan 9 clone pattern.

### Clone

**`/cntr/clone`** (read): Allocates a new container slot, returns its decimal ID.
```sh
cat /cntr/clone    # → "3\n"
```

### Status

**`/cntr/N/status`** (read): Container state as key-value text.
```
id 3
name myalpine
state running
compat linux
init_pid 42
procs 5
pages 1024
quota_pages 8192
quota_children 16
rootfs /var/lib/fnx/containers/myalpine/rootfs
ip 10.0.1.4
cmd /bin/sh
```

### Control

**`/cntr/N/ctl`** (write):

| Command | Action |
|---------|--------|
| `name <name>` | Set container name (state=created only). |
| `rootfs <path>` | Set rootfs path (state=created only). |
| `compat linux` | Enable Linux syscall translation. |
| `compat fornax` | Native Fornax binaries (default). |
| `cmd <command>` | Set default command. |
| `quota pages N` | Set memory page quota. |
| `quota children N` | Set max child processes. |
| `stop` | Kill all container processes, set state=stopped. |
| `destroy` | Stop + free container slot. |

### Process List

**`/cntr/N/procs`** (read): PIDs of processes in this container (one per line).

### Directory

**`/cntr/`** (read): Directory listing of active container IDs.

## `fnx` CLI Reference

Podman-familiar interface. All operations map to `/cntr/` file operations.

| Command | Description |
|---------|-------------|
| `fnx run [-d] [--name N] [--compat linux] <image> [cmd]` | Create, start, optionally wait. |
| `fnx create [--name N] <image>` | Create without starting. |
| `fnx start <name\|id>` | Start a created container. |
| `fnx stop <name\|id>` | Stop a running container. |
| `fnx rm <name\|id>` | Destroy a container. |
| `fnx exec <name\|id> <cmd> [args...]` | Execute command in running container. |
| `fnx ps [-a]` | List running (or all) containers. |
| `fnx images` | List images in `/var/lib/fnx/images/`. |
| `fnx inspect <name\|id>` | Show container status (reads `/cntr/N/status`). |
| `fnx import <tarball> <name>` | Extract tarball into image rootfs. |
| `fnx cp <src> <container:dest>` | Copy file into container rootfs. |
| `fnx build -f <Containerfile> -t <tag> [context]` | Build image from Containerfile. |

### Example Workflow

```sh
# Import Alpine Linux
fnx import /tmp/alpine-minirootfs.tar.gz alpine

# Run with Linux compat
fnx run --name mybox --compat linux alpine /bin/sh

# From another terminal
fnx ps
fnx exec mybox /bin/busybox ls /
fnx stop mybox
fnx rm mybox
```

## Linux Syscall Compatibility

Enables running unmodified musl-linked Linux binaries (Alpine, etc.) inside containers.

```
Linux binary
    │ SYSCALL (RAX = Linux number)
    │
    ▼
src/syscall.zig dispatch()
    │
    ├── proc.compat == 0 → normal Fornax handlers
    └── proc.compat == 1 → linuxDispatch() in src/linux_compat.zig
                              │
                              ▼
                           LNX_READ → sysRead()
                           LNX_WRITE → sysWrite()
                           LNX_OPENAT → sysOpen()
                           LNX_MMAP → sysMmap()
                           ...
```

Detection: Set via `/cntr/N/ctl` `compat linux` command, or auto-inherited from parent container.

### Key Translations

| Linux # | Name | Fornax Handler |
|---------|------|---------------|
| 0 | read | sysRead |
| 1 | write | sysWrite |
| 2 | open | sysOpen (+ strlen) |
| 3 | close | sysClose |
| 8 | lseek | sysSeek |
| 9 | mmap | sysMmap |
| 11 | munmap | sysMunmap |
| 12 | brk | sysBrk |
| 56 | clone | sysClone |
| 57 | fork | sysRfork(RFPROC) |
| 59 | execve | sysExec |
| 61 | wait4 | sysWait |
| 63 | uname | returns "Fornax" |
| 158 | arch_prctl | sysArchPrctl |
| 202 | futex | sysFutex |
| 231 | exit_group | sysExit |
| 257 | openat | sysOpen (AT_FDCWD) |

## Container Rootfs & Images

### Directory Layout

```
/var/lib/fnx/
├── images/                     ← immutable base images
│   ├── fornax-base/
│   │   ├── rootfs/             ← fsh + core utils
│   │   └── config              ← default command
│   └── alpine/
│       ├── rootfs/             ← Alpine minirootfs
│       └── compat              ← "linux"
└── containers/                 ← per-container instances
    └── mybox/
        └── rootfs/             ← copy of image rootfs
```

### Namespace Prefix Remapping

Container processes see an isolated root filesystem via namespace mount prefix. When a container opens `/bin/sh`, the namespace resolves to `var/lib/fnx/containers/mybox/rootfs/bin/sh` on the host fxfs.

The `MountEntry.prefix` field in `src/namespace.zig` prepends a path to all IPC T_OPEN operations going to the mount's fxfs channel.

## Containerfile Reference

Supported instructions:

| Instruction | Description |
|-------------|-------------|
| `FROM <base>` | Base image (`scratch` for empty). |
| `COPY <src> <dest>` | Copy file from build context to rootfs. |
| `RUN <cmd>` | Execute command in temporary container. |
| `CMD ["cmd"]` or `CMD cmd` | Default command. |
| `WORKDIR <dir>` | Create directory in rootfs. |
| `ENTRYPOINT ["cmd"]` | Entry point (overrides CMD). |
| `ENV <key>=<val>` | Environment variable (metadata). |
| `EXPOSE <port>` | Port metadata. |
| `LABEL <k>=<v>` | Metadata label. |
| `USER <name>` | Run as user. |

### Build Process

```sh
fnx build -f Containerfile -t myapp /src
```

1. **FROM**: Copy base image rootfs (or create empty for `scratch`).
2. **COPY**: Copy files from build context directory.
3. **RUN**: Start temporary container with image rootfs, execute shell command, wait.
4. **CMD/WORKDIR/ENV**: Update image config.
5. Save to `/var/lib/fnx/images/<tag>/`.

## Container Networking

### Shared Ether (v1)

Each container's netd gets its own `/dev/ether0` client. All clients receive all frames; each netd filters by its own IP. Container IPs from the 10.0.1.0/24 range.

### Bridge + NAT (v2)

The bridge server (`srv/bridge/main.zig`) provides L2 isolation and NAT.

```
Container netd ──IPC──▶ bridge port N ──▶ bridge ──▶ /dev/ether0
Host netd      ──direct ether access──▶ /dev/ether0
```

Bridge ctl files at `/bridge/`:

| Path | R/W | Description |
|------|-----|-------------|
| `/bridge/clone` | R | Allocate virtual port, returns port ID. |
| `/bridge/N/ctl` | W | `mac XX:XX:XX:XX:XX:XX`, `ip A.B.C.D`. |
| `/bridge/N/data` | RW | Raw Ethernet frame I/O for this port. |
| `/bridge/status` | R | Port list + NAT entry count. |
| `/bridge/ctl` | W | `flush` — clear NAT and MAC tables. |

NAT: SNAT rewrites container source IP (10.0.1.x) to host IP (10.0.2.15) for outbound traffic. DNAT rewrites destination IP back for inbound replies. Incremental checksum update (RFC 1624) for IP + TCP/UDP headers.

## Resource Quotas

Container-wide quotas enforce aggregate limits across all processes in a container.

| Quota | Description |
|-------|-------------|
| `max_memory_pages` | Total physical pages across all container processes. |
| `max_children` | Maximum process count in container. |

Enforcement:
- `allocPageForProcess()` checks container aggregate (`canAllocPage`) before PMM allocation.
- `sysSpawn` checks `canSpawnProcess()` before `process.create()`.
- Container processes cannot write `/dev/reboot` or manage other containers.

## SYS 40: `cntr_op`

Single syscall for container lifecycle operations.

```
cntr_op(op, cntr_id, arg0, arg1, arg2) → result
```

| Op | Name | Arguments | Description |
|----|------|-----------|-------------|
| 0 | start | elf_ptr, elf_len, argv_ptr | Start container init process. |
| 1 | stop | — | Kill all container processes. |
| 2 | destroy | — | Stop + free slot. |
| 3 | exec | elf_ptr, elf_len, argv_ptr | Spawn process in running container. |
| 4 | start_netd | netd_elf_ptr, netd_elf_len | Spawn netd with ether client. |

## SMP Considerations

| Component | Lock Strategy |
|-----------|--------------|
| Container registry | Global `containers_lock` (create/destroy only). |
| Per-container state | `ct.lock` spinlock for state transitions. |
| Page quota tracking | `@atomicRmw` on `pages_used_total` (no spinlock on hot path). |
| Process count | `@atomicRmw` on `process_count`. |
| Linux compat dispatch | Pure function — zero shared state, zero locks. |
| Bridge frame routing | `bridge_lock: Mutex` (coarse, per-operation). |
| NAT/MAC tables | Protected by `bridge_lock`. |

Lock ordering: `process.table_lock → ct.lock → pmm_lock → bridge_lock → ipc.chan.lock`.

## Design Decisions

**Why kernel translation instead of a VM?** Fornax's syscall interface is already close to Linux. The `shim.c` POSIX layer (60+ translations) proves the mapping works. Kernel-side translation adds ~200 lines vs. a hypervisor. Same approach as WSL1.

**Why SYS 40?** Starting a container requires loading an ELF binary into a new address space — the kernel can't do this from a ctl write handler (synchronous IPC). Same pattern as `spawn` (SYS 19).

**Why directory-based images?** No layers in v1. Each image is a directory tree on fxfs. Simple, debuggable, fits the Plan 9 ethos. Layers can be added later as a union mount.

**Why `fnx` not `podman`?** Fornax-native but familiar. Power users can use raw `/cntr/` files directly.
