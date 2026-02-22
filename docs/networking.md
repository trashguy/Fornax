# Networking Stack

Fornax implements a two-tier networking architecture: a kernel TCP/DNS stack (legacy fallback) and a userspace `netd` server (Plan 9 model). When `netd` is mounted at `/net/`, all network operations route through userspace IPC. Without `netd`, the kernel stack handles `/net/*` paths directly.

## Architecture Overview

```
 ┌─────────────────────────────────────────────────────────┐
 │                    User Programs                         │
 │     curl, dnstest, fsh, etc.                            │
 │     open("/net/tcp/clone") → read/write /net/tcp/N/data │
 └──────────────────────┬──────────────────────────────────┘
                        │ IPC (T_OPEN, T_READ, T_WRITE, T_CLOSE)
                        │
 ┌──────────────────────▼──────────────────────────────────┐
 │              netd (srv/netd/main.zig)                    │
 │  Serves /net/tcp/*, /net/dns/*, /net/icmp/*, /net/status│
 │  ┌──────────────┐ ┌──────────┐ ┌─────────────────────┐  │
 │  │ 4 IPC workers│ │ frame RX │ │ timer (55ms tick)    │  │
 │  │ (ipc_recv/   │ │ thread   │ │ tcp.tick(), dns      │  │
 │  │  ipc_reply)  │ │ (ether0  │ │ retry, icmp timeout  │  │
 │  │              │ │  read)   │ │                      │  │
 │  └──────────────┘ └──────────┘ └─────────────────────┘  │
 │                                                          │
 │  Uses: lib/net/{tcp,arp,dns,icmp,ethernet,ipv4}.zig     │
 │  Struct-based, no globals — each netd has own state      │
 └──────────────────────┬──────────────────────────────────┘
                        │ read/write fd 4
                        │
 ┌──────────────────────▼──────────────────────────────────┐
 │           /dev/ether0 (src/ether.zig)                    │
 │  Raw Ethernet frame ring buffer (64 × 1518 bytes)        │
 │  Per-client: separate ring, read waiters, spinlock        │
 │  Modes: shared (kernel + userspace) or exclusive          │
 └──────────────────────┬──────────────────────────────────┘
                        │
 ┌──────────────────────▼──────────────────────────────────┐
 │           virtio-net driver (src/virtio_net.zig)         │
 │           Handles TX/RX DMA rings                        │
 └─────────────────────────────────────────────────────────┘
```

## Spawn Sequence

Init (`cmd/init/main.zig`) spawns netd during boot:

1. `fx.ipc_pair()` — creates IPC channel, returns `{server_fd, client_fd}`
2. `fx.open("/dev/ether0")` — gets raw Ethernet fd (graceful skip if no NIC)
3. `loadBin("netd")` — reads `/bin/netd` ELF from fxfs
4. `fx.spawn(elf, &mappings, null)` — fd mappings: `server_fd→3`, `ether_fd→4`
5. `fx.mount(client_fd, "/net/", 0)` — mounts netd's IPC channel at `/net/`
6. Close init's copies of all fds

After this, any process opening `/net/*` gets routed to netd via IPC.

## Kernel `/net/*` Fallback

The kernel (`src/syscall.zig:sysOpen`) intercepts `/net/*` paths for its built-in TCP/DNS stack. A `hasNetMount()` check skips this interception when a userspace server is mounted at `/net/`, letting namespace resolution route to netd instead.

Priority order in `sysOpen`:
1. `/dev/*` — always kernel-handled (devices)
2. `/net/*` — kernel TCP/DNS only if no userspace mount
3. `/proc/*` — always kernel-handled (process info)
4. Namespace resolution — fxfs, netd, any other mounted servers

## netd Server (`srv/netd/main.zig`)

### Threading Model

| Thread | Role |
|--------|------|
| Main + 3 workers | IPC recv/reply loop (`workerLoop`) |
| Frame RX | Reads `/dev/ether0`, dispatches to TCP/ARP/ICMP/DNS |
| Timer | 55ms tick loop: `tcp_stack.tick()`, DNS retry, ICMP timeout |

