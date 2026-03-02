# Fornax Container System

Fornax containers compose existing kernel primitives — process groups, namespaces, resource quotas, ELF loading, and IPC channels — into an isolated execution environment. A container is not a special kernel concept; it combines existing mechanisms behind a Plan 9-style file interface served by a userspace IPC server (`srv/cntrd`).

## Architecture

```
Host                           Container
┌─────────────────┐            ┌──────────────────────┐
│ /bin/fsh         │            │ /bin/sh (Alpine)     │
│ /bin/fnx         │            │ /usr/bin/...         │
│ host netd (/net/)│            │ container netd       │
│                  │            │   (/net/ in cntr ns) │
└────────┬─────────┘            └──────────┬───────────┘
         │ namespace: host                 │ namespace: isolated
         │                                 │ rootfs prefix:
         │                                 │  /var/lib/fnx/containers/<name>/rootfs/
┌────────▼─────────────────────────────────▼──────────┐
│              Userspace Servers                        │
│  cntrd (/cntr/)  │  bridge (/bridge/)                │
│  netd (/net/)    │  fxfs (/)                         │
├──────────────────────────────────────────────────────┤
│                   Fornax Kernel                       │
│  process_group.zig  │  SYS 46 proc_setup             │
│  sysSpawn (blocked) │  namespace prefixes             │
│  quota enforcement  │  linux_compat dispatch          │
└──────────────────────────────────────────────────────┘
```

## `/cntr/` File Interface

Served by `srv/cntrd/main.zig`, a userspace IPC server mounted at `/cntr/`. Follows the Plan 9 clone pattern.

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
| `started <pid>` | Notify cntrd of init process PID (called by fnx). |
| `netd <pid>` | Notify cntrd of netd process PID (called by fnx). |

### Process List

**`/cntr/N/procs`** (read): PIDs of processes in this container (one per line).

### Directory

**`/cntr/`** (read): Directory listing of active container IDs.

## `fnx` CLI Reference

Podman-familiar interface. All operations map to `/cntr/` file operations + composable kernel primitives.

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

## Container Lifecycle (spawn_blocked + proc_setup)

Container creation uses composable kernel primitives instead of a monolithic syscall:

```
fnx run alpine:latest
  1. fnx reads /cntr/clone → allocates container in cntrd, gets cntr_id
  2. fnx writes ctl commands to set metadata (name, rootfs, compat, cmd)
  3. fnx calls group_alloc() → allocates kernel ProcessGroup, gets group_id
  4. fnx calls spawn_blocked(elf, len, group_id, compat_flags) → blocked pid
  5. fnx calls proc_setup(pid, CLEARNM)         → isolate namespace
  6. fnx calls proc_setup(pid, MOUNTPFX, ...)   → mount rootfs with prefix
  7. fnx calls proc_setup(pid, SETARGV, argv)   → copy argv + set up auxv
  8. fnx calls proc_setup(pid, SETQUOTA, ...)    → set resource quotas
  9. fnx calls proc_setup(pid, READY)            → mark runnable
  10. fnx writes ctl "started <pid>"             → notify cntrd
  11. fnx spawns container netd (ether fd + IPC channel)
  12. fnx calls wait(pid) for foreground, or returns for detached
```

The `spawn_blocked` + `proc_setup` pattern gives userspace full control over process setup:
- Namespace isolation (CLEARNM clears, CLONENM clones from another process)
- Mount configuration (MOUNT, MOUNTPFX for rootfs prefix)
- File descriptor inheritance (SETFD)
- Compat mode (SETCOMPAT)
- Resource quotas (SETQUOTA)
- Process group assignment (SETGROUP)
- Argv/auxv setup (SETARGV)

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

Detection: Set via `proc_setup(pid, SETCOMPAT, 1, 0)` during spawn, or auto-inherited from parent container.

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

Container-wide quotas enforce aggregate limits across all processes in a process group.

| Quota | Description |
|-------|-------------|
| `max_memory_pages` | Total physical pages across all group processes. |
| `max_children` | Maximum process count in group. |

Enforcement:
- `allocPageForProcess()` checks group aggregate (`canAllocPage`) before PMM allocation.
- `sysSpawn` checks `canSpawnProcess()` before `process.create()`.
- Container processes cannot write `/dev/reboot` or manage other containers.

## Kernel Primitives

### Process Groups (`src/process_group.zig`)

Lightweight kernel-side resource tracking. No policy, no lifecycle — just quotas and group kill.

