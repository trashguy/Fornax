/// TCP: Transmission Control Protocol (RFC 793).
///
/// Minimal TCP implementation with connection state machine, retransmission,
/// and ring buffers. Supports connect, listen, send, and receive.
///
/// SMP locking model:
///   alloc_lock (global) — protects conn_hash[], in_use flags,
///     next_ephemeral_port, seq_counter. Acquired for alloc/free/hash ops.
///   conn.lock (per-connection) — protects all connection fields (state,
///     buffers, waiters, sequence numbers). Acquired for send/recv/segment.
///
/// Lock ordering: conn.lock → alloc_lock (never reversed).
/// handlePacket: alloc_lock (lookup) → release → conn.lock (never nested).
const ipv4 = @import("ipv4.zig");
const klog = @import("../klog.zig");
const timer = @import("../timer.zig");
const process = @import("../process.zig");
const SpinLock = @import("../spinlock.zig").SpinLock;

const HEADER_SIZE = 20; // no options
pub const MAX_CONNECTIONS = 256;
const RX_BUF_SIZE = 16384;
const TX_BUF_SIZE = 4096;
const DEFAULT_MSS: u16 = 1460;
const DEFAULT_WINDOW: u16 = 16384;
const INITIAL_RTO: u32 = 18; // ~1 second at 18 Hz
const MAX_RETRIES: u8 = 8;
const TIME_WAIT_TICKS: u32 = 36; // ~2 seconds

// TCP flags
const FIN: u8 = 0x01;
const SYN: u8 = 0x02;
const RST: u8 = 0x04;
const PSH: u8 = 0x08;
const ACK: u8 = 0x10;

pub const TcpState = enum(u8) {
    closed,
    listen,
    syn_sent,
    syn_received,
    established,
    fin_wait_1,
    fin_wait_2,
    close_wait,
    last_ack,
    time_wait,
    closing,
};

const MAX_WAITERS = 4;

/// Hash table sentinel — 0xFF means end-of-chain. Valid indices are 0..254.
const HASH_EMPTY: u8 = 0xFF;
const HASH_BUCKETS = 256;

pub const Connection = struct {
    // Per-connection lock (hot field, first cache line)
    lock: SpinLock,
    in_use: bool,
    state: TcpState,
    hash_next: u8, // chaining for hash table (HASH_EMPTY = end)
    local_port: u16,
    remote_port: u16,
    local_ip: [4]u8,
    remote_ip: [4]u8,
    // Sequence numbers
    snd_una: u32, // oldest unacknowledged
    snd_nxt: u32, // next to send
    rcv_nxt: u32, // next expected from remote
    snd_wnd: u16, // remote window
    mss: u16,
    // Receive ring buffer
    rx_buf: [RX_BUF_SIZE]u8,
    rx_head: u16, // write position
    rx_count: u16, // bytes available
    // Transmit buffer (for retransmission)
    tx_buf: [TX_BUF_SIZE]u8,
    tx_len: u16, // bytes in tx_buf awaiting ACK
    // Retransmit timer
    retransmit_tick: u32,
    retransmit_count: u8,
    rto: u32,
    // Blocked process tracking (multi-slot for SMP/threads)
    read_waiters: [MAX_WAITERS]?u16,
    connect_waiters: [MAX_WAITERS]?u16,
    listen_waiters: [MAX_WAITERS]?u16,
    // Listener parent index (for connections spawned by accept)
    parent_idx: u8,
};

/// Connections array — must be in BSS to avoid bloating .data (~5.8 MB)
var connections: [MAX_CONNECTIONS]Connection linksection(".bss") = undefined;
var next_ephemeral_port: u16 = 49152;
var seq_counter: u32 = 1000;

/// Global alloc lock — protects conn_hash[], in_use flags,
/// next_ephemeral_port, seq_counter.
var alloc_lock: SpinLock = .{};

/// Hash table for O(1) established-connection demux (chained).
/// Listeners are NOT in the hash table (linear scan, few listeners).
var conn_hash: [HASH_BUCKETS]u8 = [_]u8{HASH_EMPTY} ** HASH_BUCKETS;

// Forward-declare the net module for sending
const net = @import("../net.zig");

const no_waiters = [_]?u16{null} ** MAX_WAITERS;

pub fn init() void {
    for (&connections) |*c| {
        resetConn(c);
    }
    for (&conn_hash) |*h| {
        h.* = HASH_EMPTY;
    }
}

