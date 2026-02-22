const std = @import("std");
const arp = @import("arp");
const ethernet = @import("ethernet");
const ipv4 = @import("ipv4");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const OUR_MAC = [_]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
const OUR_IP = [_]u8{ 10, 0, 2, 15 };

// ── Cache operations ────────────────────────────────────────────────

test "insert and lookup" {
    var table = arp.ArpTable.init();
    const ip = [_]u8{ 10, 0, 0, 1 };
    const mac = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF };

    table.insert(ip, mac);
    const found = table.lookup(ip) orelse return error.TestUnexpectedResult;
    try expectEqualSlices(u8, &mac, &found);
}

test "lookup miss" {
    var table = arp.ArpTable.init();
    try expect(table.lookup(.{ 10, 0, 0, 1 }) == null);
}

test "update existing entry" {
    var table = arp.ArpTable.init();
    const ip = [_]u8{ 10, 0, 0, 1 };
    const mac1 = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06 };
    const mac2 = [_]u8{ 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F };

    table.insert(ip, mac1);
    table.insert(ip, mac2); // update

    const found = table.lookup(ip) orelse return error.TestUnexpectedResult;
    try expectEqualSlices(u8, &mac2, &found);
}

test "cache eviction (round-robin)" {
    var table = arp.ArpTable.init();

    // Fill all slots
    for (0..arp.CACHE_SIZE) |i| {
        const ip = [_]u8{ 10, 0, @intCast(i >> 8), @intCast(i & 0xFF) };
        table.insert(ip, .{ 0, 0, 0, 0, 0, @intCast(i) });
    }

    // Insert one more — should evict slot 0
    table.insert(.{ 192, 168, 0, 1 }, .{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });

    // Original slot 0 IP should be gone
    try expect(table.lookup(.{ 10, 0, 0, 0 }) == null);
    // New entry should be present
    try expect(table.lookup(.{ 192, 168, 0, 1 }) != null);
}

test "flush clears all entries" {
    var table = arp.ArpTable.init();
    table.insert(.{ 10, 0, 0, 1 }, .{ 1, 2, 3, 4, 5, 6 });
    table.flush();
    try expect(table.lookup(.{ 10, 0, 0, 1 }) == null);
}

// ── buildRequest ────────────────────────────────────────────────────

test "buildRequest: wire format" {
    var buf: [ethernet.MAX_FRAME]u8 = undefined;
    const len = arp.ArpTable.buildRequest(&buf, OUR_MAC, OUR_IP, .{ 10, 0, 2, 1 }) orelse
        return error.TestUnexpectedResult;

    // Should be ethernet header (14) + ARP packet (28) = 42
    try expectEqual(@as(usize, 42), len);

    // Parse the Ethernet frame
    const eth = ethernet.parse(buf[0..len]) orelse return error.TestUnexpectedResult;
    try expect(ethernet.isBroadcast(eth.header.dst));
    try expectEqualSlices(u8, &OUR_MAC, &eth.header.src);
    try expectEqual(@as(u16, ethernet.ETHER_ARP), eth.header.ethertype);

    // ARP payload checks
    const p = eth.payload;
    try expect(p.len >= 28);
    // HW type = Ethernet (1)
    try expectEqual(@as(u8, 0), p[0]);
    try expectEqual(@as(u8, 1), p[1]);
    // Proto type = IPv4 (0x0800)
    try expectEqual(@as(u8, 0x08), p[2]);
    try expectEqual(@as(u8, 0x00), p[3]);
    // HW size = 6, Proto size = 4
    try expectEqual(@as(u8, 6), p[4]);
    try expectEqual(@as(u8, 4), p[5]);
    // Operation = Request (1)
    try expectEqual(@as(u8, 0), p[6]);
    try expectEqual(@as(u8, 1), p[7]);
    // Sender MAC
    try expectEqualSlices(u8, &OUR_MAC, p[8..14]);
    // Sender IP
    try expectEqualSlices(u8, &OUR_IP, p[14..18]);
    // Target IP
    try expectEqualSlices(u8, &[_]u8{ 10, 0, 2, 1 }, p[24..28]);
}