All threads share a single `net_lock: Mutex` protecting the network stack state.

### Handle System

netd uses a handle table (64 entries) to track open files. Each handle has a `HandleKind`:

| Kind | Created by opening | Read returns | Write accepts |
|------|-------------------|--------------|---------------|
| `tcp_clone` | `/net/tcp/clone` | connection index N | — |
| `tcp_ctl` | `/net/tcp/N/ctl` | connection state | `connect IP!port`, `announce !port`, `hangup` |
| `tcp_data` | `/net/tcp/N/data` | TCP stream data (blocks) | TCP stream data |
| `tcp_listen` | `/net/tcp/N/listen` | `N` on accept | — |
| `tcp_local` | `/net/tcp/N/local` | `IP!port` | — |
| `tcp_remote` | `/net/tcp/N/remote` | `IP!port` | — |
| `tcp_status` | `/net/tcp/N/status` | connection state text | — |
| `dns_ctl` | `/net/dns/ctl` | — | `nameserver IP` |
| `dns_query` | `/net/dns/DOMAIN` | resolved IP | — |
| `dns_cache` | `/net/dns/cache` | cache dump | — |
| `icmp_clone` | `/net/icmp/clone` | connection index N | — |
| `icmp_ctl` | `/net/icmp/N/ctl` | — | `ping IP` |
| `icmp_data` | `/net/icmp/N/data` | ping reply text (blocks) | — |
| `net_status` | `/net/status` | MAC/IP/gateway/mask | — |

### Blocking Reads

When a TCP data or ICMP data read finds no data available, the IPC worker polls with `fx.sleep(10ms)` up to 3000 iterations (~30 seconds). Other worker threads continue serving new requests. If data arrives (from frame RX thread), the next poll finds it and replies.

### Path Resolution

netd receives path suffixes via T_OPEN (e.g., `tcp/clone`, `dns/example.com`, `icmp/0/data`). The `handleOpen` function parses these to create the appropriate handle kind.

## `/dev/ether0` — Raw Ethernet Interface

Kernel module: `src/ether.zig`

Provides raw Ethernet frame access for userspace network servers.

| Property | Value |
|----------|-------|
| Max clients | 8 |
| Ring size | 64 frames per client |
| Max frame | 1518 bytes |
| BSS per client | ~98 KB |

### Operations

| Operation | Description |
|-----------|-------------|
| `open("/dev/ether0")` | Allocate a client slot, get an fd |
| `read(fd, buf)` | Dequeue next frame from ring (blocks if empty) |
| `write(fd, frame)` | Send raw Ethernet frame via virtio-net |
| `write(fd, "exclusive")` | Disable kernel stack processing (netd owns all frames) |
| `write(fd, "shared")` | Re-enable dual delivery (kernel + userspace) |

When any ether client is active, `net.handleFrame()` copies incoming frames into all client rings. In shared mode (default), the kernel stack also processes frames. In exclusive mode, frames go only to userspace clients.

## Userspace Network Libraries (`lib/net/`)

Struct-based ports of kernel protocol modules. Each instance has independent state — no globals. Designed for per-realm network isolation.

| Library | Struct | Key difference from kernel |
|---------|--------|---------------------------|
| `lib/net/tcp.zig` | `TcpStack` | Callback-based: `SendFn`, `GetIpFn`, `GetTicksFn`, `WaiterCallback` |
| `lib/net/arp.zig` | `ArpTable` | `SendFn` callback for frame TX |
| `lib/net/dns.zig` | `DnsResolver` | `SendUdpFn` + `GetTimeFn` callbacks, millisecond TTL |
| `lib/net/icmp.zig` | `IcmpHandler` | `SendIpFn` + `GetTimeFn` callbacks, timeout array return |
| `lib/net/ethernet.zig` | (pure functions) | Identical to kernel — parse/build are stateless |
| `lib/net/ipv4.zig` | (pure functions) | Identical to kernel, explicit `ttl`/`packet_id` params |

