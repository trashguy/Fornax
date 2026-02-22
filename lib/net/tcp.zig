/// TCP: Transmission Control Protocol (userspace, struct-based).
///
/// Each TcpStack instance owns its connection pool, hash table, and state.
/// No global state — suitable for per-realm netd instances.
///
/// Caller provides:
///   - sendFn: callback to send an IP packet (builds and transmits)
///   - getIpFn: callback to get our current IP address
///   - getTicksFn: callback to get current tick count (for retransmission)
const ipv4 = @import("ipv4.zig");

pub const HEADER_SIZE = 20;
pub const MAX_CONNECTIONS = 256;
pub const RX_BUF_SIZE = 16384;
pub const TX_BUF_SIZE = 4096;
pub const DEFAULT_MSS: u16 = 1460;
pub const DEFAULT_WINDOW: u16 = 16384;
pub const INITIAL_RTO: u32 = 18;
pub const MAX_RETRIES: u8 = 8;
pub const TIME_WAIT_TICKS: u32 = 36;

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
const HASH_EMPTY: u8 = 0xFF;
const HASH_BUCKETS = 256;

/// Waiter callback: called when a connection event occurs.
/// The netd server maps these to IPC replies.
pub const WaiterCallback = *const fn (conn_idx: u8, event: WaiterEvent) void;
pub const WaiterEvent = enum { data_ready, connect_done, accept_ready, error_reset, eof };

pub const Connection = struct {
    in_use: bool,
    state: TcpState,
    hash_next: u8,
    local_port: u16,
    remote_port: u16,
    local_ip: [4]u8,
    remote_ip: [4]u8,
    snd_una: u32,
    snd_nxt: u32,
    rcv_nxt: u32,
    snd_wnd: u16,
    mss: u16,
    rx_buf: [RX_BUF_SIZE]u8,
    rx_head: u16,
    rx_count: u16,
    tx_buf: [TX_BUF_SIZE]u8,
    tx_len: u16,
    retransmit_tick: u32,
    retransmit_count: u8,
    rto: u32,
    parent_idx: u8,
};

/// Callback to send an IP-encapsulated TCP segment.
pub const SendFn = *const fn (dst_ip: [4]u8, tcp_segment: []const u8) void;
/// Callback to get our IP address.
pub const GetIpFn = *const fn () [4]u8;
/// Callback to get current tick count.
pub const GetTicksFn = *const fn () u32;

