const std = @import("std");
const ethernet = @import("ethernet");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

// ── Parse ───────────────────────────────────────────────────────────

test "parse valid Ethernet frame" {
    // Build a known frame: dst=broadcast, src=DE:AD:BE:EF:00:01, EtherType=0x0800 (IPv4), payload="hi"
    const frame = [_]u8{
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // dst (broadcast)
        0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, // src
        0x08, 0x00, // EtherType (IPv4)
        'h',  'i', // payload
    };

    const result = ethernet.parse(&frame) orelse return error.TestUnexpectedResult;

    try expectEqualSlices(u8, &ethernet.BROADCAST, &result.header.dst);
    try expectEqualSlices(u8, &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01 }, &result.header.src);
    try expectEqual(@as(u16, ethernet.ETHER_IPV4), result.header.ethertype);
    try expectEqualSlices(u8, "hi", result.payload);
}

test "parse frame too short" {
    const short = [_]u8{ 0xFF, 0xFF, 0xFF };
    try expect(ethernet.parse(&short) == null);
}

// ── Build ───────────────────────────────────────────────────────────

test "build Ethernet frame" {
    const dst = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 };
    const src = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF };
    const payload = "test";
    var buf: [ethernet.MAX_FRAME]u8 = undefined;

    const len = ethernet.build(&buf, dst, src, ethernet.ETHER_ARP, payload) orelse
        return error.TestUnexpectedResult;

    try expectEqual(@as(usize, ethernet.HEADER_SIZE + 4), len);
    // Check dst
    try expectEqualSlices(u8, &dst, buf[0..6]);
    // Check src
    try expectEqualSlices(u8, &src, buf[6..12]);
    // Check EtherType
    try expectEqual(@as(u8, 0x08), buf[12]);
    try expectEqual(@as(u8, 0x06), buf[13]);
    // Check payload
    try expectEqualSlices(u8, payload, buf[14..18]);
}

test "build rejects oversized payload" {
    const dst = [_]u8{ 0, 0, 0, 0, 0, 0 };
    const src = dst;
    var big_payload: [1501]u8 = undefined;
    @memset(&big_payload, 0x42);
    var buf: [2000]u8 = undefined;

    try expect(ethernet.build(&buf, dst, src, 0x0800, &big_payload) == null);
}

test "build rejects small buffer" {
    const dst = [_]u8{ 0, 0, 0, 0, 0, 0 };
    const src = dst;
    var buf: [10]u8 = undefined; // too small for header + payload

    try expect(ethernet.build(&buf, dst, src, 0x0800, "hello") == null);
}

// ── Round-trip ──────────────────────────────────────────────────────

test "build then parse round-trip" {
    const dst = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06 };
    const src = [_]u8{ 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F };
    const payload = "round trip";
    var buf: [ethernet.MAX_FRAME]u8 = undefined;

    const len = ethernet.build(&buf, dst, src, 0x1234, payload) orelse
        return error.TestUnexpectedResult;
    const result = ethernet.parse(buf[0..len]) orelse
        return error.TestUnexpectedResult;

    try expectEqualSlices(u8, &dst, &result.header.dst);
    try expectEqualSlices(u8, &src, &result.header.src);
    try expectEqual(@as(u16, 0x1234), result.header.ethertype);
    try expectEqualSlices(u8, payload, result.payload);
}

// ── MAC utilities ───────────────────────────────────────────────────

test "BROADCAST constant" {
    try expectEqualSlices(u8, &[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }, &ethernet.BROADCAST);
}

test "macEqual" {
    const a = [_]u8{ 1, 2, 3, 4, 5, 6 };
    const b = [_]u8{ 1, 2, 3, 4, 5, 6 };
    const c = [_]u8{ 1, 2, 3, 4, 5, 7 };
    try expect(ethernet.macEqual(a, b));
    try expect(!ethernet.macEqual(a, c));
}

test "isBroadcast" {
    try expect(ethernet.isBroadcast(ethernet.BROADCAST));
    try expect(!ethernet.isBroadcast([_]u8{ 0, 0, 0, 0, 0, 0 }));
}
