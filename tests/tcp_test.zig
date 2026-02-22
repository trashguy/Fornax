const std = @import("std");
const tcp = @import("tcp");
const ipv4 = @import("ipv4");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

// ── Mock callbacks (global state for fn ptr compatibility) ──────────

var mock_send_buf: [4096]u8 = undefined;
var mock_send_len: usize = 0;
var mock_send_dst: [4]u8 = .{ 0, 0, 0, 0 };
var mock_send_count: u32 = 0;
var mock_tick_count: u32 = 0;

const OUR_IP = [_]u8{ 10, 0, 2, 15 };
const REMOTE_IP = [_]u8{ 93, 184, 216, 34 };

fn mockSend(dst_ip: [4]u8, tcp_segment: []const u8) void {
    mock_send_dst = dst_ip;
    const len = @min(tcp_segment.len, mock_send_buf.len);
    @memcpy(mock_send_buf[0..len], tcp_segment[0..len]);
    mock_send_len = len;
    mock_send_count += 1;
}

fn mockGetIp() [4]u8 {
    return OUR_IP;
}

fn mockGetTicks() u32 {
    return mock_tick_count;
}

fn resetMock() void {
    mock_send_len = 0;
    mock_send_count = 0;
    mock_tick_count = 0;
    mock_send_dst = .{ 0, 0, 0, 0 };
}

// TcpStack is ~5MB, use heap allocation for tests
fn createStack() !*tcp.TcpStack {
    const allocator = std.testing.allocator;
    const stack = try allocator.create(tcp.TcpStack);
    stack.* = tcp.TcpStack.init(&mockSend, &mockGetIp, &mockGetTicks);
    stack.setMaxConnections(8); // small for testing
    return stack;
}

fn destroyStack(stack: *tcp.TcpStack) void {
    std.testing.allocator.destroy(stack);
}

// ── alloc / free lifecycle ──────────────────────────────────────────

test "alloc returns connection index" {
    resetMock();
    const stack = try createStack();
    defer destroyStack(stack);

    const idx = stack.alloc() orelse return error.TestUnexpectedResult;
    try expect(stack.connections[idx].in_use);
    try expectEqual(tcp.TcpState.closed, stack.getState(idx).?);
}

test "alloc exhaustion" {
    resetMock();
    const stack = try createStack();
    defer destroyStack(stack);

    // Alloc all 8
    for (0..8) |_| {
        try expect(stack.alloc() != null);
    }
    // Should be full
    try expect(stack.alloc() == null);
}

// ── connect sends SYN ───────────────────────────────────────────────

test "connect sends SYN packet" {
    resetMock();
    const stack = try createStack();
    defer destroyStack(stack);

    const idx = stack.alloc() orelse return error.TestUnexpectedResult;
    try expect(stack.connect(idx, REMOTE_IP, 80));

    try expectEqual(tcp.TcpState.syn_sent, stack.getState(idx).?);
    try expect(mock_send_count > 0);
    try expectEqualSlices(u8, &REMOTE_IP, &mock_send_dst);

    // Verify SYN flag in sent packet
    try expect(mock_send_len >= tcp.HEADER_SIZE);
    const flags = mock_send_buf[13];
    try expectEqual(tcp.SYN, flags);
}

test "connect on non-closed connection fails" {
    resetMock();
    const stack = try createStack();
    defer destroyStack(stack);

    const idx = stack.alloc() orelse return error.TestUnexpectedResult;
    _ = stack.connect(idx, REMOTE_IP, 80);
    // Already in syn_sent, should fail
    try expect(!stack.connect(idx, .{ 1, 2, 3, 4 }, 8080));
}

// ── handlePacket: SYN-ACK → ESTABLISHED ─────────────────────────────

