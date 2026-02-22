const std = @import("std");
const ipv4 = @import("ipv4");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

// ── computeChecksum ─────────────────────────────────────────────────

test "computeChecksum: RFC 1071 test vector" {
    // RFC 1071 example header (20 bytes with checksum zeroed)
    const header = [_]u8{
        0x45, 0x00, 0x00, 0x73, // ver/ihl, tos, total_len=115
        0x00, 0x00, 0x40, 0x00, // id=0, flags=DF
        0x40, 0x11, 0x00, 0x00, // ttl=64, proto=UDP, cksum=0
        0xC0, 0xA8, 0x00, 0x01, // src=192.168.0.1
        0xC0, 0xA8, 0x00, 0xC7, // dst=192.168.0.199
    };

    const cksum = ipv4.computeChecksum(&header);
    try expect(cksum != 0);

    // Now verify: put the checksum in and verify it produces 0
    var verified = header;
    verified[10] = @truncate(cksum >> 8);
    verified[11] = @truncate(cksum);
    try expectEqual(@as(u16, 0), ipv4.computeChecksum(&verified));
}

test "computeChecksum: all zeros" {
    const zeros = [_]u8{0} ** 20;
    try expectEqual(@as(u16, 0xFFFF), ipv4.computeChecksum(&zeros));
}

// ── Build ───────────────────────────────────────────────────────────

test "build valid IPv4 packet" {
    const src_ip = [_]u8{ 10, 0, 0, 1 };
    const dst_ip = [_]u8{ 10, 0, 0, 2 };
    const payload = "hello";
    var buf: [1500]u8 = undefined;

    const len = ipv4.build(&buf, src_ip, dst_ip, ipv4.PROTO_TCP, 64, 0x1234, payload) orelse
        return error.TestUnexpectedResult;

    try expectEqual(@as(usize, 25), len); // 20 header + 5 payload

    // Version/IHL
    try expectEqual(@as(u8, 0x45), buf[0]);
    // Protocol
    try expectEqual(@as(u8, ipv4.PROTO_TCP), buf[9]);
    // TTL
    try expectEqual(@as(u8, 64), buf[8]);
    // Src IP
    try expectEqualSlices(u8, &src_ip, buf[12..16]);
    // Dst IP
    try expectEqualSlices(u8, &dst_ip, buf[16..20]);
    // Payload
    try expectEqualSlices(u8, payload, buf[20..25]);
    // Checksum validates
    try expectEqual(@as(u16, 0), ipv4.computeChecksum(buf[0..20]));
}

test "build rejects too small buffer" {
    var buf: [10]u8 = undefined;
    try expect(ipv4.build(&buf, .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 }, 6, 64, 0, "hello") == null);
}

// ── Parse ───────────────────────────────────────────────────────────

test "parse valid IPv4 packet" {
    const src_ip = [_]u8{ 192, 168, 1, 1 };
    const dst_ip = [_]u8{ 192, 168, 1, 2 };
    const payload = "data";
    var buf: [1500]u8 = undefined;

    const build_len = ipv4.build(&buf, src_ip, dst_ip, ipv4.PROTO_UDP, 128, 0, payload) orelse
        return error.TestUnexpectedResult;

    const result = ipv4.parse(buf[0..build_len]) orelse
        return error.TestUnexpectedResult;

    try expectEqual(@as(u8, 0x45), result.header.version_ihl);
    try expectEqual(ipv4.PROTO_UDP, result.header.protocol);
    try expectEqual(@as(u8, 128), result.header.ttl);
    try expectEqualSlices(u8, &src_ip, &result.header.src);
    try expectEqualSlices(u8, &dst_ip, &result.header.dst);
    try expectEqualSlices(u8, payload, result.payload);
}

test "parse rejects short data" {
    const short = [_]u8{ 0x45, 0x00 };
    try expect(ipv4.parse(&short) == null);
}

test "parse rejects wrong version" {
    var buf: [1500]u8 = undefined;
    _ = ipv4.build(&buf, .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 }, 6, 64, 0, "x") orelse
        return error.TestUnexpectedResult;
    buf[0] = 0x65; // version 6 instead of 4
    try expect(ipv4.parse(buf[0..21]) == null);
}

test "parse rejects bad checksum" {
    var buf: [1500]u8 = undefined;
    const len = ipv4.build(&buf, .{ 1, 2, 3, 4 }, .{ 5, 6, 7, 8 }, 6, 64, 0, "x") orelse
        return error.TestUnexpectedResult;
    buf[10] ^= 0xFF; // corrupt checksum
    try expect(ipv4.parse(buf[0..len]) == null);
}

// ── Round-trip ──────────────────────────────────────────────────────

test "build then parse round-trip" {
    const src_ip = [_]u8{ 10, 20, 30, 40 };
    const dst_ip = [_]u8{ 50, 60, 70, 80 };
    const payload = "round trip test";
    var buf: [1500]u8 = undefined;

    const len = ipv4.build(&buf, src_ip, dst_ip, ipv4.PROTO_ICMP, 255, 0xABCD, payload) orelse
        return error.TestUnexpectedResult;
    const result = ipv4.parse(buf[0..len]) orelse
        return error.TestUnexpectedResult;

    try expectEqualSlices(u8, &src_ip, &result.header.src);
    try expectEqualSlices(u8, &dst_ip, &result.header.dst);
    try expectEqual(ipv4.PROTO_ICMP, result.header.protocol);
    try expectEqual(@as(u8, 255), result.header.ttl);
    try expectEqualSlices(u8, payload, result.payload);
}

// ── Byte order helpers ──────────────────────────────────────────────

test "be16: big-endian read" {
    const bytes = [_]u8{ 0x12, 0x34 };
    try expectEqual(@as(u16, 0x1234), ipv4.be16(&bytes));
}

test "be32: big-endian read" {
    const bytes = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    try expectEqual(@as(u32, 0xDEADBEEF), ipv4.be32(&bytes, 0));
}

test "writeBe16: big-endian write" {
    var buf: [4]u8 = undefined;
    ipv4.writeBe16(&buf, 1, 0xABCD);
    try expectEqual(@as(u8, 0xAB), buf[1]);
    try expectEqual(@as(u8, 0xCD), buf[2]);
}

test "writeBe32: big-endian write" {
    var buf: [4]u8 = undefined;
    ipv4.writeBe32(&buf, 0, 0x12345678);
    try expectEqual(@as(u8, 0x12), buf[0]);
    try expectEqual(@as(u8, 0x34), buf[1]);
    try expectEqual(@as(u8, 0x56), buf[2]);
    try expectEqual(@as(u8, 0x78), buf[3]);
}

test "ipEqual" {
    try expect(ipv4.ipEqual(.{ 10, 0, 0, 1 }, .{ 10, 0, 0, 1 }));
    try expect(!ipv4.ipEqual(.{ 10, 0, 0, 1 }, .{ 10, 0, 0, 2 }));
}