/// Reset a connection slot to empty state. Preserves lock integrity.
fn resetConn(c: *Connection) void {
    c.lock = .{};
    c.in_use = false;
    c.state = .closed;
    c.hash_next = HASH_EMPTY;
    c.local_port = 0;
    c.remote_port = 0;
    c.local_ip = .{ 0, 0, 0, 0 };
    c.remote_ip = .{ 0, 0, 0, 0 };
    c.snd_una = 0;
    c.snd_nxt = 0;
    c.rcv_nxt = 0;
    c.snd_wnd = DEFAULT_WINDOW;
    c.mss = DEFAULT_MSS;
    // rx_buf/tx_buf left undefined (BSS)
    c.rx_head = 0;
    c.rx_count = 0;
    c.tx_len = 0;
    c.retransmit_tick = 0;
    c.retransmit_count = 0;
    c.rto = INITIAL_RTO;
    c.read_waiters = no_waiters;
    c.connect_waiters = no_waiters;
    c.listen_waiters = no_waiters;
    c.parent_idx = 0xFF;
}

// ── Hash table helpers ──────────────────────────────────────────────
// Caller must hold alloc_lock.

fn connHashFn(local_port: u16, remote_port: u16, remote_ip: [4]u8) u8 {
    // FNV-1a 32-bit on the 8-byte key
    var h: u32 = 2166136261;
    h ^= local_port;
    h *%= 16777619;
    h ^= remote_port;
    h *%= 16777619;
    h ^= @as(u32, remote_ip[0]) | @as(u32, remote_ip[1]) << 8 |
        @as(u32, remote_ip[2]) << 16 | @as(u32, remote_ip[3]) << 24;
    h *%= 16777619;
    return @truncate(h); // mod 256 via truncation
}

/// Prepend connection idx to its hash bucket chain. Caller holds alloc_lock.
fn hashInsert(idx: u8) void {
    const c = &connections[idx];
    const bucket = connHashFn(c.local_port, c.remote_port, c.remote_ip);
    c.hash_next = conn_hash[bucket];
    conn_hash[bucket] = idx;
}

/// Remove connection idx from its hash bucket chain. Caller holds alloc_lock.
fn hashRemove(idx: u8) void {
    const c = &connections[idx];
    const bucket = connHashFn(c.local_port, c.remote_port, c.remote_ip);
    if (conn_hash[bucket] == idx) {
        conn_hash[bucket] = c.hash_next;
    } else {
        var prev = conn_hash[bucket];
        while (prev != HASH_EMPTY) {
            if (connections[prev].hash_next == idx) {
                connections[prev].hash_next = c.hash_next;
                break;
            }
            prev = connections[prev].hash_next;
        }
    }
    c.hash_next = HASH_EMPTY;
}

/// Look up established connection by 4-tuple. Caller holds alloc_lock.
/// Returns connection index or null.
fn hashLookup(local_port: u16, remote_port: u16, remote_ip: [4]u8) ?u8 {
    const bucket = connHashFn(local_port, remote_port, remote_ip);
    var idx = conn_hash[bucket];
    while (idx != HASH_EMPTY) {
        const c = &connections[idx];
        if (c.in_use and c.local_port == local_port and
            c.remote_port == remote_port and
            ipv4.ipEqual(c.remote_ip, remote_ip))
        {
            return idx;
        }
        idx = c.hash_next;
    }
    return null;
}

// ── Public API ──────────────────────────────────────────────────────

/// Allocate a new TCP connection slot.
pub fn alloc() ?u8 {
    alloc_lock.lock();
    defer alloc_lock.unlock();
    return allocLocked();
}

/// Internal alloc — caller must hold alloc_lock.
fn allocLocked() ?u8 {
    for (&connections, 0..) |*c, i| {
        if (!c.in_use) {
            resetConn(c);
            c.in_use = true;
            c.local_port = allocEphemeralPort();
            c.local_ip = net.getIp();
            return @intCast(i);
        }
    }
    return null;
}

/// Get connection state for status queries.
pub fn getState(idx: u8) ?TcpState {
    if (idx >= MAX_CONNECTIONS) return null;
    const c = &connections[idx];
    c.lock.lock();
    defer c.lock.unlock();
    if (!c.in_use) return null;
    return c.state;
}

/// Get connection's local port and IP.
pub fn getLocal(idx: u8) ?struct { ip: [4]u8, port: u16 } {
    if (idx >= MAX_CONNECTIONS) return null;
    const c = &connections[idx];
    c.lock.lock();
    defer c.lock.unlock();
    if (!c.in_use) return null;
    return .{ .ip = c.local_ip, .port = c.local_port };
}

/// Get connection's remote port and IP.
pub fn getRemote(idx: u8) ?struct { ip: [4]u8, port: u16 } {
    if (idx >= MAX_CONNECTIONS) return null;
    const c = &connections[idx];
    c.lock.lock();
    defer c.lock.unlock();
    if (!c.in_use) return null;
    return .{ .ip = c.remote_ip, .port = c.remote_port };
}