```zig
pub const ProcessGroup = struct {
    active: bool,
    id: u8,
    quotas: process.ResourceQuotas,
    process_count: u16,
    pages_used_total: u32,
    net_ip: u32,
    lock: SpinLock,
};
```

API: `alloc()`, `free()`, `getById()`, `addProcess/removeProcess`, `addPages/subPages`, `canAllocPage/canSpawnProcess`, `killAll/killAllExcept`.

Constants: `MAX_GROUPS = 16`, `HOST_GROUP = 0xFF` (uncontained processes).

### SYS 46: `proc_setup`

Composable process configuration syscall. Operates on a blocked process owned by the caller.

```
proc_setup(pid, op, arg0, arg1) → 0 or error
```

| Op | Name | Args | Effect |
|----|------|------|--------|
| 0 | MOUNT | path_ptr, caller_fd | Mount caller's fd in child's namespace |
| 1 | SETFD | child_fd, parent_fd | Copy caller's fd → child's fd table |
| 2 | SETCOMPAT | mode, 0 | Set compat (0=fornax, 1=linux) |
| 3 | SETQUOTA | pages, children | Set resource quotas |
| 4 | READY | 0, 0 | Mark runnable (must be last) |
| 5 | SETARGV | argv_ptr, 0 | Copy argv + set up auxv in child |
| 6 | SETGROUP | group_id, 0 | Assign process group |
| 7 | CLEARNM | 0, 0 | Clear child's namespace |
| 8 | MOUNTPFX | path_ptr, packed | Mount with prefix (rootfs isolation) |
| 9 | CLONENM | source_pid, 0 | Clone namespace from another process |
| 10 | ALLOCGROUP | 0, 0 | Allocate group → returns id |
| 11 | GROUPKILL | group_id, 0 | Kill all in group |
| 12 | FREEGROUP | group_id, 0 | Free a group |
| 13 | SETQUOTA_GROUP | group_id, packed | Set group quotas |

Mount ops (MOUNT, MOUNTPFX) accept a **caller fd** index, not a raw channel_id. The kernel resolves the fd to its underlying channel_id via `getFdEntry()`.

### `sysSpawn` Blocked Mode

Extended SYS 19. If bit 31 of arg3 (fd_map_len) is set, the process is created in **blocked** state:

```
spawn(elf_ptr, elf_len, group_id, 0x80000000 | flags, 0) → blocked pid
```

- `flags` bit 0: `SPAWN_COMPAT_LINUX` (sets compat=1)
- Process stays `.blocked` — not runnable until `proc_setup(pid, READY)`
- ELF load info stored on Process struct for later `SETARGV`
- Old calling convention (no bit 31) unchanged — existing `spawn()` works

## SMP Considerations

| Component | Lock Strategy |
|-----------|--------------|
| Process group registry | Global `groups_lock` (alloc/free only). |
| Per-group state | `g.lock` spinlock for state transitions. |
| Page quota tracking | `@atomicRmw` on `pages_used_total` (no spinlock on hot path). |
| Process count | `@atomicRmw` on `process_count`. |
| Linux compat dispatch | Pure function — zero shared state, zero locks. |
| cntrd server | Single-threaded userspace IPC server. |
| Bridge frame routing | `bridge_lock: Mutex` (coarse, per-operation). |
| NAT/MAC tables | Protected by `bridge_lock`. |

Lock ordering: `process.table_lock → g.lock → pmm_lock → bridge_lock → ipc.chan.lock`.

## Design Decisions

**Why userspace container management?** Container lifecycle (create/start/stop/destroy) is policy that doesn't belong in the kernel. Moving it to `srv/cntrd` reduces kernel complexity by ~800 lines and follows the microkernel principle. The kernel provides only the composable primitives (`spawn_blocked`, `proc_setup`, process groups).

**Why `proc_setup` instead of extending `spawn`?** A single `spawn` call can't express the full configuration space (multiple mounts, fd inheritance, namespace cloning, quotas). The `proc_setup` pattern lets userspace compose configuration steps in any order.

**Why fd-based mount ops?** Userspace doesn't know IPC channel_ids — those are kernel-internal. Mount ops accept caller fd indices, and the kernel resolves them to channel_ids. This keeps the abstraction clean.

**Why directory-based images?** No layers in v1. Each image is a directory tree on fxfs. Simple, debuggable, fits the Plan 9 ethos. Layers can be added later as a union mount.

**Why `fnx` not `podman`?** Fornax-native but familiar. Power users can use raw `/cntr/` files directly.
