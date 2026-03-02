# Phase 1011 — Delete Kernel Network Stack

## Depends On

Phase 1010 (socket shim). After 1010, no code path calls the kernel TCP/ARP/DNS/ICMP
stack — all networking goes through netd via IPC.

## Problem

The kernel contains a full TCP/IP stack (`src/net/tcp.zig`, `udp.zig`, `arp.zig`,
`dns.zig`, `icmp.zig`, `netfs.zig`) that duplicates the userspace netd. This code:
- Adds ~4000 lines to the kernel
- Creates two competing ARP caches, DNS resolvers, and TCP state machines
- Requires complex "exclusive mode" frame routing in `src/net.zig` to avoid conflicts
- Exposes `FdType.net` with 14 `NetFdKind` variants and dedicated PendingOp values

After Phase 1010, all Linux compat socket calls route through IPC to netd. Native Fornax
programs already use `/net/` files → IPC. The kernel TCP stack is dead code.

## Solution

Delete the kernel network stack entirely. Reduce `src/net.zig` to ~30 lines: read MAC
from virtio-net, poll frames, deliver to ether clients.

## Files Deleted

| File | Lines | Purpose |
|------|-------|---------|
| `src/net/tcp.zig` | ~1200 | Kernel TCP state machine |
| `src/net/udp.zig` | ~100 | Kernel UDP handler |
| `src/net/arp.zig` | ~200 | Kernel ARP cache |
| `src/net/dns.zig` | ~300 | Kernel DNS resolver |
| `src/net/icmp.zig` | ~200 | Kernel ICMP handler |
| `src/net/netfs.zig` | ~400 | Plan 9 /net/ file ops for kernel stack |
| `docs/TODO/002-net-bugs.md` | — | All tracked bugs were in kernel stack |

Retained:
- `src/net/ethernet.zig` — frame parsing (used by `src/net.zig` and `src/ether.zig`)
- `src/net/ipv4.zig` — IP header parsing (used by DHCP snooping in `src/net.zig`)

## Files Modified

### `src/net.zig` — Gut to frame delivery only

Remove:
- `pub const arp`, `pub const tcp`, `pub const udp`, `pub const dns`, `pub const icmp`, `pub const netfs`
- `handleArp()`, `handleIpv4()`, `handleIcmp()`
- `sendIpPacket()`, `sendUdp()`, `sameSubnet()`
- `setIp()`, `setGateway()`, `setSubnetMask()`, `getGateway()`, `getSubnet()`
- `handleFrameExclusive()` — complex exclusive/shared mode logic
- `snoopDhcp()` — kernel no longer needs to know its own IP

Retain:
- `init()` — just read MAC from virtio-net, log it, set `initialized = true`
- `poll()` — poll frames from virtio-net, call `ether.deliverFrame()` for each
- `getMac()`, `getIp()` — needed by `sysinfo` (read from sysinfo, set by ctl write to net)
- `our_mac`, `our_ip` variables (sysinfo reports them)
- `isInitialized()`
- `printIp*()` helpers

The `poll()` function simplifies to:
```zig
pub fn poll() void {
    if (!initialized) return;
    var frames: usize = 0;
    while (frames < 64) : (frames += 1) {
        const frame = virtio_net.poll() orelse break;
        ether_mod.deliverFrame(frame);
    }
}
```

No more frame parsing, protocol dispatch, or exclusive mode handling.

### `src/process.zig`

Remove:
- `FdType.net` from the `FdType` enum
- `NetFdKind` enum (all 14 variants)
- `FdEntry` fields: `net_kind`, `net_conn`, `net_read_done`
- `Process.allocNetFd()` method
- `PendingOp` values: `net_read`, `net_connect`, `net_listen`, `dns_query`, `icmp_read`
- Resume handlers in `switchTo()` for `.net_read`, `.icmp_read`, `.net_connect`, `.net_listen`, `.dns_query`

### `src/syscall/fs.zig`

Remove:
- `/net/*` path interception in `sysOpen()` (the `hasNetMount` check and `netfs.netOpen` call)
- `FdType.net` handling in `sysWrite()` (netfs write dispatch)
- `FdType.net` handling in `sysRead()` (netfs read dispatch + TCP read waiter blocking)
- `FdType.net` handling in `sysClose()` (netfs close dispatch)
- `const hasNetMount = root.hasNetMount`
- All `@import("../net.zig")` references

### `src/syscall/root.zig`

Remove:
- `hasNetMount()` function
- `const fs = ...` net-related imports if unused after removal

### `src/syscall/ipc_handlers.zig`

Remove:
- Any `PendingOp.net_*` skip entries or special handling

### `src/main.zig`

Simplify `net.init()` — it now just reads MAC and sets initialized flag. The call stays
but does much less.

### `src/devfiles.zig`

Remove net-related pending_op references in `etherRead()` if any (ether reads are
separate from the kernel TCP stack and should remain).

## Implementation Steps

### 1. Delete kernel net stack files

```
rm src/net/tcp.zig src/net/udp.zig src/net/arp.zig
rm src/net/dns.zig src/net/icmp.zig src/net/netfs.zig
rm docs/TODO/002-net-bugs.md
```

### 2. Gut src/net.zig

Strip down to: init (MAC read), poll (frame delivery), getMac/getIp, printIp helpers.

### 3. Clean process.zig

Remove `FdType.net`, `NetFdKind`, `allocNetFd()`, net `FdEntry` fields, net `PendingOp`
values, and net resume handlers in `switchTo()`.

### 4. Clean syscall/fs.zig

Remove all `/net/*` interception code and `FdType.net` dispatch branches in
sysOpen/sysRead/sysWrite/sysClose.

### 5. Clean syscall/root.zig

Remove `hasNetMount()`.

### 6. Clean syscall/ipc_handlers.zig

Remove net PendingOp skip entries.

### 7. Build + test

Verify cross-arch build succeeds and all network tests pass via netd.

## Verification

- `zig build x86_64` / `zig build aarch64` / `zig build riscv64` — all compile
- `tests/run_iperf.py` — host iperf3 works through netd
- `tests/tcp_test.zig` — native TCP test works through netd
- Boot → `ping`, `curl` work
- `tests/run_container_iperf.py` — container networking works (via 1010)

## Impact

- Kernel binary shrinks by ~4000 lines of net stack code
- Eliminates dual-stack complexity (exclusive mode, DHCP snooping, etc.)
- All networking now consistently goes through netd IPC
- Frame delivery path (virtio-net → ether clients) is unchanged and simple
