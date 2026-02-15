/// TCP: Transmission Control Protocol (RFC 793).
///
/// Minimal TCP implementation with connection state machine, retransmission,
/// and ring buffers. Supports connect, listen, send, and receive.
const ipv4 = @import("ipv4.zig");
const serial = @import("../serial.zig");
const timer = @import("../timer.zig");
const process = @import("../process.zig");

const HEADER_SIZE = 20; // no options
const MAX_CONNECTIONS = 16;
const RX_BUF_SIZE = 4096;
const TX_BUF_SIZE = 4096;
const DEFAULT_MSS: u16 = 1460;
const DEFAULT_WINDOW: u16 = 4096;
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

pub const Connection = struct {
    state: TcpState,
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
    // Blocked process tracking
    read_waiter_pid: u16,
    connect_waiter_pid: u16,
    listen_waiter_pid: u16,
    // Listener parent index (for connections spawned by accept)
    parent_idx: u8,
    in_use: bool,
};

/// Connections array — must be in BSS to avoid bloating .data
var connections: [MAX_CONNECTIONS]Connection linksection(".bss") = undefined;
var next_ephemeral_port: u16 = 49152;
var seq_counter: u32 = 1000;

// Forward-declare the net module for sending
const net = @import("../net.zig");

pub fn init() void {
    for (&connections) |*c| {
        c.* = emptyConn();
    }
}

fn emptyConn() Connection {
    return Connection{
        .state = .closed,
        .local_port = 0,
        .remote_port = 0,
        .local_ip = .{ 0, 0, 0, 0 },
        .remote_ip = .{ 0, 0, 0, 0 },
        .snd_una = 0,
        .snd_nxt = 0,
        .rcv_nxt = 0,
        .snd_wnd = DEFAULT_WINDOW,
        .mss = DEFAULT_MSS,
        .rx_buf = undefined,
        .rx_head = 0,
        .rx_count = 0,
        .tx_buf = undefined,
        .tx_len = 0,
        .retransmit_tick = 0,
        .retransmit_count = 0,
        .rto = INITIAL_RTO,
        .read_waiter_pid = 0,
        .connect_waiter_pid = 0,
        .listen_waiter_pid = 0,
        .parent_idx = 0xFF,
        .in_use = false,
    };
}