All re-exported via `lib/root.zig` as `fx.net.tcp`, `fx.net.arp`, etc.

### TcpStack Highlights

- 256 connections (configurable via `max_connections` runtime limit, default 32 in netd)
- Per-connection spinlock + FNV-1a hash table for O(1) demux
- ~23 KB per connection (16 KB RX buffer + 4 KB TX buffer + metadata)
- BSS allocation with `linksection(".bss")` — unused slots don't cost physical memory on demand-paged systems

## SMP TCP Improvements (Kernel Stack)

The kernel TCP stack (`src/net/tcp.zig`) was hardened for SMP:

### Per-Connection Locking

| Lock | Scope | Protects |
|------|-------|----------|
| `alloc_lock` (global) | Connection allocation | `conn_hash[]`, `in_use` flags, ephemeral ports |
| `conn.lock` (per-connection) | Connection state | Buffers, sequence numbers, waiters, state machine |

Lock ordering: `conn.lock` → `alloc_lock` (never reversed). `handlePacket` acquires `alloc_lock` for lookup, releases it, then acquires `conn.lock` — never holds both simultaneously.

### Hash Table Demux

FNV-1a hash on `(local_port, remote_port, remote_ip)` → 256 buckets with chaining via `hash_next: u8` field (0xFF sentinel). Established connections found in O(1). Listeners still use linear scan (rare — SYN-only path).

### Connection Pool

