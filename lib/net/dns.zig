/// DNS: Domain Name System resolver (userspace, struct-based).
///
/// Resolves A records over UDP. Each DnsResolver instance maintains its own
/// cache, pending query state, and nameserver config — no global state.
const ipv4 = @import("ipv4.zig");

pub const MAX_CACHE = 32;
pub const DNS_PORT: u16 = 53;
pub const MAX_NAME_LEN = 128;
const DNS_RETRY_MS: u32 = 1000;
const DNS_MAX_RETRIES: u8 = 5;

pub const CacheEntry = struct {
    name: [MAX_NAME_LEN]u8,
    name_len: u8,
    ip: [4]u8,
    expire_ms: u64, // uptime ms at which this entry expires
    valid: bool,
};

/// Callback for sending a UDP datagram.
pub const SendUdpFn = *const fn (ctx: *anyopaque, dst_ip: [4]u8, src_port: u16, dst_port: u16, data: []const u8) void;

/// Callback for getting current uptime in milliseconds.
pub const GetTimeFn = *const fn (ctx: *anyopaque) u64;

pub const DnsResolver = struct {
    cache: [MAX_CACHE]CacheEntry,
    nameserver: [4]u8,
    query_id: u16,
    bind_port: u16,

    // Pending query state
    pending_name: [MAX_NAME_LEN]u8,
    pending_name_len: u8,
    pending_qid: u16,
    pending_result: ?[4]u8,
    pending_send_ms: u64,
    pending_retries: u8,

    // Callbacks
    send_udp: SendUdpFn,
    get_time: GetTimeFn,
    cb_ctx: *anyopaque,

    pub fn init(
        send_udp: SendUdpFn,
        get_time: GetTimeFn,
        cb_ctx: *anyopaque,
        ns: [4]u8,
        bind_port: u16,
    ) DnsResolver {
        var self: DnsResolver = undefined;
        for (&self.cache) |*e| {
            e.valid = false;
            e.name_len = 0;
        }
        self.nameserver = ns;
        self.query_id = 1;
        self.bind_port = bind_port;
        self.pending_name_len = 0;
        self.pending_qid = 0;
        self.pending_result = null;
        self.pending_send_ms = 0;
        self.pending_retries = 0;
        self.send_udp = send_udp;
        self.get_time = get_time;
        self.cb_ctx = cb_ctx;
        return self;
    }

    pub fn setNameserver(self: *DnsResolver, ip: [4]u8) void {
        self.nameserver = ip;
    }

    /// Look up a name in cache. Returns IP if cached and not expired.
    pub fn cacheLookup(self: *DnsResolver, name: []const u8) ?[4]u8 {
        const now = self.get_time(self.cb_ctx);
        for (&self.cache) |*e| {
            if (!e.valid) continue;
            if (e.name_len != name.len) continue;
            if (!strEql(e.name[0..e.name_len], name)) continue;
            if (now >= e.expire_ms) {
                e.valid = false;
                continue;
            }
            return e.ip;
        }
        return null;
    }

    /// Send a DNS query for an A record. Non-blocking.
    /// Returns true if the result is already cached, false if query was sent.
    pub fn query(self: *DnsResolver, name: []const u8) bool {
        if (name.len == 0 or name.len > MAX_NAME_LEN) return false;

        // Check cache first
        if (self.cacheLookup(name)) |_| return true;

        // Build DNS query packet
        var buf: [512]u8 = undefined;
        const len = self.buildQuery(&buf, name) orelse return false;

        @memcpy(self.pending_name[0..name.len], name);
        self.pending_name_len = @intCast(name.len);
        self.pending_qid = self.query_id -% 1; // buildQuery already incremented
        self.pending_result = null;
        self.pending_send_ms = self.get_time(self.cb_ctx);
        self.pending_retries = 0;

        // Send via UDP callback
        self.send_udp(self.cb_ctx, self.nameserver, self.bind_port, DNS_PORT, buf[0..len]);
        return false;
    }

    /// Get the result of the last query.
    pub fn getResult(self: *const DnsResolver) ?[4]u8 {
        return self.pending_result;
    }

    /// Returns true if a pending query has timed out (all retries exhausted).
    pub fn hasPendingTimeout(self: *const DnsResolver) bool {
        return self.pending_name_len > 0 and self.pending_result == null and
            self.pending_retries >= DNS_MAX_RETRIES;
    }

    /// Process an incoming UDP payload as a DNS response.
    /// Returns the resolved IP on success, null if not a matching response.
    pub fn handleResponse(self: *DnsResolver, data: []const u8) ?[4]u8 {
        return self.parseResponse(data);
    }

    /// Check for retry timeout on pending query. Call periodically.
    /// Returns true if a retry was sent, false if nothing to do.
    pub fn checkRetry(self: *DnsResolver) bool {
        if (self.pending_name_len == 0 or self.pending_result != null) return false;

        const now = self.get_time(self.cb_ctx);
        if (now -% self.pending_send_ms < DNS_RETRY_MS) return false;

        if (self.pending_retries >= DNS_MAX_RETRIES) {
            self.pending_name_len = 0;
            return false;
        }

        // Rebuild and resend
        var buf: [512]u8 = undefined;
        const len = self.buildQuery(&buf, self.pending_name[0..self.pending_name_len]) orelse return false;
        self.pending_qid = self.query_id -% 1;
        self.send_udp(self.cb_ctx, self.nameserver, self.bind_port, DNS_PORT, buf[0..len]);
        self.pending_send_ms = now;
        self.pending_retries += 1;
        return true;
    }

    /// Format cache contents into a text buffer.
    pub fn getCacheText(self: *DnsResolver, buf: []u8) u16 {
        var pos: u16 = 0;
        const now = self.get_time(self.cb_ctx);

        for (&self.cache) |*e| {
            if (!e.valid) continue;
            if (now >= e.expire_ms) {
                e.valid = false;
                continue;
            }
            if (pos + e.name_len + 30 > buf.len) break;

            @memcpy(buf[pos..][0..e.name_len], e.name[0..e.name_len]);
            pos += e.name_len;
            buf[pos] = ' ';
            pos += 1;
            pos += formatIp(buf[pos..], e.ip);
            buf[pos] = ' ';
            pos += 1;
            const ttl_secs: u32 = @intCast((e.expire_ms -% now) / 1000);
            pos += formatDec(buf[pos..], ttl_secs);
            buf[pos] = '\n';
            pos += 1;
        }
        return pos;
    }

    /// Flush all cache entries.
    pub fn flushCache(self: *DnsResolver) void {
        for (&self.cache) |*e| {
            e.valid = false;
        }
    }

    // ── DNS packet building/parsing ─────────────────────────────────

    fn buildQuery(self: *DnsResolver, buf: []u8, name: []const u8) ?usize {
        if (buf.len < 512) return null;

        const qid = self.query_id;
        self.query_id +%= 1;
        writeBe16(buf, 0, qid);
        writeBe16(buf, 2, 0x0100); // standard query, recursion desired
        writeBe16(buf, 4, 1); // QDCOUNT = 1
        writeBe16(buf, 6, 0); // ANCOUNT
        writeBe16(buf, 8, 0); // NSCOUNT
        writeBe16(buf, 10, 0); // ARCOUNT

        // Question: encode name as labels
        var pos: usize = 12;
        var start: usize = 0;
        for (name, 0..) |ch, i| {
            if (ch == '.') {
                const label_len = i - start;
                if (label_len == 0 or label_len > 63) return null;
                buf[pos] = @intCast(label_len);
                pos += 1;
                @memcpy(buf[pos..][0..label_len], name[start..i]);
                pos += label_len;
                start = i + 1;
            }
        }
        if (start < name.len) {
            const label_len = name.len - start;
            if (label_len > 63) return null;
            buf[pos] = @intCast(label_len);
            pos += 1;
            @memcpy(buf[pos..][0..label_len], name[start..]);
            pos += label_len;
        }
        buf[pos] = 0; // root label
        pos += 1;

        // QTYPE = A (1), QCLASS = IN (1)
        writeBe16(buf, pos, 1);
        pos += 2;
        writeBe16(buf, pos, 1);
        pos += 2;

        return pos;
    }

    fn parseResponse(self: *DnsResolver, data: []const u8) ?[4]u8 {
        if (data.len < 12) return null;

        const resp_id = be16(data[0..2]);
        if (resp_id != self.pending_qid) return null;

        const ancount = be16(data[6..8]);
        if (ancount == 0) return null;

        // Skip question section
        var pos: usize = 12;
        while (pos < data.len) {
            const len = data[pos];
            if (len == 0) {
                pos += 1;
                break;
            }
            if (len & 0xC0 == 0xC0) {
                pos += 2;
                break;
            }
            pos += 1 + @as(usize, len);
        }
        pos += 4; // skip QTYPE + QCLASS

        // Parse answer RRs — look for A record
        var i: u16 = 0;
        while (i < ancount and pos + 10 < data.len) : (i += 1) {
            if (data[pos] & 0xC0 == 0xC0) {
                pos += 2;
            } else {
                while (pos < data.len and data[pos] != 0) {
                    pos += 1 + @as(usize, data[pos]);
                }
                pos += 1;
            }

            if (pos + 10 > data.len) break;

            const rtype = be16(data[pos..][0..2]);
            pos += 2;
            _ = be16(data[pos..][0..2]); // rclass
            pos += 2;
            const ttl = ipv4.be32(data, pos);
            pos += 4;
            const rdlength = be16(data[pos..][0..2]);
            pos += 2;

            if (rtype == 1 and rdlength == 4 and pos + 4 <= data.len) {
                const ip: [4]u8 = data[pos..][0..4].*;
                self.cacheInsert(self.pending_name[0..self.pending_name_len], ip, ttl);
                self.pending_result = ip;
                return ip;
            }
            pos += rdlength;
        }

        return null;
    }

    fn cacheInsert(self: *DnsResolver, name: []const u8, ip: [4]u8, ttl: u32) void {
        var slot: ?*CacheEntry = null;
        for (&self.cache) |*e| {
            if (!e.valid) {
                slot = e;
                break;
            }
        }
        if (slot == null) {
            const now = self.get_time(self.cb_ctx);
            for (&self.cache) |*e| {
                if (now >= e.expire_ms) {
                    slot = e;
                    break;
                }
            }
            if (slot == null) {
                slot = &self.cache[0];
            }
        }

        const entry = slot.?;
        @memcpy(entry.name[0..name.len], name);
        entry.name_len = @intCast(name.len);
        entry.ip = ip;
        const capped_ttl: u64 = @min(ttl, 600);
        entry.expire_ms = self.get_time(self.cb_ctx) + capped_ttl * 1000;
        entry.valid = true;
    }
};

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

pub fn formatIp(buf: []u8, ip: [4]u8) u16 {
    var pos: u16 = 0;
    for (ip, 0..) |octet, i| {
        pos += formatDec(buf[pos..], octet);
        if (i < 3) {
            buf[pos] = '.';
            pos += 1;
        }
    }
    return pos;
}

pub fn formatDec(buf: []u8, val: u32) u16 {
    if (val == 0) {
        buf[0] = '0';
        return 1;
    }
    var tmp: [10]u8 = undefined;
    var len: u16 = 0;
    var v = val;
    while (v > 0) : (len += 1) {
        tmp[len] = @intCast('0' + v % 10);
        v /= 10;
    }
    var i: u16 = 0;
    while (i < len) : (i += 1) {
        buf[i] = tmp[len - 1 - i];
    }
    return len;
}

fn be16(bytes: *const [2]u8) u16 {
    return @as(u16, bytes[0]) << 8 | bytes[1];
}

fn writeBe16(buf: []u8, offset: usize, val: u16) void {
    buf[offset] = @truncate(val >> 8);
    buf[offset + 1] = @truncate(val);
}