/// Initiate a TCP connection (active open).
/// Lock order: conn.lock → alloc_lock (for hash insert).
pub fn connect(idx: u8, ip: [4]u8, port: u16) bool {
    if (idx >= MAX_CONNECTIONS) return false;
    const c = &connections[idx];
    c.lock.lock();
    defer c.lock.unlock();
    if (!c.in_use or c.state != .closed) return false;

    c.remote_ip = ip;
    c.remote_port = port;
    c.snd_una = nextSeqLocked();
    c.snd_nxt = c.snd_una;

    // Send SYN
    sendSyn(c);
    c.snd_nxt = c.snd_una +% 1; // SYN consumes one sequence number
    c.state = .syn_sent;
    c.retransmit_tick = timer.getTicks();
    c.retransmit_count = 0;

    // Insert into hash table
    alloc_lock.lock();
    hashInsert(idx);
    alloc_lock.unlock();

    klog.debug("tcp: SYN sent to ");
    net.printIpDebug(ip);
    klog.debug(":");
    klog.debugDec(port);
    klog.debug("\n");
    return true;
}

/// Set up a listening socket (passive open).
/// Listeners are NOT in the hash table.
pub fn announce(idx: u8, port: u16) bool {
    if (idx >= MAX_CONNECTIONS) return false;
    const c = &connections[idx];
    c.lock.lock();
    defer c.lock.unlock();
    if (!c.in_use or c.state != .closed) return false;

    c.local_port = port;
    c.state = .listen;

    klog.debug("tcp: listening on port ");
    klog.debugDec(port);
    klog.debug("\n");
    return true;
}

/// Queue data for transmission on an established connection.
pub fn sendData(idx: u8, data: []const u8) u16 {
    if (idx >= MAX_CONNECTIONS) return 0;
    const c = &connections[idx];
    c.lock.lock();
    defer c.lock.unlock();
    if (c.state != .established and c.state != .close_wait) return 0;

    const available = TX_BUF_SIZE - c.tx_len;
    const to_send: u16 = @intCast(@min(data.len, available));
    if (to_send == 0) return 0;

    @memcpy(c.tx_buf[c.tx_len..][0..to_send], data[0..to_send]);
    c.tx_len += to_send;

    // Send segment immediately
    sendDataSegment(c);

    return to_send;
}

/// Read received data from the connection's rx ring buffer.
pub fn recvData(idx: u8, buf: []u8) u16 {
    if (idx >= MAX_CONNECTIONS) return 0;
    const c = &connections[idx];
    c.lock.lock();
    defer c.lock.unlock();
    if (c.rx_count == 0) return 0;

    const old_count = c.rx_count;
    const to_copy: u16 = @intCast(@min(buf.len, c.rx_count));
    // Read from ring buffer — head points to the write position,
    // read position = head - count (wrapped)
    const read_pos = (c.rx_head -% c.rx_count) % RX_BUF_SIZE;

    var i: u16 = 0;
    while (i < to_copy) : (i += 1) {
        buf[i] = c.rx_buf[(read_pos + i) % RX_BUF_SIZE];
    }
    c.rx_count -= to_copy;

    // Send window update ACK if buffer was previously too full for an MSS-sized
    // segment and now has room. This unblocks the remote when it stopped sending
    // due to a small/zero advertised window.
    const was_full = old_count > RX_BUF_SIZE / 2;
    const now_has_room = c.rx_count <= RX_BUF_SIZE / 2;
    if (c.state == .established and was_full and now_has_room) {
        sendAck(c);
    }
    return to_copy;
}

/// Check if connection has data available to read.
pub fn hasData(idx: u8) bool {
    if (idx >= MAX_CONNECTIONS) return false;
    const c = &connections[idx];
    c.lock.lock();
    defer c.lock.unlock();
    return connections[idx].rx_count > 0;
}

/// Check if connection is in a state where no more data will arrive (EOF).
pub fn isEof(idx: u8) bool {
    if (idx >= MAX_CONNECTIONS) return true;
    const c = &connections[idx];
    c.lock.lock();
    defer c.lock.unlock();
    return c.state == .close_wait or c.state == .closing or
        c.state == .last_ack or c.state == .time_wait or c.state == .closed;
}

/// Initiate a graceful close (send FIN).
/// Lock order: conn.lock → alloc_lock (for freeConn).
pub fn startClose(idx: u8) void {
    if (idx >= MAX_CONNECTIONS) return;
    const c = &connections[idx];
    c.lock.lock();

    switch (c.state) {
        .established => {
            sendFin(c);
            c.state = .fin_wait_1;
            c.lock.unlock();
        },
        .close_wait => {
            sendFin(c);
            c.state = .last_ack;
            c.lock.unlock();
        },
        .syn_sent, .syn_received => {
            // Abort — wake blocked waiters before freeing
            wakeAllWaiters(&c.connect_waiters, true);
            wakeAllWaiters(&c.read_waiters, true);
            sendRst(c);
            freeConn(c, idx); // releases conn.lock
        },
        .listen => {
            // Wake blocked accept waiters before freeing
            wakeAllWaiters(&c.listen_waiters, true);
            freeConn(c, idx); // releases conn.lock
        },
        else => {
            c.lock.unlock();
        },
    }
}