// ── handlePacket ────────────────────────────────────────────────────

fn buildArpRequest(buf: []u8, sender_mac: [6]u8, sender_ip: [4]u8, target_ip: [4]u8) []u8 {
    // Build a raw ARP request payload (28 bytes)
    buf[0] = 0;
    buf[1] = 1; // HW type = Ethernet
    buf[2] = 0x08;
    buf[3] = 0x00; // Proto type = IPv4
    buf[4] = 6;
    buf[5] = 4; // HW/Proto sizes
    buf[6] = 0;
    buf[7] = 1; // Operation = Request
    @memcpy(buf[8..14], &sender_mac);
    @memcpy(buf[14..18], &sender_ip);
    @memset(buf[18..24], 0); // target MAC (unknown)
    @memcpy(buf[24..28], &target_ip);
    return buf[0..28];
}

fn buildArpReplyPayload(buf: []u8, sender_mac: [6]u8, sender_ip: [4]u8, target_mac: [6]u8, target_ip: [4]u8) []u8 {
    buf[0] = 0;
    buf[1] = 1;
    buf[2] = 0x08;
    buf[3] = 0x00;
    buf[4] = 6;
    buf[5] = 4;
    buf[6] = 0;
    buf[7] = 2; // Operation = Reply
    @memcpy(buf[8..14], &sender_mac);
    @memcpy(buf[14..18], &sender_ip);
    @memcpy(buf[18..24], &target_mac);
    @memcpy(buf[24..28], &target_ip);
    return buf[0..28];
}

test "handlePacket: ARP request for us sends reply" {
    var table = arp.ArpTable.init();
    const sender_mac = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF };
    const sender_ip = [_]u8{ 10, 0, 2, 1 };

    var arp_buf: [28]u8 = undefined;
    const payload = buildArpRequest(&arp_buf, sender_mac, sender_ip, OUR_IP);

    var reply_buf: [ethernet.MAX_FRAME]u8 = undefined;
    const reply_len = table.handlePacket(payload, OUR_MAC, OUR_IP, &reply_buf);

    try expect(reply_len != null);
    // Should have learned sender's MAC
    const found = table.lookup(sender_ip) orelse return error.TestUnexpectedResult;
    try expectEqualSlices(u8, &sender_mac, &found);
}

test "handlePacket: ARP request for different IP no reply" {
    var table = arp.ArpTable.init();
    const sender_mac = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF };
    const sender_ip = [_]u8{ 10, 0, 2, 1 };
    const other_ip = [_]u8{ 10, 0, 2, 99 };

    var arp_buf: [28]u8 = undefined;
    const payload = buildArpRequest(&arp_buf, sender_mac, sender_ip, other_ip);

    var reply_buf: [ethernet.MAX_FRAME]u8 = undefined;
    const reply_len = table.handlePacket(payload, OUR_MAC, OUR_IP, &reply_buf);

    try expect(reply_len == null);
    // Still learns sender
    try expect(table.lookup(sender_ip) != null);
}

test "handlePacket: ARP reply updates cache" {
    var table = arp.ArpTable.init();
    const sender_mac = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 };
    const sender_ip = [_]u8{ 10, 0, 2, 1 };

    var arp_buf: [28]u8 = undefined;
    const payload = buildArpReplyPayload(&arp_buf, sender_mac, sender_ip, OUR_MAC, OUR_IP);

    var reply_buf: [ethernet.MAX_FRAME]u8 = undefined;
    _ = table.handlePacket(payload, OUR_MAC, OUR_IP, &reply_buf);

    const found = table.lookup(sender_ip) orelse return error.TestUnexpectedResult;
    try expectEqualSlices(u8, &sender_mac, &found);
}

test "handlePacket: reject malformed" {
    var table = arp.ArpTable.init();
    var reply_buf: [ethernet.MAX_FRAME]u8 = undefined;
    // Too short
    try expect(table.handlePacket("short", OUR_MAC, OUR_IP, &reply_buf) == null);
}