/// Allocate a new TCP connection slot.
pub fn alloc() ?u8 {
    for (&connections, 0..) |*c, i| {
        if (!c.in_use) {
            c.* = emptyConn();
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
    if (!connections[idx].in_use) return null;
    return connections[idx].state;
}

/// Get connection's local port and IP.
pub fn getLocal(idx: u8) ?struct { ip: [4]u8, port: u16 } {
    if (idx >= MAX_CONNECTIONS) return null;
    if (!connections[idx].in_use) return null;
    return .{ .ip = connections[idx].local_ip, .port = connections[idx].local_port };
}

/// Get connection's remote port and IP.
pub fn getRemote(idx: u8) ?struct { ip: [4]u8, port: u16 } {
    if (idx >= MAX_CONNECTIONS) return null;
    if (!connections[idx].in_use) return null;
    return .{ .ip = connections[idx].remote_ip, .port = connections[idx].remote_port };
}

/// Initiate a TCP connection (active open).
pub fn connect(idx: u8, ip: [4]u8, port: u16) bool {
    if (idx >= MAX_CONNECTIONS) return false;
    const c = &connections[idx];
    if (!c.in_use or c.state != .closed) return false;

    c.remote_ip = ip;
    c.remote_port = port;
    c.snd_una = nextSeq();
    c.snd_nxt = c.snd_una;

    // Send SYN
    sendSyn(c);
    c.snd_nxt = c.snd_una +% 1; // SYN consumes one sequence number
    c.state = .syn_sent;
    c.retransmit_tick = timer.getTicks();
    c.retransmit_count = 0;

    serial.puts("tcp: SYN sent to ");
    net.printIpSerial(ip);
    serial.puts(":");
    serial.putDec(port);
    serial.puts("\n");
    return true;
}

/// Set up a listening socket (passive open).
pub fn announce(idx: u8, port: u16) bool {
    if (idx >= MAX_CONNECTIONS) return false;
    const c = &connections[idx];
    if (!c.in_use or c.state != .closed) return false;

    c.local_port = port;
    c.state = .listen;

    serial.puts("tcp: listening on port ");
    serial.putDec(port);
    serial.puts("\n");
    return true;
}

/// Queue data for transmission on an established connection.
pub fn sendData(idx: u8, data: []const u8) u16 {
    if (idx >= MAX_CONNECTIONS) return 0;
    const c = &connections[idx];
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
    if (c.rx_count == 0) return 0;

    const to_copy: u16 = @intCast(@min(buf.len, c.rx_count));
    // Read from ring buffer — head points to the write position,
    // read position = head - count (wrapped)
    const read_pos = (c.rx_head -% c.rx_count) % RX_BUF_SIZE;

    var i: u16 = 0;
    while (i < to_copy) : (i += 1) {
        buf[i] = c.rx_buf[(read_pos + i) % RX_BUF_SIZE];
    }
    c.rx_count -= to_copy;
    return to_copy;
}

/// Check if connection has data available to read.
pub fn hasData(idx: u8) bool {
    if (idx >= MAX_CONNECTIONS) return false;
    return connections[idx].rx_count > 0;
}

/// Check if connection is in a state where no more data will arrive (EOF).
pub fn isEof(idx: u8) bool {
    if (idx >= MAX_CONNECTIONS) return true;
    const c = &connections[idx];
    return c.state == .close_wait or c.state == .closing or
        c.state == .last_ack or c.state == .time_wait or c.state == .closed;
}

/// Initiate a graceful close (send FIN).
pub fn startClose(idx: u8) void {
    if (idx >= MAX_CONNECTIONS) return;
    const c = &connections[idx];

    switch (c.state) {
        .established => {
            sendFin(c);
            c.state = .fin_wait_1;
        },
        .close_wait => {
            sendFin(c);
            c.state = .last_ack;
        },
        .syn_sent, .syn_received => {
            // Abort
            sendRst(c);
            freeConn(c);
        },
        .listen => {
            freeConn(c);
        },
        else => {},
    }
}

/// Register a waiter for read (blocks until data arrives).
pub fn setReadWaiter(idx: u8, pid: u16) void {
    if (idx >= MAX_CONNECTIONS) return;
    connections[idx].read_waiter_pid = pid;
}

/// Register a waiter for connect completion.
pub fn setConnectWaiter(idx: u8, pid: u16) void {
    if (idx >= MAX_CONNECTIONS) return;
    connections[idx].connect_waiter_pid = pid;
}

/// Register a waiter for listen/accept.
pub fn setListenWaiter(idx: u8, pid: u16) void {
    if (idx >= MAX_CONNECTIONS) return;
    connections[idx].listen_waiter_pid = pid;
}

/// Process an incoming TCP segment.
pub fn handlePacket(payload: []const u8, ip_hdr: ipv4.Header) void {
    if (payload.len < HEADER_SIZE) return;

    serial.puts("tcp: rx from ");
    net.printIpSerial(ip_hdr.src);
    serial.puts("\n");

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

    // Verify TCP checksum
    if (!verifyChecksum(payload, ip_hdr)) {
        serial.puts("tcp: bad checksum\n");
        return;
    }

    const data = payload[data_offset..];

    // Demux: find matching connection
    // First try established/in-progress connections
    for (&connections, 0..) |*c, i| {
        if (!c.in_use) continue;
        if (c.state == .listen) continue; // check listeners separately
        if (c.local_port != dst_port) continue;
        if (c.remote_port != src_port) continue;
        if (!ipv4.ipEqual(c.remote_ip, ip_hdr.src)) continue;

        handleSegment(c, @intCast(i), seq_num, ack_num, flags, window, data, ip_hdr);
        return;
    }

    // Try listeners
    for (&connections, 0..) |*c, i| {
        if (!c.in_use) continue;
        if (c.state != .listen) continue;
        if (c.local_port != dst_port) continue;

        handleListenSegment(c, @intCast(i), seq_num, flags, ip_hdr, src_port);
        return;
    }

    // No matching connection — send RST if it's not already a RST
    if (flags & RST == 0) {
        sendRstReply(ip_hdr.src, src_port, dst_port, seq_num, ack_num, flags, @intCast(data.len));
    }
}

/// Timer tick — check retransmission timers and TIME_WAIT expiry.
pub fn tick(now: u32) void {
    for (&connections) |*c| {
        if (!c.in_use) continue;

        switch (c.state) {
            .syn_sent => {
                if (now -% c.retransmit_tick >= c.rto) {
                    if (c.retransmit_count >= MAX_RETRIES) {
                        serial.puts("tcp: connect timeout\n");
                        wakeWaiter(&c.connect_waiter_pid, true);
                        freeConn(c);
                    } else {
                        // Retransmit SYN
                        serial.puts("tcp: retransmit SYN #");
                        serial.putDec(c.retransmit_count + 1);
                        serial.puts("\n");
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
                            serial.puts("tcp: retransmit timeout\n");
                            wakeWaiter(&c.read_waiter_pid, true);
                            sendRst(c);
                            freeConn(c);
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
                        freeConn(c);
                    } else {
                        sendFin(c);
                        c.retransmit_count += 1;
                        c.retransmit_tick = now;
                    }
                }
            },
            .time_wait => {
                if (now -% c.retransmit_tick >= TIME_WAIT_TICKS) {
                    freeConn(c);
                }
            },
            else => {},
        }
    }
}

// ── Internal helpers ────────────────────────────────────────────────

fn handleSegment(c: *Connection, idx: u8, seq: u32, ack: u32, flags: u8, window: u16, data: []const u8, ip_hdr: ipv4.Header) void {
    _ = ip_hdr;
    _ = idx;

    // RST handling — always process
    if (flags & RST != 0) {
        serial.puts("tcp: received RST\n");
        wakeWaiter(&c.connect_waiter_pid, true);
        wakeWaiter(&c.read_waiter_pid, true);
        wakeWaiter(&c.listen_waiter_pid, true);
        freeConn(c);
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
                    serial.puts("tcp: connected\n");
                    wakeWaiter(&c.connect_waiter_pid, false);
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
                serial.puts("tcp: accept complete\n");
                // Wake the listener's waiter
                if (c.parent_idx != 0xFF and c.parent_idx < MAX_CONNECTIONS) {
                    wakeWaiter(&connections[c.parent_idx].listen_waiter_pid, false);
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
                freeConn(c);
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

            // Wake read waiter
            wakeWaiter(&c.read_waiter_pid, false);
        }
        // Send ACK (even for out-of-order to trigger fast retransmit on remote)
        sendAck(c);
    }

    // Process FIN
    if (flags & FIN != 0) {
        c.rcv_nxt = seq +% @as(u32, @intCast(data.len)) +% 1;
        sendAck(c);
        c.state = .close_wait;
        // Wake reader with EOF
        wakeWaiter(&c.read_waiter_pid, false);
        serial.puts("tcp: remote closed (FIN)\n");
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

fn handleListenSegment(listener: *Connection, listener_idx: u8, seq: u32, flags: u8, ip_hdr: ipv4.Header, src_port: u16) void {
    if (flags & SYN == 0) return; // Only SYN expected on listener
    if (flags & ACK != 0) return; // SYN must not have ACK
    if (flags & RST != 0) return;

    // Allocate a child connection
    const child_idx = alloc() orelse {
        serial.puts("tcp: listen: no free connections\n");
        return;
    };
    const child = &connections[child_idx];
    child.local_port = listener.local_port;
    child.local_ip = listener.local_ip;
    child.remote_ip = ip_hdr.src;
    child.remote_port = src_port;
    child.rcv_nxt = seq +% 1;
    child.snd_una = nextSeq();
    child.snd_nxt = child.snd_una +% 1;
    child.state = .syn_received;
    child.parent_idx = listener_idx;
    child.retransmit_tick = timer.getTicks();

    // Send SYN+ACK
    sendFlags(child, SYN | ACK, child.snd_una);

    serial.puts("tcp: SYN+ACK sent to ");
    net.printIpSerial(ip_hdr.src);
    serial.puts(":");
    serial.putDec(src_port);
    serial.puts(" (child conn ");
    serial.putDec(child_idx);
    serial.puts(")\n");
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
    buildHeader(&tcp_buf, c.local_port, c.remote_port, seq, c.rcv_nxt, flags, DEFAULT_WINDOW, 0);

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

    buildHeader(tcp_buf[0..HEADER_SIZE], c.local_port, c.remote_port, c.snd_una, c.rcv_nxt, ACK | PSH, DEFAULT_WINDOW, 0);

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

fn freeConn(c: *Connection) void {
    c.* = emptyConn();
}

fn wakeWaiter(waiter_pid: *u16, is_error: bool) void {
    if (waiter_pid.* == 0) return;
    const pid = waiter_pid.*;
    waiter_pid.* = 0;

    if (process.getByPid(pid)) |proc| {
        if (proc.state == .blocked) {
            if (is_error) {
                proc.syscall_ret = 0xFFFF_FFFF_FFFF_FFF2; // -ECONNRESET equivalent
            }
            proc.state = .ready;
        }
    }
}

// ── Sequence number helpers ─────────────────────────────────────────

fn seqDiff(a: u32, b: u32) i32 {
    return @as(i32, @bitCast(a -% b));
}

fn nextSeq() u32 {
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
