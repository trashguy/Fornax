/// TCP: Transmission Control Protocol (userspace, struct-based).
///
/// Each TcpStack instance owns its connection pool, hash table, and state.
/// No global state — suitable for per-realm netd instances.
///
/// Caller provides:
///   - sendFn: callback to send an IP packet (builds and transmits)
///   - getIpFn: callback to get our current IP address
///   - getTicksFn: callback to get current tick count (for retransmission)
///   - allocBufFn/freeBufFn: callbacks for dynamic buffer allocation
const ipv4 = @import("ipv4.zig");

/// Lightweight spinlock for per-connection and allocator locking.
pub const TcpLock = struct {
    state: u32 align(4) = 0,

    pub fn lock(self: *TcpLock) void {
        while (@cmpxchgWeak(u32, &self.state, 0, 1, .acquire, .monotonic) != null) {
            // spin
        }
    }

    pub fn unlock(self: *TcpLock) void {
        @atomicStore(u32, &self.state, 0, .release);
    }
};

pub const HEADER_SIZE = 20;
pub const MAX_CONNECTIONS: u16 = 4096;
pub const RX_BUF_SIZE: u32 = 131072;
pub const TX_BUF_SIZE: u32 = 131072;
pub const DEFAULT_MSS: u16 = 1460;
pub const DEFAULT_WINDOW: u16 = 65535;
pub const INITIAL_RTO: u32 = 20;
pub const MAX_RETRIES: u8 = 8;
pub const TIME_WAIT_TICKS: u32 = 6000;

// TCP flags
pub const FIN: u8 = 0x01;
pub const SYN: u8 = 0x02;
pub const RST: u8 = 0x04;
pub const PSH: u8 = 0x08;
pub const ACK: u8 = 0x10;

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
const HASH_EMPTY: u16 = 0xFFFF;
const HASH_BUCKETS = 4096;

/// Waiter callback: called when a connection event occurs.
/// The netd server maps these to IPC replies.
pub const WaiterCallback = *const fn (conn_idx: u16, event: WaiterEvent) void;
pub const WaiterEvent = enum { data_ready, connect_done, accept_ready, error_reset, eof };

/// Callback to allocate a buffer of `len` bytes. Returns null on failure.
pub const AllocBufFn = *const fn (len: u32) ?[*]u8;
/// Callback to free a buffer previously allocated by AllocBufFn.
pub const FreeBufFn = *const fn (ptr: [*]u8, len: u32) void;

pub const Connection = struct {
    lock: TcpLock, // per-connection lock (hot field, first cache line)
    in_use: bool,
    state: TcpState,
    hash_next: u16,
    local_port: u16,
    remote_port: u16,
    local_ip: [4]u8,
    remote_ip: [4]u8,
    snd_una: u32,
    snd_nxt: u32,
    rcv_nxt: u32,
    snd_wnd: u32,
    mss: u16,
    rx_buf: ?[*]u8,
    rx_head: u32,
    rx_count: u32,
    tx_buf: ?[*]u8,
    tx_len: u32,
    retransmit_tick: u32,
    retransmit_count: u8,
    rto: u32,
    parent_idx: u16,
    cwnd: u32,
    ssthresh: u32,
    ack_pending: u8,
    snd_wnd_scale: u8, // peer's window scale factor (from SYN-ACK option)
    buf_size: u32, // RX buffer capacity (power of 2)
    tx_buf_size: u32, // TX buffer capacity
    buf_mask: u32, // buf_size - 1 (bitmask for fast modulo)
};

/// Callback to send an IP-encapsulated TCP segment.
pub const SendFn = *const fn (dst_ip: [4]u8, tcp_segment: []const u8) bool;
/// Callback to get our IP address.
pub const GetIpFn = *const fn () [4]u8;
/// Callback to get current tick count.
pub const GetTicksFn = *const fn () u32;

/// Frame header sizes for in-place TX path
pub const FRAME_HDR = 54; // 14 ETH + 20 IP + 20 TCP
pub const MAX_FRAME_LEN = FRAME_HDR + DEFAULT_MSS; // 1514

/// Sends a pre-built frame. TCP header at buf[34..54], payload at buf[54..].
/// Callee fills ETH (0..14) and IP (14..34) headers.
pub const FrameSendFn = *const fn (dst_ip: [4]u8, frame_buf: []u8, tcp_len: u16) bool;