test "SYN-ACK transitions to established" {
    resetMock();
    const stack = try createStack();
    defer destroyStack(stack);

    const idx = stack.alloc() orelse return error.TestUnexpectedResult;
    try expect(stack.connect(idx, REMOTE_IP, 80));

    const c = &stack.connections[idx];
    const our_seq = c.snd_una;
    const expected_ack = our_seq +% 1;

    // Build SYN-ACK response
    const server_seq: u32 = 5000;
    var synack_buf: [tcp.HEADER_SIZE]u8 = undefined;
    buildTcpHeader(&synack_buf, 80, c.local_port, server_seq, expected_ack, tcp.SYN | tcp.ACK, 65535);

    // Compute and set TCP checksum
    const cksum = tcp.tcpChecksum(REMOTE_IP, OUR_IP, &synack_buf);
    ipv4.writeBe16(&synack_buf, 16, cksum);

    const ip_hdr = makeIpHdr(REMOTE_IP, OUR_IP);

    mock_send_count = 0;
    stack.handlePacket(&synack_buf, ip_hdr);

    try expectEqual(tcp.TcpState.established, stack.getState(idx).?);
    // Should have sent an ACK
    try expect(mock_send_count > 0);
}

// ── sendData / recvData buffer management ───────────────────────────

test "sendData and recvData" {
    resetMock();
    const stack = try createStack();
    defer destroyStack(stack);

    const idx = stack.alloc() orelse return error.TestUnexpectedResult;
    try expect(stack.connect(idx, REMOTE_IP, 80));

    // Transition to established
    transitionToEstablished(stack, idx);

    // Send data
    const sent = stack.sendData(idx, "hello");
    try expectEqual(@as(u16, 5), sent);
    try expect(mock_send_count > 0);
}

test "sendData on non-established returns 0" {
    resetMock();
    const stack = try createStack();
    defer destroyStack(stack);

    const idx = stack.alloc() orelse return error.TestUnexpectedResult;
    // Still in closed state
    try expectEqual(@as(u16, 0), stack.sendData(idx, "hello"));
}

// ── announce (listen) ───────────────────────────────────────────────

test "announce transitions to listen" {
    resetMock();
    const stack = try createStack();
    defer destroyStack(stack);

    const idx = stack.alloc() orelse return error.TestUnexpectedResult;
    try expect(stack.announce(idx, 8080));
    try expectEqual(tcp.TcpState.listen, stack.getState(idx).?);
}

test "announce on non-closed fails" {
    resetMock();
    const stack = try createStack();
    defer destroyStack(stack);

    const idx = stack.alloc() orelse return error.TestUnexpectedResult;
    _ = stack.connect(idx, REMOTE_IP, 80);
    try expect(!stack.announce(idx, 8080));
}

// ── listen + SYN accept flow ────────────────────────────────────────

test "listen accepts incoming SYN" {
    resetMock();
    const stack = try createStack();
    defer destroyStack(stack);

    const listener_idx = stack.alloc() orelse return error.TestUnexpectedResult;
    try expect(stack.announce(listener_idx, 8080));

    // Build incoming SYN
    const client_seq: u32 = 12345;
    const client_ip = [_]u8{ 192, 168, 1, 100 };
    const client_port: u16 = 50000;

    var syn_buf: [tcp.HEADER_SIZE]u8 = undefined;
    buildTcpHeader(&syn_buf, client_port, 8080, client_seq, 0, tcp.SYN, 65535);

    const cksum = tcp.tcpChecksum(client_ip, OUR_IP, &syn_buf);
    ipv4.writeBe16(&syn_buf, 16, cksum);

    const ip_hdr = makeIpHdr(client_ip, OUR_IP);

    mock_send_count = 0;
    stack.handlePacket(&syn_buf, ip_hdr);

    // Should have allocated a child connection and sent SYN-ACK
    try expect(mock_send_count > 0);

    // Verify SYN-ACK was sent
    try expect(mock_send_len >= tcp.HEADER_SIZE);
    const flags = mock_send_buf[13];
    try expectEqual(tcp.SYN | tcp.ACK, flags);

    // Listener should still be in listen state
    try expectEqual(tcp.TcpState.listen, stack.getState(listener_idx).?);
}

// ── tick: retransmission ────────────────────────────────────────────

test "tick retransmits SYN after timeout" {
    resetMock();
    const stack = try createStack();
    defer destroyStack(stack);

    const idx = stack.alloc() orelse return error.TestUnexpectedResult;
    try expect(stack.connect(idx, REMOTE_IP, 80));

    const initial_sends = mock_send_count;
    mock_tick_count = tcp.INITIAL_RTO + 1;
    stack.tick(mock_tick_count);

    try expect(mock_send_count > initial_sends);
}