/// Register a waiter for read (blocks until data arrives).
pub fn setReadWaiter(idx: u8, pid: u16) void {
    if (idx >= MAX_CONNECTIONS) return;
    const c = &connections[idx];
    c.lock.lock();
    defer c.lock.unlock();
    addWaiter(&c.read_waiters, pid);
}

/// Register a waiter for connect completion.
pub fn setConnectWaiter(idx: u8, pid: u16) void {
    if (idx >= MAX_CONNECTIONS) return;
    const c = &connections[idx];
    c.lock.lock();
    defer c.lock.unlock();
    addWaiter(&c.connect_waiters, pid);
}

/// Register a waiter for listen/accept.
pub fn setListenWaiter(idx: u8, pid: u16) void {
    if (idx >= MAX_CONNECTIONS) return;
    const c = &connections[idx];
    c.lock.lock();
    defer c.lock.unlock();
    addWaiter(&c.listen_waiters, pid);
}

/// Process an incoming TCP segment.
/// Lock order: alloc_lock (lookup) → release → conn.lock (process).
pub fn handlePacket(payload: []const u8, ip_hdr: ipv4.Header) void {
    if (payload.len < HEADER_SIZE) return;

    klog.debug("tcp: rx from ");
    net.printIpDebug(ip_hdr.src);
    klog.debug("\n");

    const src_port = be16(payload[0..2]);
    const dst_port = be16(payload[2..4]);
    const seq_num = be32(payload, 4);
    const ack_num = be32(payload, 8);

    // Data offset (in 32-bit words) is in the high 4 bits of byte 12
    const data_offset_raw = payload[12] >> 4;
    const data_offset: usize = @as(usize, data_offset_raw) * 4;
    if (data_offset < HEADER_SIZE or data_offset > payload.len) return;

    const flags = payload[13];
    const window = be16(payload[14..16]);

    // Verify TCP checksum (no locks needed — pure computation)
    if (!verifyChecksum(payload, ip_hdr)) {
        klog.debug("tcp: bad checksum\n");
        return;
    }

    const data = payload[data_offset..];

    // Step 1: Hash lookup for established/in-progress connections
    alloc_lock.lock();
    const matched_idx = hashLookup(dst_port, src_port, ip_hdr.src);
    alloc_lock.unlock();

    if (matched_idx) |idx| {
        const c = &connections[idx];
        c.lock.lock();
        // Verify connection still matches (race with free/reuse)
        if (c.in_use and c.local_port == dst_port and
            c.remote_port == src_port and
            ipv4.ipEqual(c.remote_ip, ip_hdr.src))
        {
            handleSegment(c, idx, seq_num, ack_num, flags, window, data, ip_hdr);
            // handleSegment may call freeConn which releases lock
            if (c.lock.isLocked()) c.lock.unlock();
        } else {
            c.lock.unlock();
        }
        return;
    }

    // Step 2: Linear scan for listeners (rare — SYN only)
    alloc_lock.lock();
    var listener_idx: ?u8 = null;
    for (&connections, 0..) |*c, i| {
        if (c.in_use and c.state == .listen and c.local_port == dst_port) {
            listener_idx = @intCast(i);
            break;
        }
    }
    alloc_lock.unlock();

    if (listener_idx) |lidx| {
        const listener = &connections[lidx];
        listener.lock.lock();
        // Verify still a listener
        if (listener.in_use and listener.state == .listen and
            listener.local_port == dst_port)
        {
            handleListenSegment(listener, lidx, seq_num, flags, ip_hdr, src_port);
        }
        listener.lock.unlock();
        return;
    }

    // No matching connection — send RST if it's not already a RST
    if (flags & RST == 0) {
        sendRstReply(ip_hdr.src, src_port, dst_port, seq_num, ack_num, flags, @intCast(data.len));
    }
}

