/// ARP: Address Resolution Protocol.
///
/// Resolves IPv4 addresses to MAC addresses. Maintains a small cache.
/// Handles ARP requests (replies to queries for our IP) and stores
/// results from ARP replies.
const klog = @import("../klog.zig");
const ethernet = @import("ethernet.zig");

const ARP_REQUEST: u16 = 1;
const ARP_REPLY: u16 = 2;
const HW_ETHERNET: u16 = 1;
const PROTO_IPV4: u16 = 0x0800;
const ARP_PACKET_SIZE = 28; // for Ethernet+IPv4

pub const CacheEntry = struct {
    ip: [4]u8,
    mac: [6]u8,
    valid: bool,
};

const CACHE_SIZE = 32;
var cache: [CACHE_SIZE]CacheEntry = [_]CacheEntry{.{
    .ip = .{ 0, 0, 0, 0 },
    .mac = .{ 0, 0, 0, 0, 0, 0 },
    .valid = false,
}} ** CACHE_SIZE;

var next_cache_slot: usize = 0;

/// Look up a MAC address for the given IP.
pub fn lookup(ip: [4]u8) ?[6]u8 {
    for (&cache) |*entry| {
        if (entry.valid and ipEqual(entry.ip, ip)) {
            return entry.mac;
        }
    }
    return null;
}

/// Process an incoming ARP packet. Returns an ARP reply frame to send, or null.
/// `our_mac` and `our_ip` are this machine's addresses.
/// `payload` is the ARP data after the Ethernet header.
/// `reply_buf` is a buffer to write the reply Ethernet frame into.
pub fn handlePacket(
    payload: []const u8,
    our_mac: [6]u8,
    our_ip: [4]u8,
    reply_buf: []u8,
) ?usize {
    if (payload.len < ARP_PACKET_SIZE) return null;

    const hw_type = be16(payload[0..2]);
    const proto_type = be16(payload[2..4]);
    const hw_len = payload[4];
    const proto_len = payload[5];
    const operation = be16(payload[6..8]);

    if (hw_type != HW_ETHERNET or proto_type != PROTO_IPV4) return null;
    if (hw_len != 6 or proto_len != 4) return null;

    const sender_mac = payload[8..14];
    const sender_ip = payload[14..18];
    const target_ip = payload[24..28];

    // Always learn from the sender
    cacheInsert(sender_ip[0..4].*, sender_mac[0..6].*);

    if (operation == ARP_REQUEST) {
        // Is this asking for our MAC?
        if (ipEqual(target_ip[0..4].*, our_ip)) {
            klog.debug("arp: request for our IP, sending reply\n");
            return buildReply(reply_buf, our_mac, our_ip, sender_mac[0..6].*, sender_ip[0..4].*);
        }
    }

    return null;
}

/// Send an ARP request for the given IP address.
/// Returns the total Ethernet frame length written to `buf`.
pub fn buildRequest(buf: []u8, our_mac: [6]u8, our_ip: [4]u8, target_ip: [4]u8) ?usize {
    if (buf.len < ethernet.HEADER_SIZE + ARP_PACKET_SIZE) return null;

    var arp: [ARP_PACKET_SIZE]u8 = undefined;
    writeBe16(&arp, 0, HW_ETHERNET);
    writeBe16(&arp, 2, PROTO_IPV4);
    arp[4] = 6; // hw addr len
    arp[5] = 4; // proto addr len
    writeBe16(&arp, 6, ARP_REQUEST);
    @memcpy(arp[8..14], &our_mac);
    @memcpy(arp[14..18], &our_ip);
    @memset(arp[18..24], 0); // target MAC unknown
    @memcpy(arp[24..28], &target_ip);

    return ethernet.build(buf, ethernet.BROADCAST, our_mac, ethernet.ETHER_ARP, &arp);
}

fn buildReply(buf: []u8, our_mac: [6]u8, our_ip: [4]u8, target_mac: [6]u8, target_ip: [4]u8) ?usize {
    if (buf.len < ethernet.HEADER_SIZE + ARP_PACKET_SIZE) return null;

    var arp: [ARP_PACKET_SIZE]u8 = undefined;
    writeBe16(&arp, 0, HW_ETHERNET);
    writeBe16(&arp, 2, PROTO_IPV4);
    arp[4] = 6;
    arp[5] = 4;
    writeBe16(&arp, 6, ARP_REPLY);
    @memcpy(arp[8..14], &our_mac);
    @memcpy(arp[14..18], &our_ip);
    @memcpy(arp[18..24], &target_mac);
    @memcpy(arp[24..28], &target_ip);

    return ethernet.build(buf, target_mac, our_mac, ethernet.ETHER_ARP, &arp);
}

fn cacheInsert(ip: [4]u8, mac: [6]u8) void {
    // Update existing entry if present
    for (&cache) |*entry| {
        if (entry.valid and ipEqual(entry.ip, ip)) {
            entry.mac = mac;
            return;
        }
    }
    // Insert into next slot (round-robin eviction)
    cache[next_cache_slot] = .{ .ip = ip, .mac = mac, .valid = true };
    next_cache_slot = (next_cache_slot + 1) % CACHE_SIZE;
}

pub fn getCache() []const CacheEntry {
    return &cache;
}

fn ipEqual(a: [4]u8, b: [4]u8) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2] and a[3] == b[3];
}

fn be16(bytes: *const [2]u8) u16 {
    return @as(u16, bytes[0]) << 8 | bytes[1];
}

fn writeBe16(buf: []u8, offset: usize, val: u16) void {
    buf[offset] = @truncate(val >> 8);
    buf[offset + 1] = @truncate(val);
}
