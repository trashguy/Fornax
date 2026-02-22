const std = @import("std");
const dns = @import("dns");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

// ── Mock callbacks ──────────────────────────────────────────────────

const MockCtx = struct {
    time_ms: u64 = 0,
    last_dst_ip: [4]u8 = .{ 0, 0, 0, 0 },
    last_src_port: u16 = 0,
    last_dst_port: u16 = 0,
    last_packet: [512]u8 = undefined,
    last_packet_len: usize = 0,
    send_count: u32 = 0,
};

fn mockSendUdp(ctx_raw: *anyopaque, dst_ip: [4]u8, src_port: u16, dst_port: u16, data: []const u8) void {
    const ctx: *MockCtx = @ptrCast(@alignCast(ctx_raw));
    ctx.last_dst_ip = dst_ip;
    ctx.last_src_port = src_port;
    ctx.last_dst_port = dst_port;
    const len = @min(data.len, ctx.last_packet.len);
    @memcpy(ctx.last_packet[0..len], data[0..len]);
    ctx.last_packet_len = len;
    ctx.send_count += 1;
}

fn mockGetTime(ctx_raw: *anyopaque) u64 {
    const ctx: *MockCtx = @ptrCast(@alignCast(ctx_raw));
    return ctx.time_ms;
}

const NS_IP = [_]u8{ 8, 8, 8, 8 };
const BIND_PORT: u16 = 10053;

fn makeResolver(ctx: *MockCtx) dns.DnsResolver {
    return dns.DnsResolver.init(&mockSendUdp, &mockGetTime, @ptrCast(ctx), NS_IP, BIND_PORT);
}

// ── query sends DNS packet ──────────────────────────────────────────

test "query sends DNS A-record query" {
    var ctx = MockCtx{};
    var resolver = makeResolver(&ctx);

    const cached = resolver.query("example.com");
    try expect(!cached); // not cached, query sent

    try expectEqual(@as(u32, 1), ctx.send_count);
    try expectEqualSlices(u8, &NS_IP, &ctx.last_dst_ip);
    try expectEqual(BIND_PORT, ctx.last_src_port);
    try expectEqual(dns.DNS_PORT, ctx.last_dst_port);

    // Verify DNS packet structure
    const pkt = ctx.last_packet[0..ctx.last_packet_len];
    try expect(pkt.len >= 12);
    // Flags: 0x0100 (standard query, RD=1)
    try expectEqual(@as(u8, 0x01), pkt[2]);
    try expectEqual(@as(u8, 0x00), pkt[3]);
    // QDCOUNT = 1
    try expectEqual(@as(u8, 0), pkt[4]);
    try expectEqual(@as(u8, 1), pkt[5]);
}

test "query returns true for cached entry" {
    var ctx = MockCtx{};
    var resolver = makeResolver(&ctx);

    // First query
    _ = resolver.query("example.com");

    // Simulate DNS response with A record
    const response = buildDnsResponse(
        resolver.pending_qid,
        "example.com",
        .{ 93, 184, 216, 34 },
        300, // TTL
    );

    const ip = resolver.handleResponse(&response);
    try expect(ip != null);
    try expectEqualSlices(u8, &[_]u8{ 93, 184, 216, 34 }, &ip.?);

    // Second query should be cached
    const cached = resolver.query("example.com");
    try expect(cached);
    try expectEqual(@as(u32, 1), ctx.send_count); // no new send
}

// ── handleResponse ──────────────────────────────────────────────────

test "handleResponse: valid response caches entry" {
    var ctx = MockCtx{};
    var resolver = makeResolver(&ctx);

    _ = resolver.query("test.org");
    const qid = resolver.pending_qid;

    const response = buildDnsResponse(qid, "test.org", .{ 1, 2, 3, 4 }, 600);
    const ip = resolver.handleResponse(&response);

    try expect(ip != null);
    try expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, &ip.?);

    // Should be in cache now
    try expect(resolver.cacheLookup("test.org") != null);
}

test "handleResponse: wrong query ID returns null" {
    var ctx = MockCtx{};
    var resolver = makeResolver(&ctx);

    _ = resolver.query("test.org");

    // Use wrong QID
    const response = buildDnsResponse(0xFFFF, "test.org", .{ 1, 2, 3, 4 }, 600);
    try expect(resolver.handleResponse(&response) == null);
}

// ── cacheLookup ─────────────────────────────────────────────────────

test "cacheLookup: miss before any query" {
    var ctx = MockCtx{};
    var resolver = makeResolver(&ctx);
    try expect(resolver.cacheLookup("nothing.com") == null);
}