pub const TcpStack = struct {
    connections: [MAX_CONNECTIONS]Connection,
    conn_hash: [HASH_BUCKETS]u8,
    next_ephemeral_port: u16,
    seq_counter: u32,
    max_connections: u16, // runtime cap (default 32, max 256)
    sendFn: SendFn,
    getIpFn: GetIpFn,
    getTicksFn: GetTicksFn,
    waiter_cb: ?WaiterCallback,
    /// TCP statistics counters
    segments_tx: u64,
    segments_rx: u64,
    retransmits: u64,
    active_opens: u64,
    passive_opens: u64,

    pub fn init(send_fn: SendFn, get_ip_fn: GetIpFn, get_ticks_fn: GetTicksFn) TcpStack {
        var stack: TcpStack = undefined;
        stack.sendFn = send_fn;
        stack.getIpFn = get_ip_fn;
        stack.getTicksFn = get_ticks_fn;
        stack.waiter_cb = null;
        stack.next_ephemeral_port = 49152;
        stack.seq_counter = 1000;
        stack.max_connections = 32;
        stack.segments_tx = 0;
        stack.segments_rx = 0;
        stack.retransmits = 0;
        stack.active_opens = 0;
        stack.passive_opens = 0;
        for (&stack.connections) |*c| {
            resetConn(c);
        }
        for (&stack.conn_hash) |*h| {
            h.* = HASH_EMPTY;
        }
        return stack;
    }

    pub fn setWaiterCallback(self: *TcpStack, cb: WaiterCallback) void {
        self.waiter_cb = cb;
    }

    pub fn setMaxConnections(self: *TcpStack, max: u16) void {
        self.max_connections = @min(max, MAX_CONNECTIONS);
    }

    // ── Public API ──────────────────────────────────────────────

    pub fn alloc(self: *TcpStack) ?u8 {
        for (self.connections[0..self.max_connections], 0..) |*c, i| {
            if (!c.in_use) {
                resetConn(c);
                c.in_use = true;
                c.local_port = self.allocEphemeralPort();
                c.local_ip = self.getIpFn();
                return @intCast(i);
            }
        }
        return null;
    }

    pub fn getState(self: *const TcpStack, idx: u8) ?TcpState {
        if (idx >= self.max_connections) return null;
        const c = &self.connections[idx];
        if (!c.in_use) return null;
        return c.state;
    }

    pub fn getLocal(self: *const TcpStack, idx: u8) ?struct { ip: [4]u8, port: u16 } {
        if (idx >= self.max_connections) return null;
        const c = &self.connections[idx];
        if (!c.in_use) return null;
        return .{ .ip = c.local_ip, .port = c.local_port };
    }

    pub fn getRemote(self: *const TcpStack, idx: u8) ?struct { ip: [4]u8, port: u16 } {
        if (idx >= self.max_connections) return null;
        const c = &self.connections[idx];
        if (!c.in_use) return null;
        return .{ .ip = c.remote_ip, .port = c.remote_port };
    }

    pub fn connect(self: *TcpStack, idx: u8, ip: [4]u8, port: u16) bool {
        if (idx >= self.max_connections) return false;
        const c = &self.connections[idx];
        if (!c.in_use or c.state != .closed) return false;

        c.remote_ip = ip;
        c.remote_port = port;
        c.snd_una = self.nextSeq();
        c.snd_nxt = c.snd_una;

        self.sendSynPkt(c);
        c.snd_nxt = c.snd_una +% 1;
        c.state = .syn_sent;
        c.retransmit_tick = self.getTicksFn();
        c.retransmit_count = 0;

        self.hashInsert(idx);
        self.active_opens += 1;
        return true;
    }

    pub fn announce(self: *TcpStack, idx: u8, port: u16) bool {
        if (idx >= self.max_connections) return false;
        const c = &self.connections[idx];
        if (!c.in_use or c.state != .closed) return false;
        c.local_port = port;
        c.state = .listen;
        return true;
    }

    pub fn sendData(self: *TcpStack, idx: u8, data: []const u8) u16 {
        if (idx >= self.max_connections) return 0;
        const c = &self.connections[idx];
        if (c.state != .established and c.state != .close_wait) return 0;

        const available = TX_BUF_SIZE - c.tx_len;
        const to_send: u16 = @intCast(@min(data.len, available));
        if (to_send == 0) return 0;

        @memcpy(c.tx_buf[c.tx_len..][0..to_send], data[0..to_send]);
        c.tx_len += to_send;
        self.sendDataSegment(c);
        return to_send;
    }

    pub fn recvData(self: *TcpStack, idx: u8, buf: []u8) u16 {
        if (idx >= self.max_connections) return 0;
        const c = &self.connections[idx];
        if (c.rx_count == 0) return 0;

        const old_count = c.rx_count;
        const to_copy: u16 = @intCast(@min(buf.len, c.rx_count));
        const read_pos = (c.rx_head -% c.rx_count) % RX_BUF_SIZE;
        var i: u16 = 0;
        while (i < to_copy) : (i += 1) {
            buf[i] = c.rx_buf[(read_pos + i) % RX_BUF_SIZE];
        }
        c.rx_count -= to_copy;

        const was_full = old_count > RX_BUF_SIZE / 2;
        const now_has_room = c.rx_count <= RX_BUF_SIZE / 2;
        if (c.state == .established and was_full and now_has_room) {
            self.sendAckPkt(c);
        }
        return to_copy;
    }

    pub fn hasData(self: *const TcpStack, idx: u8) bool {
        if (idx >= self.max_connections) return false;
        return self.connections[idx].rx_count > 0;
    }

    pub fn isEof(self: *const TcpStack, idx: u8) bool {
        if (idx >= self.max_connections) return true;
        const c = &self.connections[idx];
        return c.state == .close_wait or c.state == .closing or
            c.state == .last_ack or c.state == .time_wait or c.state == .closed;
    }

    pub fn startClose(self: *TcpStack, idx: u8) void {
        if (idx >= self.max_connections) return;
        const c = &self.connections[idx];
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
                self.freeConn(c, idx);
            },
            .listen => {
                self.notifyWaiters(idx, .error_reset);
                self.freeConn(c, idx);
            },
            else => {},
        }
    }

    /// Process an incoming TCP segment (after IPv4 parsing).
    pub fn handlePacket(self: *TcpStack, payload: []const u8, ip_hdr: ipv4.Header) void {
        if (payload.len < HEADER_SIZE) return;
        self.segments_rx += 1;

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

        // Hash lookup for established connections
        if (self.hashLookup(dst_port, src_port, ip_hdr.src)) |idx| {
            const c = &self.connections[idx];
            if (c.in_use and c.local_port == dst_port and
                c.remote_port == src_port and
                ipv4.ipEqual(c.remote_ip, ip_hdr.src))
            {
                self.handleSegment(c, idx, seq_num, ack_num, flags, window, data);
                return;
            }
        }

        // Linear scan for listeners
        for (self.connections[0..self.max_connections], 0..) |*c, i| {
            if (c.in_use and c.state == .listen and c.local_port == dst_port) {
                self.handleListenSegment(c, @intCast(i), seq_num, flags, ip_hdr, src_port);
                return;
            }
        }

        // No match — send RST
        if (flags & RST == 0) {
            self.sendRstReply(ip_hdr.src, src_port, dst_port, seq_num, ack_num, flags, @intCast(data.len));
        }
    }

    /// Timer tick — retransmission and TIME_WAIT expiry.
    pub fn tick(self: *TcpStack, now: u32) void {
        for (self.connections[0..self.max_connections], 0..) |*c, i| {
            if (!c.in_use) continue;
            const idx: u8 = @intCast(i);

            switch (c.state) {
                .syn_sent => {
                    if (now -% c.retransmit_tick >= c.rto) {
                        if (c.retransmit_count >= MAX_RETRIES) {
                            self.notifyWaiters(idx, .error_reset);
                            self.freeConn(c, idx);
                        } else {
                            self.sendSynPkt(c);
                            c.retransmit_count += 1;
                            c.retransmit_tick = now;
                            c.rto *= 2;
                            self.retransmits += 1;
                        }
                    }
                },
                .established, .close_wait => {
                    if (c.tx_len > 0 and seqDiff(c.snd_nxt, c.snd_una) > 0) {
                        if (now -% c.retransmit_tick >= c.rto) {
                            if (c.retransmit_count >= MAX_RETRIES) {
                                self.notifyWaiters(idx, .error_reset);
                                self.sendRstPkt(c);
                                self.freeConn(c, idx);
                            } else {
                                self.sendDataSegment(c);
                                c.retransmit_count += 1;
                                c.retransmit_tick = now;
                                self.retransmits += 1;
                            }
                        }
                    }
                },
                .fin_wait_1, .last_ack, .closing => {
                    if (now -% c.retransmit_tick >= c.rto) {
                        if (c.retransmit_count >= MAX_RETRIES) {
                            self.freeConn(c, idx);
                        } else {
                            self.sendFinPkt(c);
                            c.retransmit_count += 1;
                            c.retransmit_tick = now;
                            self.retransmits += 1;
                        }
                    }
                },
                .time_wait => {
                    if (now -% c.retransmit_tick >= TIME_WAIT_TICKS) {
                        self.freeConn(c, idx);
                    }
                },
                else => {},
            }
        }
    }

    // ── Internal ────────────────────────────────────────────────

    fn handleSegment(self: *TcpStack, c: *Connection, idx: u8, seq: u32, ack: u32, flags: u8, window: u16, data: []const u8) void {
        if (flags & RST != 0) {
            self.notifyWaiters(idx, .error_reset);
            self.freeConn(c, idx);
            return;
        }

        switch (c.state) {
            .syn_sent => {
                if (flags & SYN != 0 and flags & ACK != 0 and ack == c.snd_nxt) {
                    c.rcv_nxt = seq +% 1;
                    c.snd_una = ack;
                    c.snd_wnd = window;
                    c.state = .established;
                    c.retransmit_count = 0;
                    c.rto = INITIAL_RTO;
                    c.tx_len = 0;
                    self.sendAckPkt(c);
                    self.notifyWaiters(idx, .connect_done);
                }
            },
            .syn_received => {
                if (flags & ACK != 0 and ack == c.snd_nxt) {
                    c.snd_una = ack;
                    c.snd_wnd = window;
                    c.state = .established;
                    c.retransmit_count = 0;
                    c.rto = INITIAL_RTO;
                    if (c.parent_idx != 0xFF and c.parent_idx < self.max_connections) {
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
                    self.freeConn(c, idx);
                }
            },
            .close_wait => {
                if (flags & ACK != 0) self.processAck(c, ack, window);
            },
            else => {},
        }
    }

    fn handleEstablished(self: *TcpStack, c: *Connection, idx: u8, seq: u32, ack: u32, flags: u8, window: u16, data: []const u8) void {
        if (flags & ACK != 0) self.processAck(c, ack, window);

        if (data.len > 0) {
            if (seq == c.rcv_nxt) {
                const space = RX_BUF_SIZE - c.rx_count;
                const to_buf: u16 = @intCast(@min(data.len, space));
                var i: u16 = 0;
                while (i < to_buf) : (i += 1) {
                    c.rx_buf[c.rx_head] = data[i];
                    c.rx_head = (c.rx_head + 1) % RX_BUF_SIZE;
                }
                c.rx_count += to_buf;
                c.rcv_nxt +%= @as(u32, to_buf);
                self.notifyWaiters(idx, .data_ready);
            }
            self.sendAckPkt(c);
        }

        if (flags & FIN != 0) {
            if (seq == c.rcv_nxt or (data.len > 0 and seq +% @as(u32, @intCast(data.len)) == c.rcv_nxt)) {
                c.rcv_nxt +%= 1;
            }
            self.sendAckPkt(c);
            c.state = .close_wait;
            self.notifyWaiters(idx, .eof);
        }
    }

    fn processAck(self: *TcpStack, c: *Connection, ack: u32, window: u16) void {
        c.snd_wnd = window;
        if (seqDiff(ack, c.snd_una) > 0 and seqDiff(ack, c.snd_nxt) <= 0) {
            const acked = ack -% c.snd_una;
            c.snd_una = ack;
            if (acked <= c.tx_len) {
                const remaining = c.tx_len - @as(u16, @intCast(acked));
                if (remaining > 0) {
                    var i: u16 = 0;
                    while (i < remaining) : (i += 1) {
                        c.tx_buf[i] = c.tx_buf[@as(u16, @intCast(acked)) + i];
                    }
                }
                c.tx_len = remaining;
            } else {
                c.tx_len = 0;
            }
            c.retransmit_count = 0;
            c.rto = INITIAL_RTO;
            c.retransmit_tick = self.getTicksFn();
        }
    }

    fn handleListenSegment(self: *TcpStack, listener: *Connection, listener_idx: u8, seq: u32, flags: u8, ip_hdr: ipv4.Header, src_port: u16) void {
        if (flags & SYN == 0 or flags & ACK != 0 or flags & RST != 0) return;

        const child_idx = self.alloc() orelse return;
        const child = &self.connections[child_idx];
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
        self.sendFlagsPkt(child, SYN | ACK, child.snd_una);
        self.passive_opens += 1;
    }

    // ── Segment building ────────────────────────────────────────

    fn sendSynPkt(self: *TcpStack, c: *Connection) void {
        self.sendFlagsPkt(c, SYN, c.snd_una);
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
        const window = RX_BUF_SIZE - c.rx_count;
        buildHeader(&tcp_buf, c.local_port, c.remote_port, seq, c.rcv_nxt, flags, window, 0);
        const cksum = tcpChecksum(c.local_ip, c.remote_ip, &tcp_buf);
        ipv4.writeBe16(&tcp_buf, 16, cksum);
        self.sendFn(c.remote_ip, &tcp_buf);
        self.segments_tx += 1;
    }

    fn sendDataSegment(self: *TcpStack, c: *Connection) void {
        if (c.tx_len == 0) return;
        const send_len: u16 = @intCast(@min(c.tx_len, c.mss));
        var tcp_buf: [HEADER_SIZE + TX_BUF_SIZE]u8 = undefined;
        const total_len = HEADER_SIZE + send_len;
        const window = RX_BUF_SIZE - c.rx_count;
        buildHeader(tcp_buf[0..HEADER_SIZE], c.local_port, c.remote_port, c.snd_una, c.rcv_nxt, ACK | PSH, window, 0);
        @memcpy(tcp_buf[HEADER_SIZE..][0..send_len], c.tx_buf[0..send_len]);
        const cksum = tcpChecksum(c.local_ip, c.remote_ip, tcp_buf[0..total_len]);
        ipv4.writeBe16(&tcp_buf, 16, cksum);
        c.snd_nxt = c.snd_una +% @as(u32, send_len);
        c.retransmit_tick = self.getTicksFn();
        self.sendFn(c.remote_ip, tcp_buf[0..total_len]);
        self.segments_tx += 1;
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
        const cksum = tcpChecksum(our_ip, dst_ip, &tcp_buf);
        ipv4.writeBe16(&tcp_buf, 16, cksum);
        self.sendFn(dst_ip, &tcp_buf);
    }

    // ── Hash table ──────────────────────────────────────────────

    fn hashInsert(self: *TcpStack, idx: u8) void {
        const c = &self.connections[idx];
        const bucket = connHashFn(c.local_port, c.remote_port, c.remote_ip);
        c.hash_next = self.conn_hash[bucket];
        self.conn_hash[bucket] = idx;
    }

    fn hashRemove(self: *TcpStack, idx: u8) void {
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

    fn hashLookup(self: *const TcpStack, local_port: u16, remote_port: u16, remote_ip: [4]u8) ?u8 {
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

    fn freeConn(self: *TcpStack, c: *Connection, idx: u8) void {
        self.hashRemove(idx);
        resetConn(c);
    }

    fn notifyWaiters(self: *TcpStack, idx: u8, event: WaiterEvent) void {
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
        if (self.next_ephemeral_port < 49152) self.next_ephemeral_port = 49152;
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
    c.rx_head = 0;
    c.rx_count = 0;
    c.tx_len = 0;
    c.retransmit_tick = 0;
    c.retransmit_count = 0;
    c.rto = INITIAL_RTO;
    c.parent_idx = 0xFF;
}

fn connHashFn(local_port: u16, remote_port: u16, remote_ip: [4]u8) u8 {
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