/// Timer tick — check retransmission timers and TIME_WAIT expiry.
/// Acquires per-connection locks individually.
pub fn tick(now: u32) void {
    for (&connections, 0..) |*c, i| {
        // Quick non-locked check to skip unused slots
        if (!@atomicLoad(bool, &c.in_use, .acquire)) continue;

        c.lock.lock();
        if (!c.in_use) {
            c.lock.unlock();
            continue;
        }

        switch (c.state) {
            .syn_sent => {
                if (now -% c.retransmit_tick >= c.rto) {
                    if (c.retransmit_count >= MAX_RETRIES) {
                        klog.debug("tcp: connect timeout\n");
                        wakeAllWaiters(&c.connect_waiters, true);
                        freeConn(c, @intCast(i)); // releases lock
                        continue;
                    } else {
                        // Retransmit SYN
                        klog.debug("tcp: retransmit SYN #");
                        klog.debugDec(c.retransmit_count + 1);
                        klog.debug("\n");
                        sendSyn(c);
                        c.retransmit_count += 1;
                        c.retransmit_tick = now;
                        c.rto *= 2; // exponential backoff
                    }
                }
            },
            .established, .close_wait => {
                // Retransmit data if unacked
                if (c.tx_len > 0 and seqDiff(c.snd_nxt, c.snd_una) > 0) {
                    if (now -% c.retransmit_tick >= c.rto) {
                        if (c.retransmit_count >= MAX_RETRIES) {
                            klog.debug("tcp: retransmit timeout\n");
                            wakeAllWaiters(&c.read_waiters, true);
                            sendRst(c);
                            freeConn(c, @intCast(i)); // releases lock
                            continue;
                        } else {
                            sendDataSegment(c);
                            c.retransmit_count += 1;
                            c.retransmit_tick = now;
                        }
                    }
                }
            },
            .fin_wait_1, .last_ack, .closing => {
                if (now -% c.retransmit_tick >= c.rto) {
                    if (c.retransmit_count >= MAX_RETRIES) {
                        freeConn(c, @intCast(i)); // releases lock
                        continue;
                    } else {
                        sendFin(c);
                        c.retransmit_count += 1;
                        c.retransmit_tick = now;
                    }
                }
            },
            .time_wait => {
                if (now -% c.retransmit_tick >= TIME_WAIT_TICKS) {
                    freeConn(c, @intCast(i)); // releases lock
                    continue;
                }
            },
            else => {},
        }
        c.lock.unlock();
    }
}

// ── Internal helpers ────────────────────────────────────────────────
// handleSegment and handleEstablished: caller holds conn.lock.

fn handleSegment(c: *Connection, idx: u8, seq: u32, ack: u32, flags: u8, window: u16, data: []const u8, ip_hdr: ipv4.Header) void {
    _ = ip_hdr;

    // RST handling — always process
    if (flags & RST != 0) {
        klog.debug("tcp: received RST\n");
        wakeAllWaiters(&c.connect_waiters, true);
        wakeAllWaiters(&c.read_waiters, true);
        wakeAllWaiters(&c.listen_waiters, true);
        freeConn(c, idx); // releases conn.lock
        return;
    }

    switch (c.state) {
        .syn_sent => {
            // Expecting SYN+ACK
            if (flags & SYN != 0 and flags & ACK != 0) {
                if (ack == c.snd_nxt) {
                    c.rcv_nxt = seq +% 1;
                    c.snd_una = ack;
                    c.snd_wnd = window;
                    c.state = .established;
                    c.retransmit_count = 0;
                    c.rto = INITIAL_RTO;
                    c.tx_len = 0;
                    sendAck(c);
                    klog.debug("tcp: connected\n");
                    wakeAllWaiters(&c.connect_waiters, false);
                }
            }
        },
        .syn_received => {
            if (flags & ACK != 0 and ack == c.snd_nxt) {
                c.snd_una = ack;
                c.snd_wnd = window;
                c.state = .established;
                c.retransmit_count = 0;
                c.rto = INITIAL_RTO;
                klog.debug("tcp: accept complete\n");
                // Wake the listener's waiter — must lock parent briefly
                if (c.parent_idx != 0xFF and c.parent_idx < MAX_CONNECTIONS) {
                    const parent = &connections[c.parent_idx];
                    parent.lock.lock();
                    wakeAllWaiters(&parent.listen_waiters, false);
                    parent.lock.unlock();
                }
            }
        },
        .established => {
            handleEstablished(c, seq, ack, flags, window, data);
        },
        .fin_wait_1 => {
            // Process ACK of our FIN
            if (flags & ACK != 0) {
                if (ack == c.snd_nxt) {
                    c.snd_una = ack;
                }
            }
            if (flags & FIN != 0) {
                c.rcv_nxt = seq +% 1;
                sendAck(c);
                if (c.snd_una == c.snd_nxt) {
                    // Our FIN was acked — go to TIME_WAIT
                    c.state = .time_wait;
                    c.retransmit_tick = timer.getTicks();
                } else {
                    c.state = .closing;
                }
            } else if (c.snd_una == c.snd_nxt) {
                c.state = .fin_wait_2;
            }
        },
        .fin_wait_2 => {
            if (flags & FIN != 0) {
                c.rcv_nxt = seq +% 1;
                sendAck(c);
                c.state = .time_wait;
                c.retransmit_tick = timer.getTicks();
            }
        },
        .closing => {
            if (flags & ACK != 0 and ack == c.snd_nxt) {
                c.state = .time_wait;
                c.retransmit_tick = timer.getTicks();
            }
        },
        .last_ack => {
            if (flags & ACK != 0 and ack == c.snd_nxt) {
                freeConn(c, idx); // releases conn.lock
                return;
            }
        },
        .close_wait => {
            // We can still receive ACKs for data we sent
            if (flags & ACK != 0) {
                processAck(c, ack, window);
            }
        },
        else => {},
    }
}