pub const TcpStack = struct {
    connections: [MAX_CONNECTIONS]Connection,
    conn_hash: [HASH_BUCKETS]u16,
    /// Protects conn_hash, in_use flags, port allocation, connection pool
    alloc_lock: TcpLock,
    next_ephemeral_port: u16,
    seq_counter: u32,
    max_connections: u16,
    sendFn: SendFn,
    getIpFn: GetIpFn,
    getTicksFn: GetTicksFn,
    waiter_cb: ?WaiterCallback,
    allocBufFn: ?AllocBufFn,
    freeBufFn: ?FreeBufFn,
    /// In-place frame send path (zero-copy TX). Null = use legacy sendFn path.
    frameSendFn: ?FrameSendFn,
    /// Runtime-tunable buffer sizes (affect new connections only)
    rx_buf_size: u32,
    tx_buf_size: u32,
    /// Runtime-tunable retransmission and timeout parameters
    max_retries: u8,
    time_wait_ticks: u32,
    /// Ephemeral port range
    port_lo: u16,
    port_hi: u16,
    /// Keepalive: 0 = disabled, >0 = ticks between probes
    keepalive_ticks: u32,
    /// If true, alloc() can reclaim oldest TIME_WAIT slot when pool is full
    tw_reuse: bool,
    /// Initial RTO in ticks (default INITIAL_RTO=20 → 200ms at 10ms tick)
    initial_rto: u32,
    /// Max congestion window in bytes (0 = no cap beyond 32-bit range)
    cwnd_max: u32,
    /// If true, ACK every segment immediately (disable delayed ACK)
    nodelay: bool,
    /// If true, skip software TCP checksum (device handles it)
    csum_offload: bool,
    /// TSO: if true, send segments larger than MSS (device segments at MSS)
    tso_enabled: bool,
    /// TSO: max payload per TCP segment (limited by device buffer size)
    tso_max_size: u32,
    /// Default MSS for new connections
    default_mss: u16,
    /// Default advertised window size (1024..65535)
    default_window: u16,
    /// TCP statistics counters
    segments_tx: u64,
    segments_rx: u64,
    retransmits: u64,
    active_opens: u64,
    passive_opens: u64,

    /// Initialize a TcpStack in place.
    pub fn initInPlace(self: *TcpStack, send_fn: SendFn, get_ip_fn: GetIpFn, get_ticks_fn: GetTicksFn) void {
        self.sendFn = send_fn;
        self.getIpFn = get_ip_fn;
        self.getTicksFn = get_ticks_fn;
        self.waiter_cb = null;
        self.allocBufFn = null;
        self.freeBufFn = null;
        self.frameSendFn = null;
        self.alloc_lock = .{};
        self.next_ephemeral_port = 49152;
        self.seq_counter = 1000;
        self.max_connections = MAX_CONNECTIONS;
        self.rx_buf_size = RX_BUF_SIZE;
        self.tx_buf_size = TX_BUF_SIZE;
        self.max_retries = MAX_RETRIES;
        self.time_wait_ticks = TIME_WAIT_TICKS;
        self.port_lo = 49152;
        self.port_hi = 65535;
        self.keepalive_ticks = 0;
        self.tw_reuse = false;
        self.initial_rto = INITIAL_RTO;
        self.cwnd_max = 0;
        self.nodelay = false;
        self.csum_offload = false;
        self.tso_enabled = false;
        self.tso_max_size = 0;
        self.default_mss = DEFAULT_MSS;
        self.default_window = DEFAULT_WINDOW;
        self.segments_tx = 0;
        self.segments_rx = 0;
        self.retransmits = 0;
        self.active_opens = 0;
        self.passive_opens = 0;
        for (&self.connections) |*c| {
            c.lock = .{}; // Explicit lock init (resetConn does not touch locks)
            resetConn(c);
        }
        for (&self.conn_hash) |*h| {
            h.* = HASH_EMPTY;
        }
    }

    pub fn setWaiterCallback(self: *TcpStack, cb: WaiterCallback) void {
        self.waiter_cb = cb;
    }

    pub fn setMaxConnections(self: *TcpStack, max: u16) void {
        self.max_connections = @min(max, MAX_CONNECTIONS);
    }

    // ── Public API ──────────────────────────────────────────────

    pub fn alloc(self: *TcpStack) ?u16 {
        self.alloc_lock.lock();
        defer self.alloc_lock.unlock();
        return self.allocInner();
    }

        /// Internal alloc — caller must hold alloc_lock.
        fn allocInner(self: *TcpStack) ?u16 {
            for (self.connections[0..self.max_connections], 0..) |*c, i| {
                if (!c.in_use) {
                    resetConn(c);
                    c.in_use = true;
                    c.local_port = self.allocEphemeralPort();
                    c.local_ip = self.getIpFn();
                    return @intCast(i);
                }
            }
            // If tw_reuse is enabled, reclaim the oldest TIME_WAIT slot
            if (self.tw_reuse) {
                var oldest_tick: u32 = 0xFFFFFFFF;
                var oldest_idx: ?u16 = null;
                for (self.connections[0..self.max_connections], 0..) |*c, i| {
                    if (c.in_use and c.state == .time_wait) {
                        if (oldest_idx == null or @as(i32, @bitCast(c.retransmit_tick -% oldest_tick)) < 0) {
                            oldest_tick = c.retransmit_tick;
                            oldest_idx = @intCast(i);
                        }
                    }
                }
                if (oldest_idx) |idx| {
                    const c = &self.connections[idx];
                    self.freeConn(c, idx);
                    resetConn(c);
                    c.in_use = true;
                    c.local_port = self.allocEphemeralPort();
                    c.local_ip = self.getIpFn();
                    return idx;
                }
            }
            return null;
        }

    pub fn getState(self: *const TcpStack, idx: u16) ?TcpState {
        if (idx >= self.max_connections) return null;
        const c = &self.connections[idx];
        if (!c.in_use) return null;
        return c.state;
    }

    pub fn getLocal(self: *const TcpStack, idx: u16) ?struct { ip: [4]u8, port: u16 } {
        if (idx >= self.max_connections) return null;
        const c = &self.connections[idx];
        if (!c.in_use) return null;
        return .{ .ip = c.local_ip, .port = c.local_port };
    }

    pub fn getRemote(self: *const TcpStack, idx: u16) ?struct { ip: [4]u8, port: u16 } {
        if (idx >= self.max_connections) return null;
        const c = &self.connections[idx];
        if (!c.in_use) return null;
        return .{ .ip = c.remote_ip, .port = c.remote_port };
    }

    pub fn connect(self: *TcpStack, idx: u16, ip: [4]u8, port: u16) bool {
        if (idx >= self.max_connections) return false;
        const c = &self.connections[idx];
        c.lock.lock();
        defer c.lock.unlock();
        if (!c.in_use or c.state != .closed) return false;

        // Allocate buffers
        if (!self.allocConnBufs(c)) return false;

        c.remote_ip = ip;
        c.remote_port = port;
        c.snd_una = self.nextSeq();
        c.snd_nxt = c.snd_una;

        self.sendSynPkt(c);
        c.snd_nxt = c.snd_una +% 1;
        c.state = .syn_sent;
        c.retransmit_tick = self.getTicksFn();
        c.retransmit_count = 0;

        self.alloc_lock.lock();
        self.hashInsert(idx);
        self.alloc_lock.unlock();
        _ = @atomicRmw(u64, &self.active_opens, .Add, 1, .monotonic);
        return true;
    }

    pub fn announce(self: *TcpStack, idx: u16, port: u16) bool {
        if (idx >= self.max_connections) return false;
        const c = &self.connections[idx];
        c.lock.lock();
        defer c.lock.unlock();
        if (!c.in_use or c.state != .closed) return false;
        c.local_port = port;
        c.state = .listen;
        // Listener does not allocate buffers
        return true;
    }

    pub fn sendData(self: *TcpStack, idx: u16, data: []const u8) u32 {
        if (idx >= self.max_connections) return 0;
        const c = &self.connections[idx];
        c.lock.lock();
        defer c.lock.unlock();
        if (c.state != .established and c.state != .close_wait) return 0;
        const tx = c.tx_buf orelse return 0;

        const available = c.tx_buf_size - c.tx_len;
        const to_send: u32 = @intCast(@min(data.len, available));
        if (to_send == 0) return 0;

        @memcpy(tx[c.tx_len..][0..to_send], data[0..to_send]);
        c.tx_len += to_send;
        self.flushTxWindow(c);
        return to_send;
    }

    pub fn recvData(self: *TcpStack, idx: u16, buf: []u8) u16 {
        if (idx >= self.max_connections) return 0;
        const c = &self.connections[idx];
        c.lock.lock();
        defer c.lock.unlock();
        if (c.rx_count == 0) return 0;
        const rx = c.rx_buf orelse return 0;

        const old_count = c.rx_count;
        const to_copy: u32 = @intCast(@min(buf.len, c.rx_count));
        // Fast ring-buffer read: 1-2 memcpy with bitmask
        const read_off = (c.rx_head -% c.rx_count) & c.buf_mask;
        const first = @min(to_copy, c.buf_size - read_off);
        @memcpy(buf[0..first], rx[read_off..][0..first]);
        if (to_copy > first) {
            @memcpy(buf[first..to_copy], rx[0 .. to_copy - first]);
        }
        c.rx_count -= to_copy;

        const was_full = old_count > c.buf_size / 2;
        const now_has_room = c.rx_count <= c.buf_size / 2;
        if (c.state == .established and was_full and now_has_room) {
            self.sendAckPkt(c);
        }
        return @intCast(to_copy);
    }

    pub fn hasData(self: *const TcpStack, idx: u16) bool {
        if (idx >= self.max_connections) return false;
        return self.connections[idx].rx_count > 0;
    }

    pub fn isEof(self: *const TcpStack, idx: u16) bool {
        if (idx >= self.max_connections) return true;
        const c = &self.connections[idx];
        return c.state == .close_wait or c.state == .closing or
            c.state == .last_ack or c.state == .time_wait or c.state == .closed;
    }

    pub fn startClose(self: *TcpStack, idx: u16) void {
        if (idx >= self.max_connections) return;
        const c = &self.connections[idx];
        c.lock.lock();
        defer c.lock.unlock();
        switch (c.state) {
            .established => {
                self.sendFinPkt(c);
                c.state = .fin_wait_1;
            },
            .close_wait => {
                self.sendFinPkt(c);
                c.state = .last_ack;
            },
            .syn_sent, .syn_received => {
                self.notifyWaiters(idx, .error_reset);
                self.sendRstPkt(c);
                self.alloc_lock.lock();
                self.freeConn(c, idx);
                self.alloc_lock.unlock();
            },
            .listen => {
                self.notifyWaiters(idx, .error_reset);
                self.alloc_lock.lock();
                self.freeConn(c, idx);
                self.alloc_lock.unlock();
            },
            else => {},
        }
    }

    /// Parse TCP options, return window scale shift count (0 if not present).
    fn parseWinScale(payload: []const u8, data_offset: usize) u8 {
        if (data_offset <= HEADER_SIZE) return 0;
        const opts = payload[HEADER_SIZE..data_offset];
        var i: usize = 0;
        while (i < opts.len) {
            const kind = opts[i];
            if (kind == 0) break; // End of options
            if (kind == 1) { // NOP
                i += 1;
                continue;
            }
            if (i + 1 >= opts.len) break;
            const olen = opts[i + 1];
            if (olen < 2 or i + olen > opts.len) break;
            if (kind == 3 and olen == 3) { // Window Scale
                return @min(opts[i + 2], 14); // RFC 7323: max shift 14
            }
            i += olen;
        }
        return 0;
    }

    /// Process an incoming TCP segment (after IPv4 parsing).
    pub fn handlePacket(self: *TcpStack, payload: []const u8, ip_hdr: ipv4.Header) void {
        if (payload.len < HEADER_SIZE) return;
        _ = @atomicRmw(u64, &self.segments_rx, .Add, 1, .monotonic);

        const src_port = be16(payload[0..2]);
        const dst_port = be16(payload[2..4]);
        const seq_num = be32(payload, 4);
        const ack_num = be32(payload, 8);

        const data_offset_raw = payload[12] >> 4;
        const data_offset: usize = @as(usize, data_offset_raw) * 4;
        if (data_offset < HEADER_SIZE or data_offset > payload.len) return;

        const flags = payload[13];
        const window = be16(payload[14..16]);

        if (!verifyChecksum(payload, ip_hdr)) return;

        const data = payload[data_offset..];

        // Parse window scale from SYN or SYN-ACK options
        const wscale: u8 = if (flags & SYN != 0) parseWinScale(payload, data_offset) else 0;

        // Hash lookup (under alloc_lock) → conn lock for processing
        self.alloc_lock.lock();
        if (self.hashLookup(dst_port, src_port, ip_hdr.src)) |idx| {
            const c = &self.connections[idx];
            if (c.in_use and c.local_port == dst_port and
                c.remote_port == src_port and
                ipv4.ipEqual(c.remote_ip, ip_hdr.src))
            {
                self.alloc_lock.unlock();
                c.lock.lock();
                defer c.lock.unlock();
                if (flags & SYN != 0 and c.state == .syn_sent) {
                    c.snd_wnd_scale = wscale;
                }
                self.handleSegment(c, idx, seq_num, ack_num, flags, window, data);
                return;
            }
        }

        // Linear scan for listeners (still under alloc_lock)
        for (self.connections[0..self.max_connections], 0..) |*c, i| {
            if (c.in_use and c.state == .listen and c.local_port == dst_port) {
                self.alloc_lock.unlock();
                c.lock.lock();
                defer c.lock.unlock();
                self.handleListenSegment(c, @intCast(i), seq_num, flags, ip_hdr, src_port);
                return;
            }
        }
        self.alloc_lock.unlock();

        // No match — send RST
        if (flags & RST == 0) {
            self.sendRstReply(ip_hdr.src, src_port, dst_port, seq_num, ack_num, flags, @intCast(data.len));
        }
    }

    /// Timer tick — retransmission, TIME_WAIT expiry, keepalive.
    pub fn tick(self: *TcpStack, now: u32) void {
        for (self.connections[0..self.max_connections], 0..) |*c, i| {
            if (!c.in_use) continue; // quick unlocked check
            c.lock.lock();
            if (!c.in_use) { c.lock.unlock(); continue; } // re-check under lock
            const idx: u16 = @intCast(i);
            var need_free = false;

            switch (c.state) {
                .syn_sent => {
                    if (now -% c.retransmit_tick >= c.rto) {
                        if (c.retransmit_count >= self.max_retries) {
                            self.notifyWaiters(idx, .error_reset);
                            need_free = true;
                        } else {
                            self.sendSynPkt(c);
                            c.retransmit_count += 1;
                            c.retransmit_tick = now;
                            c.rto *= 2;
                            _ = @atomicRmw(u64, &self.retransmits, .Add, 1, .monotonic);
                        }
                    }
                },
                .established, .close_wait => {
                    // Flush delayed ACKs on timer tick
                    if (c.ack_pending > 0) {
                        self.sendAckPkt(c);
                        c.ack_pending = 0;
                    }
                    if (c.tx_len > 0 and seqDiff(c.snd_nxt, c.snd_una) > 0) {
                        if (now -% c.retransmit_tick >= c.rto) {
                            if (c.retransmit_count >= self.max_retries) {
                                self.notifyWaiters(idx, .error_reset);
                                self.sendRstPkt(c);
                                need_free = true;
                            } else {
                                self.sendDataSegment(c);
                                c.retransmit_count += 1;
                                c.retransmit_tick = now;
                                // Cap RTO backoff at ~3.2s (initial 200ms * 2^4)
                                if (c.rto < self.initial_rto * 16) {
                                    c.rto *= 2;
                                }
                                _ = @atomicRmw(u64, &self.retransmits, .Add, 1, .monotonic);
                            }
                        }
                    }
                    // Zero-window probe (RFC 1122 §4.2.2.17): data pending but
                    // peer's receive window is closed and nothing is in flight.
                    // Send a keepalive-style probe to solicit a window update.
                    if (c.tx_len > 0 and c.snd_wnd == 0 and
                        seqDiff(c.snd_nxt, c.snd_una) == 0)
                    {
                        if (now -% c.retransmit_tick >= c.rto) {
                            self.sendFlagsPktSeq(c, ACK, c.snd_una -% 1);
                            c.retransmit_tick = now;
                            if (c.rto < self.initial_rto * 16) {
                                c.rto *= 2;
                            }
                        }
                    }
                    // Stalled TX retry: data pending, window open, but nothing
                    // in flight (previous flushTxWindow may have been blocked by
                    // a full deferred TX queue). Try again.
                    if (c.tx_len > 0 and c.snd_wnd > 0 and
                        seqDiff(c.snd_nxt, c.snd_una) == 0)
                    {
                        self.flushTxWindow(c);
                    }
                    // Keepalive probe for idle established connections
                    if (c.state == .established and self.keepalive_ticks > 0 and
                        c.tx_len == 0 and seqDiff(c.snd_nxt, c.snd_una) == 0)
                    {
                        if (now -% c.retransmit_tick >= self.keepalive_ticks) {
                            // Send keepalive probe: ACK with seq = snd_una - 1
                            self.sendFlagsPktSeq(c, ACK, c.snd_una -% 1);
                            c.retransmit_tick = now;
                        }
                    }
                },
                .fin_wait_1, .last_ack, .closing => {
                    if (now -% c.retransmit_tick >= c.rto) {
                        if (c.retransmit_count >= self.max_retries) {
                            need_free = true;
                        } else {
                            self.sendFinPkt(c);
                            c.retransmit_count += 1;
                            c.retransmit_tick = now;
                            _ = @atomicRmw(u64, &self.retransmits, .Add, 1, .monotonic);
                        }
                    }
                },
                .time_wait => {
                    if (now -% c.retransmit_tick >= self.time_wait_ticks) {
                        need_free = true;
                    }
                },
                else => {},
            }

            if (need_free) {
                self.alloc_lock.lock();
                self.freeConn(c, idx);
                self.alloc_lock.unlock();
            }
            c.lock.unlock();
        }
    }

    // ── Internal ────────────────────────────────────────────────

    fn handleSegment(self: *TcpStack, c: *Connection, idx: u16, seq: u32, ack: u32, flags: u8, window: u16, data: []const u8) void {
        if (flags & RST != 0) {
            self.notifyWaiters(idx, .error_reset);
            self.alloc_lock.lock();
            self.freeConn(c, idx);
            self.alloc_lock.unlock();
            return;
        }

        // Apply peer's window scale to the raw header window value
        const scaled_wnd: u32 = @as(u32, window) << @intCast(c.snd_wnd_scale);

        switch (c.state) {
            .syn_sent => {
                if (flags & SYN != 0 and flags & ACK != 0 and ack == c.snd_nxt) {
                    c.rcv_nxt = seq +% 1;
                    c.snd_una = ack;
                    c.snd_wnd = scaled_wnd;
                    c.state = .established;
                    c.retransmit_count = 0;
                    c.rto = self.initial_rto;
                    c.tx_len = 0;
                    self.sendAckPkt(c);
                    self.notifyWaiters(idx, .connect_done);
                }
            },
            .syn_received => {
                if (flags & ACK != 0 and ack == c.snd_nxt) {
                    c.snd_una = ack;
                    c.snd_wnd = scaled_wnd;
                    c.state = .established;
                    c.retransmit_count = 0;
                    c.rto = self.initial_rto;
                    if (c.parent_idx != 0xFFFF and c.parent_idx < self.max_connections) {
                        self.notifyWaiters(c.parent_idx, .accept_ready);
                    }
                }
            },
            .established => self.handleEstablished(c, idx, seq, ack, flags, window, data),
            .fin_wait_1 => {
                if (flags & ACK != 0 and ack == c.snd_nxt) c.snd_una = ack;
                if (flags & FIN != 0) {
                    c.rcv_nxt = seq +% 1;
                    self.sendAckPkt(c);
                    c.state = if (c.snd_una == c.snd_nxt) .time_wait else .closing;
                    if (c.state == .time_wait) c.retransmit_tick = self.getTicksFn();
                } else if (c.snd_una == c.snd_nxt) {
                    c.state = .fin_wait_2;
                }
            },
            .fin_wait_2 => {
                if (flags & FIN != 0) {
                    c.rcv_nxt = seq +% 1;
                    self.sendAckPkt(c);
                    c.state = .time_wait;
                    c.retransmit_tick = self.getTicksFn();
                }
            },
            .closing => {
                if (flags & ACK != 0 and ack == c.snd_nxt) {
                    c.state = .time_wait;
                    c.retransmit_tick = self.getTicksFn();
                }
            },
            .last_ack => {
                if (flags & ACK != 0 and ack == c.snd_nxt) {
                    self.alloc_lock.lock();
                    self.freeConn(c, idx);
                    self.alloc_lock.unlock();
                }
            },
            .close_wait => {
                if (flags & ACK != 0) self.processAck(c, ack, window);
            },
            else => {},
        }
    }

    fn handleEstablished(self: *TcpStack, c: *Connection, idx: u16, seq: u32, ack: u32, flags: u8, window: u16, data: []const u8) void {
        if (flags & ACK != 0) self.processAck(c, ack, window);

        if (data.len > 0) {
            if (seq == c.rcv_nxt) {
                if (c.rx_buf) |rx| {
                    const space = c.buf_size - c.rx_count;
                    const to_buf: u32 = @intCast(@min(data.len, space));
                    // Fast ring-buffer write: 1-2 memcpy with bitmask
                    const head_off = c.rx_head & c.buf_mask;
                    const first = @min(to_buf, c.buf_size - head_off);
                    @memcpy(rx[head_off..][0..first], data[0..first]);
                    if (to_buf > first) {
                        @memcpy(rx[0 .. to_buf - first], data[first..to_buf]);
                    }
                    c.rx_head +%= to_buf;
                    c.rx_count += to_buf;
                    c.rcv_nxt +%= @as(u32, to_buf);
                    self.notifyWaiters(idx, .data_ready);
                }
            }
            // Delayed ACK: ACK every 2nd segment (or immediately if nodelay)
            c.ack_pending += 1;
            if (self.nodelay or c.ack_pending >= 2 or flags & FIN != 0) {
                self.sendAckPkt(c);
                c.ack_pending = 0;
            }
        }

        if (flags & FIN != 0) {
            if (seq == c.rcv_nxt or (data.len > 0 and seq +% @as(u32, @intCast(data.len)) == c.rcv_nxt)) {
                c.rcv_nxt +%= 1;
            }
            self.sendAckPkt(c);
            c.ack_pending = 0;
            c.state = .close_wait;
            self.notifyWaiters(idx, .eof);
        }
    }

    fn processAck(self: *TcpStack, c: *Connection, ack: u32, window: u16) void {
        c.snd_wnd = @as(u32, window) << @intCast(c.snd_wnd_scale);
        if (seqDiff(ack, c.snd_una) > 0 and seqDiff(ack, c.snd_nxt) <= 0) {
            const acked: u32 = ack -% c.snd_una;
            c.snd_una = ack;
            if (c.tx_buf) |tx| {
                if (acked <= c.tx_len) {
                    const remaining = c.tx_len - acked;
                    if (remaining > 0) {
                        // Forward copy: dst < src (acked > 0) so forward iteration
                        // is safe even though regions overlap. @memcpy forbids
                        // overlap, so we copy manually.
                        const dst = tx;
                        const src = tx + acked;
                        for (0..remaining) |i| {
                            dst[i] = src[i];
                        }
                    }
                    c.tx_len = remaining;
                } else {
                    c.tx_len = 0;
                }
            } else {
                c.tx_len = 0;
            }
            c.retransmit_count = 0;
            c.rto = self.initial_rto;
            c.retransmit_tick = self.getTicksFn();

            // Congestion control: slow start / congestion avoidance
            const mss32: u32 = c.mss;
            if (c.cwnd == 0) {
                c.cwnd = @max(1, mss32);
            } else if (c.cwnd < c.ssthresh) {
                // Slow start: increase cwnd by MSS per ACK
                c.cwnd +|= mss32;
            } else {
                // Congestion avoidance: increase cwnd by ~MSS per RTT
                c.cwnd +|= @max(1, mss32 * mss32 / c.cwnd);
            }
            // Cap cwnd (0 = no cap, otherwise configurable max)
            if (self.cwnd_max > 0 and c.cwnd > self.cwnd_max) {
                c.cwnd = self.cwnd_max;
            }

            // Send more segments within the window
            if (c.tx_len > 0) {
                self.flushTxWindow(c);
            }
        }
    }

    fn handleListenSegment(self: *TcpStack, listener: *Connection, listener_idx: u16, seq: u32, flags: u8, ip_hdr: ipv4.Header, src_port: u16) void {
        if (flags & SYN == 0 or flags & ACK != 0 or flags & RST != 0) return;

        // Take alloc_lock for allocation + hash insert (conn.lock → alloc_lock ordering OK)
        self.alloc_lock.lock();
        const child_idx = self.allocInner() orelse {
            self.alloc_lock.unlock();
            return;
        };
        const child = &self.connections[child_idx];

        // Allocate buffers for the child connection
        if (!self.allocConnBufs(child)) {
            // Alloc failed — free the child slot and send RST
            self.freeConn(child, child_idx);
            self.alloc_lock.unlock();
            self.sendRstReply(ip_hdr.src, src_port, listener.local_port, seq, 0, flags, 0);
            return;
        }

        child.local_port = listener.local_port;
        child.local_ip = listener.local_ip;
        child.remote_ip = ip_hdr.src;
        child.remote_port = src_port;
        child.rcv_nxt = seq +% 1;
        child.snd_una = self.nextSeq();
        child.snd_nxt = child.snd_una +% 1;
        child.state = .syn_received;
        child.parent_idx = listener_idx;
        child.retransmit_tick = self.getTicksFn();

        self.hashInsert(child_idx);
        self.alloc_lock.unlock();

        self.sendFlagsPkt(child, SYN | ACK, child.snd_una);
        _ = @atomicRmw(u64, &self.passive_opens, .Add, 1, .monotonic);
    }

    /// Allocate rx and tx buffers for a connection using allocBufFn.
    /// Returns false if allocBufFn is null or allocation fails.
    fn allocConnBufs(self: *TcpStack, c: *Connection) bool {
        const alloc_fn = self.allocBufFn orelse return false;
        const rx_size = roundUpPow2(self.rx_buf_size);
        const tx_size = self.tx_buf_size;

        const rx = alloc_fn(rx_size) orelse return false;
        const tx = alloc_fn(tx_size) orelse {
            // Free rx on failure
            if (self.freeBufFn) |free_fn| free_fn(rx, rx_size);
            return false;
        };

        c.rx_buf = rx;
        c.tx_buf = tx;
        c.buf_size = rx_size;
        c.buf_mask = rx_size - 1;
        c.tx_buf_size = tx_size;
        return true;
    }

    /// Free rx and tx buffers for a connection using freeBufFn.
    fn freeConnBufs(self: *TcpStack, c: *Connection) void {
        const free_fn = self.freeBufFn orelse return;
        if (c.rx_buf) |rx| {
            free_fn(rx, c.buf_size);
            c.rx_buf = null;
        }
        if (c.tx_buf) |tx| {
            free_fn(tx, c.tx_buf_size);
            c.tx_buf = null;
        }
        c.buf_size = 0;
        c.tx_buf_size = 0;
    }

    // ── Segment building ────────────────────────────────────────

    fn sendSynPkt(self: *TcpStack, c: *Connection) void {
        // SYN with MSS and Window Scale options (24 bytes total header)
        // Options: MSS (4 bytes) + WScale (3 bytes) + NOP (1 byte pad)
        const OPT_LEN = 8;
        var tcp_buf: [HEADER_SIZE + OPT_LEN]u8 = undefined;
        const rx_space = if (c.buf_size > 0) c.buf_size - c.rx_count else 0;
        const window: u16 = @intCast(@min(rx_space, 65535));
        buildHeader(tcp_buf[0..HEADER_SIZE], c.local_port, c.remote_port, c.snd_una, c.rcv_nxt, SYN, window, 0);
        // Set data offset to 7 (28 bytes = 20 header + 8 options)
        tcp_buf[12] = 0x70;
        // MSS option: kind=2, len=4, value=1460
        tcp_buf[HEADER_SIZE] = 2;
        tcp_buf[HEADER_SIZE + 1] = 4;
        ipv4.writeBe16(&tcp_buf, HEADER_SIZE + 2, DEFAULT_MSS);
        // Window Scale option: kind=3, len=3, value=0 (no scaling on our side)
        tcp_buf[HEADER_SIZE + 4] = 3;
        tcp_buf[HEADER_SIZE + 5] = 3;
        tcp_buf[HEADER_SIZE + 6] = 0; // shift count 0
        // NOP padding
        tcp_buf[HEADER_SIZE + 7] = 1;
        if (self.csum_offload) {
            const pseudo = tcpPseudoChecksum(c.local_ip, c.remote_ip, HEADER_SIZE + OPT_LEN);
            ipv4.writeBe16(&tcp_buf, 16, pseudo);
        } else {
            const cksum = tcpChecksum(c.local_ip, c.remote_ip, &tcp_buf);
            ipv4.writeBe16(&tcp_buf, 16, cksum);
        }
        _ = self.sendFn(c.remote_ip, &tcp_buf);
        _ = @atomicRmw(u64, &self.segments_tx, .Add, 1, .monotonic);
    }

    fn sendAckPkt(self: *TcpStack, c: *Connection) void {
        self.sendFlagsPkt(c, ACK, c.snd_nxt);
    }

    fn sendFinPkt(self: *TcpStack, c: *Connection) void {
        self.sendFlagsPkt(c, FIN | ACK, c.snd_nxt);
        c.snd_nxt = c.snd_nxt +% 1;
        c.retransmit_tick = self.getTicksFn();
        c.retransmit_count = 0;
    }

    fn sendRstPkt(self: *TcpStack, c: *Connection) void {
        self.sendFlagsPkt(c, RST | ACK, c.snd_nxt);
    }

    fn sendFlagsPkt(self: *TcpStack, c: *Connection, flags: u8, seq: u32) void {
        var tcp_buf: [HEADER_SIZE]u8 = undefined;
        const rx_space = if (c.buf_size > 0) c.buf_size - c.rx_count else 0;
        const window: u16 = @intCast(@min(rx_space, 65535));
        buildHeader(&tcp_buf, c.local_port, c.remote_port, seq, c.rcv_nxt, flags, window, 0);
        if (self.csum_offload) {
            const pseudo = tcpPseudoChecksum(c.local_ip, c.remote_ip, HEADER_SIZE);
            ipv4.writeBe16(&tcp_buf, 16, pseudo);
        } else {
            const cksum = tcpChecksum(c.local_ip, c.remote_ip, &tcp_buf);
            ipv4.writeBe16(&tcp_buf, 16, cksum);
        }
        _ = self.sendFn(c.remote_ip, &tcp_buf);
        _ = @atomicRmw(u64, &self.segments_tx, .Add, 1, .monotonic);
    }

    /// Send a flags packet with an explicit seq (used for keepalive probes).
    fn sendFlagsPktSeq(self: *TcpStack, c: *Connection, flags: u8, seq: u32) void {
        self.sendFlagsPkt(c, flags, seq);
    }

    /// Retransmit the first MSS of unsent data from snd_una (loss recovery).
    /// Applies multiplicative decrease to cwnd.
    fn sendDataSegment(self: *TcpStack, c: *Connection) void {
        if (c.tx_len == 0) return;
        const tx = c.tx_buf orelse return;
        const send_len: u16 = @intCast(@min(c.tx_len, c.mss));
        var tcp_buf: [HEADER_SIZE + DEFAULT_MSS]u8 = undefined;
        const total_len = HEADER_SIZE + send_len;
        const rx_space = if (c.buf_size > 0) c.buf_size - c.rx_count else 0;
        const window: u16 = @intCast(@min(rx_space, 65535));
        buildHeader(tcp_buf[0..HEADER_SIZE], c.local_port, c.remote_port, c.snd_una, c.rcv_nxt, ACK | PSH, window, 0);
        @memcpy(tcp_buf[HEADER_SIZE..][0..send_len], tx[0..send_len]);
        if (self.csum_offload) {
            const pseudo = tcpPseudoChecksum(c.local_ip, c.remote_ip, @intCast(total_len));
            ipv4.writeBe16(&tcp_buf, 16, pseudo);
        } else {
            const cksum = tcpChecksum(c.local_ip, c.remote_ip, tcp_buf[0..total_len]);
            ipv4.writeBe16(&tcp_buf, 16, cksum);
        }
        if (!self.sendFn(c.remote_ip, tcp_buf[0..total_len])) return;
        c.snd_nxt = c.snd_una +% @as(u32, send_len);
        c.retransmit_tick = self.getTicksFn();
        // Multiplicative decrease on retransmit
        c.ssthresh = @max(2 * @as(u32, c.mss), c.cwnd / 2);
        c.cwnd = @as(u32, c.mss);
        _ = @atomicRmw(u64, &self.segments_tx, .Add, 1, .monotonic);
    }

    /// Send multiple MSS-sized segments up to min(cwnd, snd_wnd) window.
    fn flushTxWindow(self: *TcpStack, c: *Connection) void {
        if (c.tx_len == 0) return;
        const tx = c.tx_buf orelse return;

        const flight: u32 = @intCast(@max(0, seqDiff(c.snd_nxt, c.snd_una)));
        const effective_wnd: u32 = @min(c.cwnd, @as(u32, c.snd_wnd));
        if (flight >= effective_wnd) return;

        var allowed = effective_wnd - flight;
        var offset: u32 = flight; // offset into tx_buf for next unsent byte
        // TSO: send larger segments when offload is available
        const max_seg: u32 = if (self.tso_enabled) @min(self.tso_max_size, 65535 - FRAME_HDR) else c.mss;

        // In-place frame path: build TCP+payload directly in frame buffer
        if (self.frameSendFn) |frameSend| {
            while (offset < c.tx_len and allowed > 0) {
                const chunk: u16 = @intCast(@min(@min(c.tx_len - offset, max_seg), allowed));
                if (chunk == 0) break;

                // Use stack buffer for TSO (max ~4KB) or normal MSS frames
                var frame_buf: [FRAME_HDR + 4096]u8 = undefined;
                const tcp_total: u16 = HEADER_SIZE + chunk;
                const seq = c.snd_una +% offset;
                const rx_space = if (c.buf_size > 0) c.buf_size - c.rx_count else 0;
                const window: u16 = @intCast(@min(rx_space, 65535));
                const is_last = (offset + chunk >= c.tx_len) or (allowed -| chunk == 0);
                const flags: u8 = ACK | if (is_last) PSH else 0;
                // TCP header at frame[34..54]
                buildHeader(frame_buf[FRAME_HDR - HEADER_SIZE .. FRAME_HDR], c.local_port, c.remote_port, seq, c.rcv_nxt, flags, window, 0);
                // Payload at frame[54..] — ONE copy from tx_buf
                @memcpy(frame_buf[FRAME_HDR..][0..chunk], tx[offset..][0..chunk]);
                // Checksum: pseudo-only for offload, full for software
                const tcp_slice = frame_buf[FRAME_HDR - HEADER_SIZE ..][0..tcp_total];
                if (self.csum_offload) {
                    const pseudo = tcpPseudoChecksum(c.local_ip, c.remote_ip, tcp_total);
                    ipv4.writeBe16(tcp_slice, 16, pseudo);
                } else {
                    const cksum = tcpChecksum(c.local_ip, c.remote_ip, tcp_slice);
                    ipv4.writeBe16(tcp_slice, 16, cksum);
                }
                if (!frameSend(c.remote_ip, &frame_buf, tcp_total)) break;
                _ = @atomicRmw(u64, &self.segments_tx, .Add, 1, .monotonic);

                offset += chunk;
                allowed -|= chunk;
            }
        } else {
            // Legacy path: build TCP segment, caller wraps in IP+ETH
            while (offset < c.tx_len and allowed > 0) {
                const chunk: u16 = @intCast(@min(@min(c.tx_len - offset, max_seg), allowed));
                if (chunk == 0) break;

                var tcp_buf: [HEADER_SIZE + 4096]u8 = undefined;
                const total_len = HEADER_SIZE + chunk;
                const seq = c.snd_una +% offset;
                const rx_space = if (c.buf_size > 0) c.buf_size - c.rx_count else 0;
                const window: u16 = @intCast(@min(rx_space, 65535));
                const is_last = (offset + chunk >= c.tx_len) or (allowed -| chunk == 0);
                const flags: u8 = ACK | if (is_last) PSH else 0;
                buildHeader(tcp_buf[0..HEADER_SIZE], c.local_port, c.remote_port, seq, c.rcv_nxt, flags, window, 0);
                @memcpy(tcp_buf[HEADER_SIZE..][0..chunk], tx[offset..][0..chunk]);
                if (self.csum_offload) {
                    const pseudo = tcpPseudoChecksum(c.local_ip, c.remote_ip, @intCast(total_len));
                    ipv4.writeBe16(&tcp_buf, 16, pseudo);
                } else {
                    const cksum = tcpChecksum(c.local_ip, c.remote_ip, tcp_buf[0..total_len]);
                    ipv4.writeBe16(&tcp_buf, 16, cksum);
                }
                if (!self.sendFn(c.remote_ip, tcp_buf[0..total_len])) break;
                _ = @atomicRmw(u64, &self.segments_tx, .Add, 1, .monotonic);

                offset += chunk;
                allowed -|= chunk;
            }
        }

        c.snd_nxt = c.snd_una +% offset;
        c.retransmit_tick = self.getTicksFn();
    }

    fn sendRstReply(self: *TcpStack, dst_ip: [4]u8, dst_port: u16, src_port: u16, seq: u32, ack: u32, in_flags: u8, data_len: u16) void {
        var tcp_buf: [HEADER_SIZE]u8 = undefined;
        if (in_flags & ACK != 0) {
            buildHeader(&tcp_buf, src_port, dst_port, ack, 0, RST, 0, 0);
        } else {
            const response_ack = seq +% @as(u32, data_len) +% if (in_flags & SYN != 0) @as(u32, 1) else @as(u32, 0);
            buildHeader(&tcp_buf, src_port, dst_port, 0, response_ack, RST | ACK, 0, 0);
        }
        const our_ip = self.getIpFn();
        if (self.csum_offload) {
            const pseudo = tcpPseudoChecksum(our_ip, dst_ip, HEADER_SIZE);
            ipv4.writeBe16(&tcp_buf, 16, pseudo);
        } else {
            const cksum = tcpChecksum(our_ip, dst_ip, &tcp_buf);
            ipv4.writeBe16(&tcp_buf, 16, cksum);
        }
        _ = self.sendFn(dst_ip, &tcp_buf);
    }

    // ── Hash table ──────────────────────────────────────────────

    fn hashInsert(self: *TcpStack, idx: u16) void {
        const c = &self.connections[idx];
        const bucket = connHashFn(c.local_port, c.remote_port, c.remote_ip);
        c.hash_next = self.conn_hash[bucket];
        self.conn_hash[bucket] = idx;
    }

    fn hashRemove(self: *TcpStack, idx: u16) void {
        const c = &self.connections[idx];
        const bucket = connHashFn(c.local_port, c.remote_port, c.remote_ip);
        if (self.conn_hash[bucket] == idx) {
            self.conn_hash[bucket] = c.hash_next;
        } else {
            var prev = self.conn_hash[bucket];
            while (prev != HASH_EMPTY) {
                if (self.connections[prev].hash_next == idx) {
                    self.connections[prev].hash_next = c.hash_next;
                    break;
                }
                prev = self.connections[prev].hash_next;
            }
        }
        c.hash_next = HASH_EMPTY;
    }

    fn hashLookup(self: *const TcpStack, local_port: u16, remote_port: u16, remote_ip: [4]u8) ?u16 {
        const bucket = connHashFn(local_port, remote_port, remote_ip);
        var idx = self.conn_hash[bucket];
        while (idx != HASH_EMPTY) {
            const c = &self.connections[idx];
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

    fn freeConn(self: *TcpStack, c: *Connection, idx: u16) void {
        self.hashRemove(idx);
        self.freeConnBufs(c);
        resetConn(c);
    }

    fn notifyWaiters(self: *TcpStack, idx: u16, event: WaiterEvent) void {
        if (self.waiter_cb) |cb| {
            cb(idx, event);
        }
    }

    fn nextSeq(self: *TcpStack) u32 {
        self.seq_counter +%= 64000;
        return self.seq_counter;
    }

    fn allocEphemeralPort(self: *TcpStack) u16 {
        const port = self.next_ephemeral_port;
        self.next_ephemeral_port +%= 1;
        if (self.next_ephemeral_port < self.port_lo or self.next_ephemeral_port > self.port_hi) {
            self.next_ephemeral_port = self.port_lo;
        }
        return port;
    }

    pub fn activeConns(self: *const TcpStack) u64 {
        var count: u64 = 0;
        for (self.connections[0..self.max_connections]) |c| {
            if (c.in_use and c.state != .closed and c.state != .listen) count += 1;
        }
        return count;
    }
};

// ── Static helpers (no self) ────────────────────────────────────────

fn resetConn(c: *Connection) void {
    // NOTE: does NOT reset c.lock — lock lifetime outlives connection to
    // prevent use-after-free races (freeConn under conn.lock then defer unlock).
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
    c.rx_buf = null;
    c.rx_head = 0;
    c.rx_count = 0;
    c.tx_buf = null;
    c.tx_len = 0;
    c.retransmit_tick = 0;
    c.retransmit_count = 0;
    c.rto = INITIAL_RTO;
    c.parent_idx = 0xFFFF;
    c.cwnd = 10 * @as(u32, DEFAULT_MSS); // RFC 6928 IW10
    c.ssthresh = 65535;
    c.ack_pending = 0;
    c.snd_wnd_scale = 0;
    c.buf_size = 0;
    c.tx_buf_size = 0;
    c.buf_mask = 0;
}

fn connHashFn(local_port: u16, remote_port: u16, remote_ip: [4]u8) u12 {
    var h: u32 = 2166136261;
    h ^= local_port;
    h *%= 16777619;
    h ^= remote_port;
    h *%= 16777619;
    h ^= @as(u32, remote_ip[0]) | @as(u32, remote_ip[1]) << 8 |
        @as(u32, remote_ip[2]) << 16 | @as(u32, remote_ip[3]) << 24;
    h *%= 16777619;
    return @truncate(h);
}

fn roundUpPow2(v: u32) u32 {
    if (v == 0) return 1;
    var x = v - 1;
    x |= x >> 1;
    x |= x >> 2;
    x |= x >> 4;
    x |= x >> 8;
    x |= x >> 16;
    return x + 1;
}

fn seqDiff(a: u32, b: u32) i32 {
    return @as(i32, @bitCast(a -% b));
}

fn buildHeader(buf: *[HEADER_SIZE]u8, src_port: u16, dst_port: u16, seq: u32, ack: u32, flags: u8, window: u16, urgent: u16) void {
    ipv4.writeBe16(buf, 0, src_port);
    ipv4.writeBe16(buf, 2, dst_port);
    ipv4.writeBe32(buf, 4, seq);
    ipv4.writeBe32(buf, 8, ack);
    buf[12] = 0x50;
    buf[13] = flags;
    ipv4.writeBe16(buf, 14, window);
    ipv4.writeBe16(buf, 16, 0);
    ipv4.writeBe16(buf, 18, urgent);
}

pub fn tcpChecksum(src_ip: [4]u8, dst_ip: [4]u8, tcp_segment: []const u8) u16 {
    var pseudo: [12]u8 = undefined;
    @memcpy(pseudo[0..4], &src_ip);
    @memcpy(pseudo[4..8], &dst_ip);
    pseudo[8] = 0;
    pseudo[9] = ipv4.PROTO_TCP;
    const tcp_len: u16 = @intCast(tcp_segment.len);
    ipv4.writeBe16(&pseudo, 10, tcp_len);

    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < pseudo.len) : (i += 2) {
        sum += @as(u32, pseudo[i]) << 8 | pseudo[i + 1];
    }
    i = 0;
    while (i + 1 < tcp_segment.len) : (i += 2) {
        sum += @as(u32, tcp_segment[i]) << 8 | tcp_segment[i + 1];
    }
    if (i < tcp_segment.len) {
        sum += @as(u32, tcp_segment[i]) << 8;
    }
    while (sum >> 16 != 0) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    return @truncate(~sum);
}

/// Compute only the TCP pseudo-header partial checksum (for HW offload).
/// The device will add the TCP header + payload sum and finalize.
pub fn tcpPseudoChecksum(src_ip: [4]u8, dst_ip: [4]u8, tcp_len: u16) u16 {
    var sum: u32 = 0;
    sum += @as(u32, src_ip[0]) << 8 | src_ip[1];
    sum += @as(u32, src_ip[2]) << 8 | src_ip[3];
    sum += @as(u32, dst_ip[0]) << 8 | dst_ip[1];
    sum += @as(u32, dst_ip[2]) << 8 | dst_ip[3];
    sum += @as(u32, ipv4.PROTO_TCP);
    sum += tcp_len;
    while (sum >> 16 != 0) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    return @truncate(sum); // NOT inverted — device does final complement
}

fn verifyChecksum(tcp_segment: []const u8, ip_hdr: ipv4.Header) bool {
    return tcpChecksum(ip_hdr.src, ip_hdr.dst, tcp_segment) == 0;
}

fn be16(bytes: *const [2]u8) u16 {
    return @as(u16, bytes[0]) << 8 | bytes[1];
}

fn be32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) << 24 |
        @as(u32, bytes[offset + 1]) << 16 |
        @as(u32, bytes[offset + 2]) << 8 |
        bytes[offset + 3];
}
