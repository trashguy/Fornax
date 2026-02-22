/// ARP: Address Resolution Protocol (userspace, struct-based).
///
/// Resolves IPv4 addresses to MAC addresses. Each ArpTable instance
/// maintains its own cache — no global state.
const ethernet = @import("ethernet.zig");
const ipv4 = @import("ipv4.zig");

const ARP_REQUEST: u16 = 1;
const ARP_REPLY: u16 = 2;
const HW_ETHERNET: u16 = 1;
const PROTO_IPV4: u16 = 0x0800;
const ARP_PACKET_SIZE = 28;

pub const CACHE_SIZE = 32;

pub const CacheEntry = struct {
    ip: [4]u8,
    mac: [6]u8,
    valid: bool,
};

pub const ArpTable = struct {
    cache: [CACHE_SIZE]CacheEntry,
    next_slot: usize,

    pub fn init() ArpTable {
        return .{
            .cache = [_]CacheEntry{.{
                .ip = .{ 0, 0, 0, 0 },
                .mac = .{ 0, 0, 0, 0, 0, 0 },
                .valid = false,
            }} ** CACHE_SIZE,
            .next_slot = 0,
        };
    }

    /// Look up a MAC address for the given IP.
    pub fn lookup(self: *const ArpTable, ip: [4]u8) ?[6]u8 {
        for (&self.cache) |*entry| {
            if (entry.valid and ipv4.ipEqual(entry.ip, ip)) {
                return entry.mac;
            }
        }
        return null;
    }

    /// Process an incoming ARP packet. Returns an ARP reply frame to send, or null.
    pub fn handlePacket(
        self: *ArpTable,
        payload: []const u8,
        our_mac: [6]u8,
        our_ip: [4]u8,
        reply_buf: []u8,
    ) ?usize {
        if (payload.len < ARP_PACKET_SIZE) return null;

        const hw_type = be16(payload[0..2]);
        const proto_type = be16(payload[2..4]);
        if (hw_type != HW_ETHERNET or proto_type != PROTO_IPV4) return null;
        if (payload[4] != 6 or payload[5] != 4) return null;

        const operation = be16(payload[6..8]);
        const sender_mac = payload[8..14];
        const sender_ip = payload[14..18];
        const target_ip = payload[24..28];

        // Always learn from the sender
        self.insert(sender_ip[0..4].*, sender_mac[0..6].*);

        if (operation == ARP_REQUEST and ipv4.ipEqual(target_ip[0..4].*, our_ip)) {
            return buildReply(reply_buf, our_mac, our_ip, sender_mac[0..6].*, sender_ip[0..4].*);
        }

        return null;
    }

    /// Build an ARP request frame.
    pub fn buildRequest(buf: []u8, our_mac: [6]u8, our_ip: [4]u8, target_ip: [4]u8) ?usize {
        if (buf.len < ethernet.HEADER_SIZE + ARP_PACKET_SIZE) return null;

        var arp: [ARP_PACKET_SIZE]u8 = undefined;
        writeBe16(&arp, 0, HW_ETHERNET);
        writeBe16(&arp, 2, PROTO_IPV4);
        arp[4] = 6;
        arp[5] = 4;
        writeBe16(&arp, 6, ARP_REQUEST);
        @memcpy(arp[8..14], &our_mac);
        @memcpy(arp[14..18], &our_ip);
        @memset(arp[18..24], 0);
        @memcpy(arp[24..28], &target_ip);

        return ethernet.build(buf, ethernet.BROADCAST, our_mac, ethernet.ETHER_ARP, &arp);
    }

    /// Insert or update a cache entry.
    pub fn insert(self: *ArpTable, ip: [4]u8, mac: [6]u8) void {
        // Update existing
        for (&self.cache) |*entry| {
            if (entry.valid and ipv4.ipEqual(entry.ip, ip)) {
                entry.mac = mac;
                return;
            }
        }
        // Insert new (round-robin eviction)
        self.cache[self.next_slot] = .{ .ip = ip, .mac = mac, .valid = true };
        self.next_slot = (self.next_slot + 1) % CACHE_SIZE;
    }

    /// Flush all entries.
    pub fn flush(self: *ArpTable) void {
        for (&self.cache) |*entry| {
            entry.valid = false;
        }
    }

    pub fn remove(self: *ArpTable, ip: [4]u8) void {
        for (&self.cache) |*entry| {
            if (entry.valid and ipv4.ipEqual(entry.ip, ip)) {
                entry.valid = false;
                return;
            }
        }
    }

    /// Get the cache for reading.
    pub fn getCache(self: *const ArpTable) []const CacheEntry {
        return &self.cache;
    }
};

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

fn be16(bytes: *const [2]u8) u16 {
    return @as(u16, bytes[0]) << 8 | bytes[1];
}

fn writeBe16(buf: []u8, offset: usize, val: u16) void {
    buf[offset] = @truncate(val >> 8);
    buf[offset + 1] = @truncate(val);
}