fn handleEstablished(c: *Connection, seq: u32, ack: u32, flags: u8, window: u16, data: []const u8) void {
    // Process ACK
    if (flags & ACK != 0) {
        processAck(c, ack, window);
    }

    // Process incoming data
    if (data.len > 0) {
        if (seq == c.rcv_nxt) {
            // In-order data — buffer it
            const space = RX_BUF_SIZE - c.rx_count;
            const to_buf: u16 = @intCast(@min(data.len, space));
            var i: u16 = 0;
            while (i < to_buf) : (i += 1) {
                c.rx_buf[c.rx_head] = data[i];
                c.rx_head = (c.rx_head + 1) % RX_BUF_SIZE;
            }
            c.rx_count += to_buf;
            c.rcv_nxt +%= @as(u32, to_buf);

            if (to_buf < data.len) {
                klog.debug("tcp: partial buf ");
                klog.debugDec(to_buf);
                klog.debug("/");
                klog.debugDec(@as(u16, @intCast(data.len)));
                klog.debug(" rx_count=");
                klog.debugDec(c.rx_count);
                klog.debug("\n");
            }

            // Wake read waiters
            wakeAllWaiters(&c.read_waiters, false);
        } else {
            klog.debug("tcp: OOO seq=");
            klog.debugHex(seq);
            klog.debug(" exp=");
            klog.debugHex(c.rcv_nxt);
            klog.debug("\n");
        }
        // Send ACK (even for out-of-order to trigger fast retransmit on remote)
        sendAck(c);
    } else if (flags & FIN == 0) {
        // ACK-only (no data, no FIN) — print for debug
        klog.debug("tcp: ack-only\n");
    }

    // Process FIN
    if (flags & FIN != 0) {
        // Only advance rcv_nxt if this FIN's seq matches what we expect
        if (seq == c.rcv_nxt or (data.len > 0 and seq +% @as(u32, @intCast(data.len)) == c.rcv_nxt)) {
            c.rcv_nxt +%= 1; // FIN consumes one sequence number
        }
        sendAck(c);
        c.state = .close_wait;
        // Wake reader with EOF
        wakeAllWaiters(&c.read_waiters, false);
        klog.debug("tcp: remote closed (FIN)\n");
    }
}

fn processAck(c: *Connection, ack: u32, window: u16) void {
    c.snd_wnd = window;
    // Check if ACK advances snd_una
    if (seqDiff(ack, c.snd_una) > 0 and seqDiff(ack, c.snd_nxt) <= 0) {
        const acked = ack -% c.snd_una;
        c.snd_una = ack;
        // Remove acked data from tx buffer
        if (acked <= c.tx_len) {
            const remaining = c.tx_len - @as(u16, @intCast(acked));
            if (remaining > 0) {
                // Shift remaining data to front
                var i: u16 = 0;
                while (i < remaining) : (i += 1) {
                    c.tx_buf[i] = c.tx_buf[@as(u16, @intCast(acked)) + i];
                }
            }
            c.tx_len = remaining;
        } else {
            c.tx_len = 0;
        }
        // Reset retransmit on progress
        c.retransmit_count = 0;
        c.rto = INITIAL_RTO;
        c.retransmit_tick = timer.getTicks();
    }
}

/// Handle SYN on a listener. Caller holds listener.lock.
/// Lock order: listener.lock already held → alloc_lock (for allocLocked + hashInsert).
fn handleListenSegment(listener: *Connection, listener_idx: u8, seq: u32, flags: u8, ip_hdr: ipv4.Header, src_port: u16) void {
    if (flags & SYN == 0) return; // Only SYN expected on listener
    if (flags & ACK != 0) return; // SYN must not have ACK
    if (flags & RST != 0) return;

    // Allocate a child connection
    alloc_lock.lock();
    const child_idx = allocLocked() orelse {
        alloc_lock.unlock();
        klog.debug("tcp: listen: no free connections\n");
        return;
    };
    const child = &connections[child_idx];
    child.local_port = listener.local_port;
    child.local_ip = listener.local_ip;
    child.remote_ip = ip_hdr.src;
    child.remote_port = src_port;
    child.rcv_nxt = seq +% 1;
    child.snd_una = nextSeqLocked();
    child.snd_nxt = child.snd_una +% 1;
    child.state = .syn_received;
    child.parent_idx = listener_idx;
    child.retransmit_tick = timer.getTicks();
    // Insert child into hash table
    hashInsert(child_idx);
    alloc_lock.unlock();

    // Send SYN+ACK (no lock needed on child — it's not visible to other
    // cores yet since we just allocated it and it's in syn_received state)
    sendFlags(child, SYN | ACK, child.snd_una);

    klog.debug("tcp: SYN+ACK sent to ");
    net.printIpDebug(ip_hdr.src);
    klog.debug(":");
    klog.debugDec(src_port);
    klog.debug(" (child conn ");
    klog.debugDec(child_idx);
    klog.debug(")\n");
}