test "tick: max retries resets connection" {
    resetMock();
    const stack = try createStack();
    defer destroyStack(stack);

    const idx = stack.alloc() orelse return error.TestUnexpectedResult;
    try expect(stack.connect(idx, REMOTE_IP, 80));

    // Exhaust retries — RTO starts at INITIAL_RTO and doubles each retry.
    // Each tick() call reads getTicksFn() for the new retransmit_tick, so
    // we need mock_tick_count to advance in sync with the tick argument.
    var tick: u32 = 0;
    var rto: u32 = tcp.INITIAL_RTO;
    for (0..tcp.MAX_RETRIES + 1) |_| {
        tick += rto + 1;
        mock_tick_count = tick;
        stack.tick(tick);
        rto *= 2;
    }

    // Connection should be freed
    try expect(!stack.connections[idx].in_use);
}

// ── hasData / isEof ─────────────────────────────────────────────────

test "hasData returns false on empty rx buffer" {
    resetMock();
    const stack = try createStack();
    defer destroyStack(stack);

    const idx = stack.alloc() orelse return error.TestUnexpectedResult;
    try expect(!stack.hasData(idx));
}

test "isEof on closed connection" {
    resetMock();
    const stack = try createStack();
    defer destroyStack(stack);

    const idx = stack.alloc() orelse return error.TestUnexpectedResult;
    // Closed state counts as EOF
    try expect(stack.isEof(idx));
}

// ── tcpChecksum ─────────────────────────────────────────────────────

test "tcpChecksum: verify round-trip" {
    // Build a TCP segment, compute checksum, verify it validates to 0
    var seg: [tcp.HEADER_SIZE]u8 = undefined;
    buildTcpHeader(&seg, 12345, 80, 1000, 2000, tcp.ACK, 65535);

    const cksum = tcp.tcpChecksum(OUR_IP, REMOTE_IP, &seg);
    ipv4.writeBe16(&seg, 16, cksum);

    // Verification: checksum of the complete segment should be 0
    try expectEqual(@as(u16, 0), tcp.tcpChecksum(OUR_IP, REMOTE_IP, &seg));
}

// ── Helper functions ────────────────────────────────────────────────

fn buildTcpHeader(buf: *[tcp.HEADER_SIZE]u8, src_port: u16, dst_port: u16, seq: u32, ack: u32, flags: u8, window: u16) void {
    ipv4.writeBe16(buf, 0, src_port);
    ipv4.writeBe16(buf, 2, dst_port);
    ipv4.writeBe32(buf, 4, seq);
    ipv4.writeBe32(buf, 8, ack);
    buf[12] = 0x50; // data offset = 5 (20 bytes)
    buf[13] = flags;
    ipv4.writeBe16(buf, 14, window);
    ipv4.writeBe16(buf, 16, 0); // checksum placeholder
    ipv4.writeBe16(buf, 18, 0); // urgent pointer
}

fn makeIpHdr(src: [4]u8, dst: [4]u8) ipv4.Header {
    return .{
        .version_ihl = 0x45,
        .tos = 0,
        .total_length = 40,
        .identification = 0,
        .flags_fragment = 0,
        .ttl = 64,
        .protocol = ipv4.PROTO_TCP,
        .checksum = 0,
        .src = src,
        .dst = dst,
    };
}

fn transitionToEstablished(stack: *tcp.TcpStack, idx: u8) void {
    const c = &stack.connections[idx];
    const our_seq = c.snd_una;
    const expected_ack = our_seq +% 1;
    const server_seq: u32 = 5000;

    var synack_buf: [tcp.HEADER_SIZE]u8 = undefined;
    buildTcpHeader(&synack_buf, c.remote_port, c.local_port, server_seq, expected_ack, tcp.SYN | tcp.ACK, 65535);
    const cksum = tcp.tcpChecksum(c.remote_ip, c.local_ip, &synack_buf);
    ipv4.writeBe16(&synack_buf, 16, cksum);

    const ip_hdr = makeIpHdr(c.remote_ip, c.local_ip);
    stack.handlePacket(&synack_buf, ip_hdr);
}
