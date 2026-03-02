# Phase 1010 — Socket Shim: Plan 9 /net/ File Operations via IPC

## Problem

`src/linux_socket.zig` calls the kernel TCP stack directly (`tcp.alloc()`, `tcp.connect()`,
`tcp.sendData()`, etc.). This bypasses the container's namespace-mounted netd server, so
container processes (e.g. iperf3) use the host's IP (10.0.2.15) instead of their container
IP (10.0.1.x). The kernel stack also duplicates the entire userspace netd implementation.

## Solution

Rewrite `linux_socket.zig` to translate BSD socket calls into Plan 9 `/net/tcp/*` file
operations. Each socket operation becomes a sequence of IPC open/read/write calls routed
through the process's namespace, which resolves `/net/` to the correct netd (host or
container).

## Design

### Socket Lifecycle → File Operations

Each BSD socket maps to a set of internal IPC file descriptors (not exposed to the Linux
fd table). The mapping follows the Plan 9 TCP protocol:

```
socket()    → allocate SocketMeta slot (no IPC yet)
connect()   → open /net/tcp/clone → read N → open /net/tcp/N/ctl →
              write "connect <ip>!<port>" → open /net/tcp/N/data
bind()      → stash port in SocketMeta
listen()    → open /net/tcp/clone → read N → open /net/tcp/N/ctl →
              write "announce <port>"
accept()    → open /net/tcp/N/listen → read (blocks) → on wake:
              parse child N → open /net/tcp/child/data
send()      → write to data fd
recv()      → read from data fd
close()     → close data fd, close ctl fd
poll()      → conservatively report POLLIN|POLLOUT, force app to try read/write
select()    → same conservative approach
```

### Multi-Step IPC State Machine

`connect()` requires 4-5 sequential IPC round-trips. Since IPC is blocking (rendezvous),
this uses a step-based state machine:

```
PendingOp.linux_sock_step  (new enum value)
```

Process fields for step tracking:
- `pending_fd`: the Linux socket fd being operated on
- `linux_stat_fd`: step counter (0=open clone, 1=read N, 2=open ctl, 3=write connect, 4=open data)
- `linux_stat_buf`: stash for intermediate results (e.g. connection number N)
- `ipc_recv_buf_ptr`: stash for user-provided addresses

On each IPC reply wake, `linux_socket.handleResume()` advances the step counter and
issues the next IPC operation, or completes the syscall.

### Internal IPC Fd Tracking

```zig
const SocketMeta = struct {
    in_use: bool = false,
    bound_port: u16 = 0,
    listening: bool = false,
    conn_num: u16 = 0,        // /net/tcp/N connection number
    ipc_clone_fd: u8 = 0,     // fd for /net/tcp/clone (transient)
    ipc_ctl_fd: u8 = 0,       // fd for /net/tcp/N/ctl
    ipc_data_fd: u8 = 0,      // fd for /net/tcp/N/data
    ipc_listen_fd: u8 = 0,    // fd for /net/tcp/N/listen (server sockets)
};
var socket_meta: [64]SocketMeta = [_]SocketMeta{.{}} ** 64;
```

These IPC fds are real process fds (allocated via `allocFd()`) but tracked separately
from the Linux fd table. The Linux fd number maps to a `SocketMeta` index, not directly
to an IPC channel.

### Poll/Select Handling

With the kernel stack gone, we can't query TCP state directly. Instead:

- Socket fds always report POLLIN|POLLOUT (optimistic)
- The app's subsequent `read()` or `write()` will discover the actual state
- This matches how many real-world poll implementations work on first call
- `POLLHUP` is reported when the data fd has been closed by the server

For blocking poll with timeout, the existing `poll_wait` mechanism (timer-based re-check)
still works — it just always reports ready.

### Nanosleep / Clock

`linuxNanosleep()` and `linuxClock*()` are unaffected — they don't use the net stack.

## Files Modified

| File | Change |
|------|--------|
| `src/linux_socket.zig` | Complete rewrite — Plan 9 file ops via IPC |
| `src/process.zig` | Add `PendingOp.linux_sock_step` |
| `src/syscall/ipc_handlers.zig` | Handle `.linux_sock_step` in resume path → dispatch to `linux_socket.handleResume` |

## Implementation Steps

### 1. Add PendingOp.linux_sock_step

In `src/process.zig`, add `linux_sock_step` to the `PendingOp` enum.

### 2. Add IPC Resume Hook

In `src/syscall/ipc_handlers.zig`, when a process wakes from IPC with
`pending_op == .linux_sock_step`, call `linux_socket.handleResume(proc)`.

### 3. Rewrite linux_socket.zig

Replace all direct kernel TCP calls with IPC file operations:

- `linuxSocket()`: allocate SocketMeta slot, return immediately
- `linuxConnect()`: start multi-step IPC (open clone → read N → open ctl → write connect → open data)
- `linuxBind()`: stash port
- `linuxListen()`: multi-step IPC (open clone → read N → open ctl → write announce)
- `linuxAccept()`: open /net/tcp/N/listen, block for connection
- `linuxSendto()`: write to data fd
- `linuxRecvfrom()`: read from data fd
- `linuxShutdown()`: close data fd
- `linuxPoll()`/`linuxSelect()`: report POLLIN|POLLOUT for all socket fds
- `handleResume()`: advance step counter, issue next IPC op or complete

### 4. Remove Kernel TCP Dependencies

Remove all imports of `net.zig` / `tcp` from `linux_socket.zig`. The only imports needed
are `process`, `ipc`, `namespace`, and `timer`.

## Verification

- `tests/run_container_iperf.py` — container iperf3 uses container IP (10.0.1.x)
- `tests/run_iperf.py` — host iperf3 still works through host netd
- Boot → `curl` from container works
- `tests/tcp_test.zig` — native Fornax TCP test (uses /net/ files directly, unaffected)

## Dependencies

- None (this phase is self-contained)
- Requires netd to be running (already started by init)

## Risk

- Multi-step IPC adds latency to `connect()` (5 round-trips vs 1 kernel call)
- Acceptable: connection setup is not the bottleneck for iperf3 throughput
- Poll/select optimistic reporting may cause extra read/write attempts
- Acceptable: this is how containers work on real Linux with epoll edge triggers too