// ── Segment building ────────────────────────────────────────────────

fn sendSyn(c: *Connection) void {
    sendFlags(c, SYN, c.snd_una);
}

fn sendAck(c: *Connection) void {
    sendFlags(c, ACK, c.snd_nxt);
}

fn sendFin(c: *Connection) void {
    sendFlags(c, FIN | ACK, c.snd_nxt);
    c.snd_nxt = c.snd_nxt +% 1; // FIN consumes a sequence number
    c.retransmit_tick = timer.getTicks();
    c.retransmit_count = 0;
}

fn sendRst(c: *Connection) void {
    sendFlags(c, RST | ACK, c.snd_nxt);
}

fn sendFlags(c: *Connection, flags: u8, seq: u32) void {
    var tcp_buf: [HEADER_SIZE]u8 = undefined;
    const window = RX_BUF_SIZE - c.rx_count;
    buildHeader(&tcp_buf, c.local_port, c.remote_port, seq, c.rcv_nxt, flags, window, 0);

    // Compute checksum
    const cksum = tcpChecksum(c.local_ip, c.remote_ip, &tcp_buf);
    writeBe16(&tcp_buf, 16, cksum);

    sendTcpPacket(c.remote_ip, &tcp_buf);
}

fn sendDataSegment(c: *Connection) void {
    if (c.tx_len == 0) return;

    const send_len: u16 = @intCast(@min(c.tx_len, c.mss));
    var tcp_buf: [HEADER_SIZE + TX_BUF_SIZE]u8 = undefined;
    const total_len = HEADER_SIZE + send_len;

    const window = RX_BUF_SIZE - c.rx_count;
    buildHeader(tcp_buf[0..HEADER_SIZE], c.local_port, c.remote_port, c.snd_una, c.rcv_nxt, ACK | PSH, window, 0);

    // Copy data
    @memcpy(tcp_buf[HEADER_SIZE..][0..send_len], c.tx_buf[0..send_len]);

    // Compute checksum over header + data
    const cksum = tcpChecksum(c.local_ip, c.remote_ip, tcp_buf[0..total_len]);
    writeBe16(&tcp_buf, 16, cksum);

    c.snd_nxt = c.snd_una +% @as(u32, send_len);
    c.retransmit_tick = timer.getTicks();

    sendTcpPacket(c.remote_ip, tcp_buf[0..total_len]);
}

fn sendRstReply(dst_ip: [4]u8, dst_port: u16, src_port: u16, seq: u32, ack: u32, in_flags: u8, data_len: u16) void {
    var tcp_buf: [HEADER_SIZE]u8 = undefined;

    if (in_flags & ACK != 0) {
        // Use their ACK as our SEQ, no ACK from us
        buildHeader(&tcp_buf, src_port, dst_port, ack, 0, RST, 0, 0);
    } else {
        // ACK their data
        const response_ack = seq +% @as(u32, data_len) +% if (in_flags & SYN != 0) @as(u32, 1) else @as(u32, 0);
        buildHeader(&tcp_buf, src_port, dst_port, 0, response_ack, RST | ACK, 0, 0);
    }

    const our_ip = net.getIp();
    const cksum = tcpChecksum(our_ip, dst_ip, &tcp_buf);
    writeBe16(&tcp_buf, 16, cksum);

    sendTcpPacket(dst_ip, &tcp_buf);
}

fn buildHeader(buf: *[HEADER_SIZE]u8, src_port: u16, dst_port: u16, seq: u32, ack: u32, flags: u8, window: u16, urgent: u16) void {
    writeBe16(buf, 0, src_port);
    writeBe16(buf, 2, dst_port);
    writeBe32(buf, 4, seq);
    writeBe32(buf, 8, ack);
    buf[12] = 0x50; // data offset = 5 (20 bytes), no options
    buf[13] = flags;
    writeBe16(buf, 14, window);
    writeBe16(buf, 16, 0); // checksum placeholder
    writeBe16(buf, 18, urgent);
}

fn tcpChecksum(src_ip: [4]u8, dst_ip: [4]u8, tcp_segment: []const u8) u16 {
    // Pseudo-header: src_ip(4) + dst_ip(4) + zero(1) + proto(1) + tcp_len(2) = 12 bytes
    var pseudo: [12]u8 = undefined;
    @memcpy(pseudo[0..4], &src_ip);
    @memcpy(pseudo[4..8], &dst_ip);
    pseudo[8] = 0;
    pseudo[9] = ipv4.PROTO_TCP;
    const tcp_len: u16 = @intCast(tcp_segment.len);
    writeBe16(&pseudo, 10, tcp_len);

    // Sum pseudo-header
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < pseudo.len) : (i += 2) {
        sum += @as(u32, pseudo[i]) << 8 | pseudo[i + 1];
    }

    // Sum TCP segment
    i = 0;
    while (i + 1 < tcp_segment.len) : (i += 2) {
        sum += @as(u32, tcp_segment[i]) << 8 | tcp_segment[i + 1];
    }
    if (i < tcp_segment.len) {
        sum += @as(u32, tcp_segment[i]) << 8;
    }

    // Fold carry
    while (sum >> 16 != 0) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    return @truncate(~sum);
}