test "cacheLookup: expired entry returns null" {
    var ctx = MockCtx{ .time_ms = 0 };
    var resolver = makeResolver(&ctx);

    _ = resolver.query("expire.com");
    const qid = resolver.pending_qid;
    const response = buildDnsResponse(qid, "expire.com", .{ 5, 6, 7, 8 }, 10); // 10s TTL
    _ = resolver.handleResponse(&response);

    // Before expiry
    try expect(resolver.cacheLookup("expire.com") != null);

    // After expiry (10s = 10000ms, capped to 600s max but 10s < 600s)
    ctx.time_ms = 11000;
    try expect(resolver.cacheLookup("expire.com") == null);
}

// ── flushCache ──────────────────────────────────────────────────────

test "flushCache clears all" {
    var ctx = MockCtx{};
    var resolver = makeResolver(&ctx);

    _ = resolver.query("a.com");
    const response = buildDnsResponse(resolver.pending_qid, "a.com", .{ 1, 1, 1, 1 }, 300);
    _ = resolver.handleResponse(&response);

    try expect(resolver.cacheLookup("a.com") != null);
    resolver.flushCache();
    try expect(resolver.cacheLookup("a.com") == null);
}

// ── checkRetry ──────────────────────────────────────────────────────

test "checkRetry: retransmits after timeout" {
    var ctx = MockCtx{ .time_ms = 0 };
    var resolver = makeResolver(&ctx);

    _ = resolver.query("retry.com");
    try expectEqual(@as(u32, 1), ctx.send_count);

    // Not enough time yet
    ctx.time_ms = 500;
    try expect(!resolver.checkRetry());

    // After retry timeout (1000ms)
    ctx.time_ms = 1001;
    try expect(resolver.checkRetry());
    try expectEqual(@as(u32, 2), ctx.send_count);
}

test "checkRetry: stops after max retries" {
    var ctx = MockCtx{ .time_ms = 0 };
    var resolver = makeResolver(&ctx);

    _ = resolver.query("fail.com");

    // Exhaust retries
    for (0..6) |i| {
        ctx.time_ms = @as(u64, i + 1) * 2000;
        _ = resolver.checkRetry();
    }

    try expect(resolver.hasPendingTimeout() or resolver.pending_name_len == 0);
}

// ── Helper: build a minimal DNS A-record response ───────────────────

fn buildDnsResponse(qid: u16, name: []const u8, ip: [4]u8, ttl: u32) [512]u8 {
    var buf: [512]u8 = .{0} ** 512;

    // Header
    buf[0] = @truncate(qid >> 8);
    buf[1] = @truncate(qid);
    buf[2] = 0x81;
    buf[3] = 0x80; // standard response, no error
    buf[4] = 0;
    buf[5] = 1; // QDCOUNT=1
    buf[6] = 0;
    buf[7] = 1; // ANCOUNT=1

    // Question section: encode name
    var pos: usize = 12;
    var start: usize = 0;
    for (name, 0..) |ch, i| {
        if (ch == '.') {
            buf[pos] = @intCast(i - start);
            pos += 1;
            @memcpy(buf[pos..][0 .. i - start], name[start..i]);
            pos += i - start;
            start = i + 1;
        }
    }
    if (start < name.len) {
        buf[pos] = @intCast(name.len - start);
        pos += 1;
        @memcpy(buf[pos..][0 .. name.len - start], name[start..]);
        pos += name.len - start;
    }
    buf[pos] = 0; // root
    pos += 1;
    // QTYPE=A, QCLASS=IN
    buf[pos] = 0;
    buf[pos + 1] = 1;
    buf[pos + 2] = 0;
    buf[pos + 3] = 1;
    pos += 4;

    // Answer section: pointer to name in question
    buf[pos] = 0xC0;
    buf[pos + 1] = 12; // pointer to offset 12
    pos += 2;
    // TYPE=A
    buf[pos] = 0;
    buf[pos + 1] = 1;
    pos += 2;
    // CLASS=IN
    buf[pos] = 0;
    buf[pos + 1] = 1;
    pos += 2;
    // TTL (big-endian u32)
    buf[pos] = @truncate(ttl >> 24);
    buf[pos + 1] = @truncate(ttl >> 16);
    buf[pos + 2] = @truncate(ttl >> 8);
    buf[pos + 3] = @truncate(ttl);
    pos += 4;
    // RDLENGTH=4
    buf[pos] = 0;
    buf[pos + 1] = 4;
    pos += 2;
    // RDATA (IP)
    @memcpy(buf[pos..][0..4], &ip);

    return buf;
}