- `MAX_CONNECTIONS = 256` (u8 natural limit)
- `FdEntry.net_conn: u8` — no changes needed outside tcp.zig
- BSS cost: ~5.8 MB (256 × 23 KB)
- `freeConn` preserves lock field (doesn't zero entire struct)
- `allocLocked` resets all fields on reuse

## IPC Channel Pairs (SYS 39)

`ipc_pair()` creates an IPC channel and returns two fds (server + client) to the calling process. Used by init to set up communication channels for servers like netd.

```
result = fx.ipc_pair();
// result.server_fd → pass to server via spawn fd mappings
// result.client_fd → mount at desired path
```

This enables userspace servers to be spawned and mounted without kernel involvement beyond the initial channel creation.

## `mount` / `unmount` Syscalls

| Syscall | Args | Description |
|---------|------|-------------|
| `SYS 8 mount` | `fd, path_ptr, path_len, flags` | Mount IPC channel fd at path in process namespace |
| `SYS 10 unmount` | `path_ptr, path_len` | Remove mount point |

Namespace resolution (`src/namespace.zig:resolve`) finds the longest matching mount prefix. A mount at `/net/` (len 5) takes priority over root `/` (len 1).

## Hardware Layer

### PCI Enumeration (`src/arch/x86_64/pci.zig`)

Scans PCI bus 0, slots 0-31, reading config space via I/O ports `0xCF8` (address) and `0xCFC` (data). Each discovered device is logged to serial with vendor/device IDs and class codes.

`PciDevice` stores vendor ID, device ID, class/subclass, and BARs. Helper methods extract the I/O base address from BAR0 and enable bus mastering (required for DMA).

### virtio-net Driver (`src/virtio_net.zig`)

Uses the **virtio legacy I/O port interface** (virtio spec 0.9.5).

**Device discovery**: Finds vendor `0x1AF4` (Red Hat/Virtio), device `0x1000` (transitional net) or `0x1041` (modern net).

**Initialization sequence**:
1. Enable PCI bus mastering
2. Reset device (write 0 to status register)
3. Acknowledge + set DRIVER status
4. Read device features, negotiate (`MAC` + `STATUS`, no `MRG_RXBUF`)
5. Set up RX queue (index 0) and TX queue (index 1)
6. Post 16 receive buffers (4 KB pages from PMM)
7. Read MAC address from device config at BAR0 + `0x14`
8. Set DRIVER_OK status

**Virtqueue layout** (allocated from PMM, physically contiguous):
```
[Descriptor table: 16 bytes * queue_size]
[Available ring: 4 + 2 * queue_size + 2 bytes]
--- page-aligned boundary ---
[Used ring: 4 + 8 * queue_size + 2 bytes]
```

**Frame format**: Every frame is prepended with a 10-byte `VirtioNetHeader` (flags, GSO type/size, checksum offsets). All zeros for basic operation.

## Protocol Layers

### Ethernet (`src/net/ethernet.zig`)

IEEE 802.3 frame handling.

**Frame layout**: `[dst MAC 6][src MAC 6][EtherType 2][payload 46-1500]`

- `parse()`: Extracts header fields and payload slice. EtherType is big-endian.
- `build()`: Writes a complete frame into a buffer. Returns total length.
- Constants: `ETHER_ARP` (0x0806), `ETHER_IPV4` (0x0800), `BROADCAST` (FF:FF:FF:FF:FF:FF).

### ARP (`src/net/arp.zig`)

32-entry cache with round-robin eviction. No TTL. Every ARP packet inserts the sender's IP/MAC. ARP requests for our IP get unicast replies.

### IPv4 (`src/net/ipv4.zig`)

Minimal IPv4: no fragmentation, no options, no routing table. TTL 64, Don't Fragment flag. RFC 1071 ones-complement checksum.

**Default config** (QEMU user-mode networking):
| Field | Value |
|-------|-------|
| IP | 10.0.2.15 |
| Gateway | 10.0.2.2 |
| Subnet mask | 255.255.255.0 |

### TCP (`src/net/tcp.zig`)

Full TCP with connection tracking, retransmission, and flow control. 256 connections with per-connection locks and hash table demux (see SMP section above).

### ICMP (`src/net/icmp.zig`)

Echo request/reply (ping). 4-slot connection pool with timeout tracking.

### UDP (`src/net/udp.zig`)

16 connection slots with port multiplexing. Single-datagram receive buffer per connection.

### DNS (`src/net/dns.zig`)

Recursive DNS resolver with 16-entry cache. Configurable nameserver. 3-second query timeout with retry.

## QEMU Setup

The run script (`scripts/run-x86_64.sh`) includes:
```
-device virtio-net-pci,netdev=net0
-netdev user,id=net0
```

QEMU user-mode networking provides a virtual network at `10.0.2.0/24` with:
- Gateway/DHCP at `10.0.2.2`
- DNS at `10.0.2.3`
- Fornax configured at `10.0.2.15`

## Plan 9 `/net/` Interface

The standard interface for network operations (served by netd):

```
/net/
├── status              MAC/IP/gateway/mask
├── tcp/
│   ├── clone           open → allocate connection, read → N
│   └── N/
│       ├── ctl         write: "connect IP!port", "announce !port", "hangup"
│       ├── data        read/write TCP stream
│       ├── listen      open+read blocks until connection accepted
│       ├── local       read: "IP!port"
│       ├── remote      read: "IP!port"
│       └── status      read: connection state
├── dns/
│   ├── ctl             write: "nameserver IP"
│   ├── cache           read: cache dump
│   └── DOMAIN          open+read → resolved IP
└── icmp/
    ├── clone           open → allocate slot, read → N
    └── N/
        ├── ctl         write: "ping IP"
        └── data        read: ping reply (blocks until reply/timeout)
```

No sockets API. To make an HTTP request:
1. `open("/net/tcp/clone")` → read to get connection N
2. `write("/net/tcp/N/ctl", "connect 93.184.216.34!80")`
3. `write("/net/tcp/N/data", "GET / HTTP/1.1\r\n...")`
4. `read("/net/tcp/N/data")` → response

## Future Work

- **Bridge server** (`srv/bridge/main.zig`): Software Ethernet switch + NAT for container networking. Requires container infrastructure.
- **Per-realm isolation**: Each POSIX realm/container gets its own netd instance with independent state. Tested via `rfork(RFNAMEG)` + per-realm mount.
- **ctl file expansion**: Runtime TCP tuning (keepalive, MSS, window scaling), routing tables, interface configuration.