fn verifyChecksum(tcp_segment: []const u8, ip_hdr: ipv4.Header) bool {
    return tcpChecksum(ip_hdr.src, ip_hdr.dst, tcp_segment) == 0;
}

fn sendTcpPacket(dst_ip: [4]u8, tcp_segment: []const u8) void {
    var ip_buf: [1600]u8 = undefined;
    const our_ip = net.getIp();
    const ip_len = ipv4.build(&ip_buf, our_ip, dst_ip, ipv4.PROTO_TCP, tcp_segment) orelse return;
    net.sendIpPacket(dst_ip, ip_buf[0..ip_len]);
}

/// Free a connection. Caller holds conn.lock. This function releases it.
/// Lock order: conn.lock (already held) → alloc_lock (hash remove + mark free).
fn freeConn(c: *Connection, idx: u8) void {
    // Remove from hash table and mark free under alloc_lock
    alloc_lock.lock();
    hashRemove(idx);
    c.in_use = false;
    c.state = .closed;
    alloc_lock.unlock();

    // Reset remaining fields (safe — no one else can see this slot now)
    c.hash_next = HASH_EMPTY;
    c.local_port = 0;
    c.remote_port = 0;
    c.local_ip = .{ 0, 0, 0, 0 };
    c.remote_ip = .{ 0, 0, 0, 0 };
    c.snd_una = 0;
    c.snd_nxt = 0;
    c.rcv_nxt = 0;
    c.snd_wnd = DEFAULT_WINDOW;
    c.mss = DEFAULT_MSS;
    c.rx_head = 0;
    c.rx_count = 0;
    c.tx_len = 0;
    c.retransmit_tick = 0;
    c.retransmit_count = 0;
    c.rto = INITIAL_RTO;
    c.read_waiters = no_waiters;
    c.connect_waiters = no_waiters;
    c.listen_waiters = no_waiters;
    c.parent_idx = 0xFF;

    // Release conn.lock last
    c.lock.unlock();
}

// ── Waiter helpers ──────────────────────────────────────────────────

/// Add a PID to a waiter array. Overwrites oldest slot if full.
fn addWaiter(waiters: *[MAX_WAITERS]?u16, pid: u16) void {
    for (waiters) |*w| {
        if (w.* == null) {
            w.* = pid;
            return;
        }
    }
    // Full — overwrite first slot (shouldn't happen in practice)
    waiters[0] = pid;
}

/// Wake all waiters in the array and clear it.
fn wakeAllWaiters(waiters: *[MAX_WAITERS]?u16, is_error: bool) void {
    for (waiters) |*w| {
        if (w.*) |pid| {
            w.* = null;
            if (process.getByPid(pid)) |proc| {
                if (proc.state == .blocked) {
                    if (is_error) {
                        proc.syscall_ret = 0xFFFF_FFFF_FFFF_FFF2; // -ECONNRESET equivalent
                    }
                    process.markReady(proc);
                }
            }
        }
    }
}

// ── Sequence number helpers ─────────────────────────────────────────

fn seqDiff(a: u32, b: u32) i32 {
    return @as(i32, @bitCast(a -% b));
}

/// Generate next ISN. Caller must hold alloc_lock.
fn nextSeqLocked() u32 {
    seq_counter +%= 64000; // crude ISN generation
    return seq_counter;
}

fn allocEphemeralPort() u16 {
    const port = next_ephemeral_port;
    next_ephemeral_port +%= 1;
    if (next_ephemeral_port < 49152) next_ephemeral_port = 49152;
    return port;
}

// ── Byte order helpers ──────────────────────────────────────────────

fn be16(bytes: *const [2]u8) u16 {
    return @as(u16, bytes[0]) << 8 | bytes[1];
}

fn be32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) << 24 |
        @as(u32, bytes[offset + 1]) << 16 |
        @as(u32, bytes[offset + 2]) << 8 |
        bytes[offset + 3];
}

fn writeBe16(buf: []u8, offset: usize, val: u16) void {
    buf[offset] = @truncate(val >> 8);
    buf[offset + 1] = @truncate(val);
}

fn writeBe32(buf: []u8, offset: usize, val: u32) void {
    buf[offset] = @truncate(val >> 24);
    buf[offset + 1] = @truncate(val >> 16);
    buf[offset + 2] = @truncate(val >> 8);
    buf[offset + 3] = @truncate(val);
}
