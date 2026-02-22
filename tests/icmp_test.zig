const std = @import("std");
const icmp = @import("icmp");
const ipv4 = @import("ipv4");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

// ── Mock callbacks ──────────────────────────────────────────────────

const MockCtx = struct {
    time_ms: u64 = 0,
    last_dst_ip: [4]u8 = .{ 0, 0, 0, 0 },
    last_packet: [1600]u8 = undefined,
    last_packet_len: usize = 0,
    send_count: u32 = 0,
};

fn mockSendIp(ctx_raw: *anyopaque, dst_ip: [4]u8, ip_packet: []const u8) void {
    const ctx: *MockCtx = @ptrCast(@alignCast(ctx_raw));
    ctx.last_dst_ip = dst_ip;
    const len = @min(ip_packet.len, ctx.last_packet.len);
    @memcpy(ctx.last_packet[0..len], ip_packet[0..len]);
    ctx.last_packet_len = len;
    ctx.send_count += 1;
}

fn mockGetTime(ctx_raw: *anyopaque) u64 {
    const ctx: *MockCtx = @ptrCast(@alignCast(ctx_raw));
    return ctx.time_ms;
}

const OUR_IP = [_]u8{ 10, 0, 2, 15 };
const REMOTE_IP = [_]u8{ 8, 8, 8, 8 };

fn makeHandler(ctx: *MockCtx) icmp.IcmpHandler {
    return icmp.IcmpHandler.init(&mockSendIp, &mockGetTime, @ptrCast(ctx));
}

// ── alloc / close lifecycle ─────────────────────────────────────────

test "alloc and close" {
    var ctx = MockCtx{};
    var handler = makeHandler(&ctx);

    const idx = handler.alloc() orelse return error.TestUnexpectedResult;
    try expect(handler.connections[idx].in_use);
    handler.close(idx);
    try expect(!handler.connections[idx].in_use);
}

test "alloc exhaustion" {
    var ctx = MockCtx{};
    var handler = makeHandler(&ctx);

    var slots: [icmp.MAX_CONNECTIONS]u8 = undefined;
    for (0..icmp.MAX_CONNECTIONS) |i| {
        slots[i] = handler.alloc() orelse return error.TestUnexpectedResult;
    }
    // Should be full
    try expect(handler.alloc() == null);

    // Free one and re-alloc
    handler.close(slots[0]);
    try expect(handler.alloc() != null);
}

// ── sendEchoRequest ─────────────────────────────────────────────────

test "sendEchoRequest sends IP packet" {
    var ctx = MockCtx{};
    var handler = makeHandler(&ctx);

    const idx = handler.alloc() orelse return error.TestUnexpectedResult;
    handler.setDst(idx, REMOTE_IP);

    try expect(handler.sendEchoRequest(idx, OUR_IP));
    try expectEqual(@as(u32, 1), ctx.send_count);
    try expectEqual(REMOTE_IP, ctx.last_dst_ip);
    try expectEqual(@as(u32, 1), handler.stats.echo_requests_tx);
}

test "sendEchoRequest on invalid index" {
    var ctx = MockCtx{};
    var handler = makeHandler(&ctx);
    try expect(!handler.sendEchoRequest(icmp.MAX_CONNECTIONS, OUR_IP));
}

// ── handlePacket: echo reply matching ───────────────────────────────

test "handlePacket: echo reply sets got_reply" {
    var ctx = MockCtx{};
    var handler = makeHandler(&ctx);

    const idx = handler.alloc() orelse return error.TestUnexpectedResult;
    handler.setDst(idx, REMOTE_IP);
    _ = handler.sendEchoRequest(idx, OUR_IP);

    const echo_id = handler.connections[idx].echo_id;

    // Build an ICMP echo reply
    var reply_payload: [64]u8 = undefined;
    reply_payload[0] = icmp.TYPE_ECHO_REPLY;
    reply_payload[1] = 0;
    reply_payload[2] = 0;
    reply_payload[3] = 0;
    reply_payload[4] = @truncate(echo_id >> 8);
    reply_payload[5] = @truncate(echo_id);
    reply_payload[6] = 0; // seq hi
    reply_payload[7] = 0; // seq lo
    @memset(reply_payload[8..], 0x42);

    // Fix ICMP checksum
    const cksum = ipv4.computeChecksum(&reply_payload);
    reply_payload[2] = @truncate(cksum >> 8);
    reply_payload[3] = @truncate(cksum);

    const ip_hdr = ipv4.Header{
        .version_ihl = 0x45,
        .tos = 0,
        .total_length = 84,
        .identification = 0,
        .flags_fragment = 0,
        .ttl = 64,
        .protocol = ipv4.PROTO_ICMP,
        .checksum = 0,
        .src = REMOTE_IP,
        .dst = OUR_IP,
    };

    var reply_buf: [1600]u8 = undefined;
    _ = handler.handlePacket(&reply_payload, ip_hdr, OUR_IP, &reply_buf);

    try expect(handler.hasReply(idx));
    try expectEqual(@as(u32, 1), handler.stats.echo_replies_rx);
}

// ── handlePacket: echo request sends reply ──────────────────────────

test "handlePacket: echo request generates reply" {
    var ctx = MockCtx{};
    var handler = makeHandler(&ctx);

    // Build an ICMP echo request
    var req_payload: [64]u8 = undefined;
    req_payload[0] = icmp.TYPE_ECHO_REQUEST;
    req_payload[1] = 0;
    req_payload[2] = 0;
    req_payload[3] = 0;
    req_payload[4] = 0x12; // echo ID
    req_payload[5] = 0x34;
    req_payload[6] = 0;
    req_payload[7] = 1; // seq=1
    @memset(req_payload[8..], 0xAA);

    const cksum = ipv4.computeChecksum(&req_payload);
    req_payload[2] = @truncate(cksum >> 8);
    req_payload[3] = @truncate(cksum);

    const ip_hdr = ipv4.Header{
        .version_ihl = 0x45,
        .tos = 0,
        .total_length = 84,
        .identification = 0,
        .flags_fragment = 0,
        .ttl = 64,
        .protocol = ipv4.PROTO_ICMP,
        .checksum = 0,
        .src = REMOTE_IP,
        .dst = OUR_IP,
    };

    var reply_buf: [1600]u8 = undefined;
    const reply_len = handler.handlePacket(&req_payload, ip_hdr, OUR_IP, &reply_buf);

    try expect(reply_len != null);
    try expectEqual(@as(u32, 1), handler.stats.echo_requests_rx);
    try expectEqual(@as(u32, 1), handler.stats.echo_replies_tx);
}

// ── checkTimeouts ───────────────────────────────────────────────────

test "checkTimeouts: detects timeout" {
    var ctx = MockCtx{ .time_ms = 0 };
    var handler = makeHandler(&ctx);

    const idx = handler.alloc() orelse return error.TestUnexpectedResult;
    handler.setDst(idx, REMOTE_IP);
    _ = handler.sendEchoRequest(idx, OUR_IP);

    // Not timed out yet
    var timed_out_buf: [4]u8 = undefined;
    try expectEqual(@as(u8, 0), handler.checkTimeouts(&timed_out_buf));

    // Advance time past timeout (3000ms)
    ctx.time_ms = 4000;
    const count = handler.checkTimeouts(&timed_out_buf);
    try expectEqual(@as(u8, 1), count);
    try expectEqual(idx, timed_out_buf[0]);
    try expect(handler.isTimedOut(idx));
}
