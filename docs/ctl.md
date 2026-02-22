# Control Files Reference

Fornax follows Plan 9's "everything is a file" philosophy. System configuration and monitoring is performed by reading and writing virtual files rather than through special-purpose syscalls.

## Kernel Virtual Files (`/dev/`)

These files are intercepted by the kernel in `sysOpen` and handled directly in `sysRead`/`sysWrite`. No filesystem server is involved.

### Identity & Info

| Path | R/W | Description |
|------|-----|-------------|
| `/dev/sysname` | RW | Hostname. Read returns name + `\n`. Write sets (max 63 chars). Default: `fornax`. |
| `/dev/osversion` | R | OS version string. Returns `Fornax 0.1\n`. |
| `/dev/time` | RW | Read: `<epoch_secs> <uptime_secs>\n`. Write (root): set epoch seconds. |
| `/dev/pid` | R | Current process PID (decimal) + `\n`. |
| `/dev/user` | R | Current process UID (decimal) + `\n`. |
| `/dev/kmesg` | R | Kernel log ring buffer (64 KB). Supports offset-based reads. |
| `/dev/drivers` | R | One line per initialized kernel subsystem (e.g. `console\nvirtio_blk\n`). |

### Control

| Path | R/W | Description |
|------|-----|-------------|
| `/dev/reboot` | W | `reboot` or `halt`. Root only (uid 0). |
| `/dev/consctl` | W | Console control: `rawon`, `rawoff`, `echo on`, `echo off`, `size`. Delegates to keyboard driver. |

### Hardware & Stats

| Path | R/W | Description |
|------|-----|-------------|
| `/dev/sysstat` | R | Per-core stats, one line per online core: `core_id ctx_switches interrupts syscalls idle_ticks`. |
| `/dev/cpu` | R | CPU identification (vendor, brand, family/model on x86_64; ISA/SBI on riscv64). |
| `/dev/pci` | R | PCI device list: `BB:SS.F VVVV:DDDD CC:SS:PP` per line. |
| `/dev/usb` | R | USB device list from xHCI. |
| `/dev/mouse` | R | Mouse event stream (3-byte packets). |
| `/dev/ether0` | W | Ethernet mode: `exclusive` or `shared`. |

### Null Devices

| Path | R/W | Description |
|------|-----|-------------|
| `/dev/null` | RW | Discards writes, reads return EOF. |
| `/dev/zero` | R | Reads return zero bytes. |
| `/dev/random` | R | Reads return pseudo-random bytes (xorshift64). |

## Process Control (`/proc/`)

Kernel-intercepted. Each running process has a directory `/proc/N/`.

### `/proc/N/status` (read)

Returns process state as key-value text:
```
pid N
ppid N
state running|blocked|ready|dead
pages N
uid N
gid N
core N
affinity N|any
vt N
name <basename>
```

### `/proc/N/ctl` (write)

| Command | Action |
|---------|--------|
| `kill` | Terminate process. |
| `stop` | Suspend process (blocked with no pending op). |
| `start` | Resume a stopped process. |
| `wired N` | Pin to core N. Validates N < cores_online. |
| `wired any` | Clear core affinity. |
| `killgrp` | Kill all children of this process. |
| `close N` | Close fd N in the target process. |

### `/proc/meminfo` (read)

```
total_pages N
free_pages N
page_size 4096
total_bytes N
free_bytes N
used_pages N
```

## Filesystem Control (`/ctl`)

Served by fxfs. The `/ctl` path opens a virtual handle with sentinel inode.

### Read

```
TOTAL=N
FREE=N
BSIZE=4096
NODES=N
GEN=N
DIRTY=N
```

| Field | Description |
|-------|-------------|
| TOTAL | Total blocks on filesystem. |
| FREE | Free blocks available. |
| BSIZE | Block size (always 4096). |
| NODES | Next inode number (approximate allocated inodes). |
| GEN | Filesystem generation (increments on each transaction commit). |
| DIRTY | 1 if bitmap has uncommitted changes, 0 otherwise. |

### Write

| Command | Action |
|---------|--------|
| `sync` | Flush bitmap and write superblock to disk. |
| `check` | Stub for future B-tree consistency check (no-op, returns OK). |

## Network Control (`/net/`)

Served by netd (userspace daemon). Mounted via IPC.

### TCP (`/net/tcp/`)

| Path | R/W | Description |
|------|-----|-------------|
| `/net/tcp/clone` | R | Allocate new connection, returns connection ID. |
| `/net/tcp/N/ctl` | W | `connect IP!PORT`, `announce PORT`, `hangup`. |
| `/net/tcp/N/data` | RW | Read/write TCP stream data. |
| `/net/tcp/N/listen` | R | Block until incoming connection on announced port. |

### DNS (`/net/dns/`)

| Path | R/W | Description |
|------|-----|-------------|
| `/net/dns/resolve` | RW | Write hostname, read resolved IP address. |
| `/net/dns/ctl` | W | `nameserver IP`, `flush`. |

### ICMP (`/net/icmp/`)

| Path | R/W | Description |
|------|-----|-------------|
| `/net/icmp/clone` | R | Allocate ICMP handle. |
| `/net/icmp/N/ctl` | W | `connect IP` — set destination. |
| `/net/icmp/N/data` | RW | Write sends echo request, read returns echo reply. |

### ARP & Stats

| Path | R/W | Description |
|------|-----|-------------|
| `/net/arp` | RW | Read: dump ARP cache (`IP MAC\n` per entry). Write: `flush`, `del IP`. |
| `/net/stats` | R | TCP counters: `segments_tx`, `segments_rx`, `retransmits`, `active_opens`, `passive_opens`, `active_conns`. |
| `/net/status` | R | Interface config: MAC, IP, gateway, netmask. |

### Interface Config

| Path | R/W | Description |
|------|-----|-------------|
| `/net/ipifc/0/ctl` | RW | Read: `ip IP mask MASK gateway GW mtu 1500\n`. Write: `add IP mask GW`. |

## Implementation Notes

- Kernel virtual files use `FdType` enum variants in `src/process.zig`
- `sysOpen` in `src/syscall.zig` intercepts paths under `/dev/`, `/proc/`, `/net/`
- Server-backed files (fxfs `/ctl`, netd `/net/*`) use IPC protocol with `HandleKind` dispatch
- Per-CPU counters (`ctx_switches`, `syscalls`, `interrupts`) live in `src/percpu.zig` PerCpu struct
- All reads support offset-based access for `cat` compatibility (read until EOF)
- Write commands accept optional trailing newline (stripped before parsing)
