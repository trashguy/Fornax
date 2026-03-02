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
const ARP_HASH_BITS = 6; // 64 buckets
const ARP_HASH_SIZE = 1 << ARP_HASH_BITS;
const ARP_HASH_MASK = ARP_HASH_SIZE - 1;
const HASH_END: u8 = 0xFF;

fn arpHash(ip: [4]u8) usize {
    const v = @as(u32, ip[0]) | (@as(u32, ip[1]) << 8) |
        (@as(u32, ip[2]) << 16) | (@as(u32, ip[3]) << 24);
    return (v *% 2654435761) >> (32 - ARP_HASH_BITS);
}

pub const CacheEntry = struct {
    ip: [4]u8,
    mac: [6]u8,
    valid: bool,
    hash_next: u8, // next entry in hash chain, 0xFF = end
};

pub const ArpTable = struct {
    cache: [CACHE_SIZE]CacheEntry,
    next_slot: usize,
    hash_buckets: [ARP_HASH_SIZE]u8, // index into cache[], HASH_END = empty

    pub fn init() ArpTable {
        return .{
            .cache = [_]CacheEntry{.{
                .ip = .{ 0, 0, 0, 0 },
                .mac = .{ 0, 0, 0, 0, 0, 0 },
                .valid = false,
                .hash_next = HASH_END,
            }} ** CACHE_SIZE,
            .next_slot = 0,
            .hash_buckets = [_]u8{HASH_END} ** ARP_HASH_SIZE,
        };
    }

    /// Look up a MAC address for the given IP (O(1) hash chain walk).
    pub fn lookup(self: *const ArpTable, ip: [4]u8) ?[6]u8 {
        var idx = self.hash_buckets[arpHash(ip)];
        while (idx != HASH_END) {
            const e = &self.cache[idx];
            if (e.valid and ipv4.ipEqual(e.ip, ip)) return e.mac;
            idx = e.hash_next;
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

    /// Insert or update a cache entry (hash-accelerated).
    pub fn insert(self: *ArpTable, ip: [4]u8, mac: [6]u8) void {
        const bucket = arpHash(ip);
        // Update existing entry in hash chain
        var idx = self.hash_buckets[bucket];
        while (idx != HASH_END) {
            const e = &self.cache[idx];
            if (e.valid and ipv4.ipEqual(e.ip, ip)) {
                e.mac = mac;
                return;
            }
            idx = e.hash_next;
        }
        // Insert new — evict at next_slot (round-robin)
        const slot: u8 = @intCast(self.next_slot);
        const evicted = &self.cache[slot];
        // Remove evicted entry from its old hash chain
        if (evicted.valid) {
            self.hashRemoveEntry(slot, arpHash(evicted.ip));
        }
        // Insert new entry
        evicted.ip = ip;
        evicted.mac = mac;
        evicted.valid = true;
        // Prepend to new bucket's chain
        evicted.hash_next = self.hash_buckets[bucket];
        self.hash_buckets[bucket] = slot;
        self.next_slot = (self.next_slot + 1) % CACHE_SIZE;
    }

    /// Remove an entry from a hash chain by slot index.
    fn hashRemoveEntry(self: *ArpTable, slot: u8, bucket: usize) void {
        if (self.hash_buckets[bucket] == slot) {
            self.hash_buckets[bucket] = self.cache[slot].hash_next;
            return;
        }
        var prev = self.hash_buckets[bucket];
        while (prev != HASH_END) {
            if (self.cache[prev].hash_next == slot) {
                self.cache[prev].hash_next = self.cache[slot].hash_next;
                return;
            }
            prev = self.cache[prev].hash_next;
        }
    }

    /// Flush all entries.
    pub fn flush(self: *ArpTable) void {
        for (&self.cache) |*entry| {
            entry.valid = false;
            entry.hash_next = HASH_END;
        }
        @memset(&self.hash_buckets, HASH_END);
    }

    pub fn remove(self: *ArpTable, ip: [4]u8) void {
        const bucket = arpHash(ip);
        var idx = self.hash_buckets[bucket];
        while (idx != HASH_END) {
            const e = &self.cache[idx];
            if (e.valid and ipv4.ipEqual(e.ip, ip)) {
                e.valid = false;
                self.hashRemoveEntry(idx, bucket);
                return;
            }
            idx = e.hash_next;
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
