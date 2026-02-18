/// DNS resolver: kernel-side A record lookups over UDP.
///
/// Uses the existing kernel UDP stack. Queries a nameserver (default 10.0.2.3,
/// QEMU user-mode DNS forwarder) and caches results with TTL expiry.
const klog = @import("../klog.zig");
const process = @import("../process.zig");
const timer = @import("../timer.zig");

const net = @import("../net.zig");
const udp = @import("udp.zig");

const MAX_CACHE = 32;
const DNS_PORT: u16 = 53;
const MAX_NAME_LEN = 128;

var nameserver: [4]u8 = .{ 10, 0, 2, 3 }; // QEMU default
var udp_conn: ?usize = null;
var query_id: u16 = 1;

// Pending query state
var pending_name: [MAX_NAME_LEN]u8 = undefined;
var pending_name_len: u8 = 0;
var pending_qid: u16 = 0;
var pending_waiter_pid: u16 = 0;
var pending_result: ?[4]u8 = null;
var pending_send_tick: u32 = 0;
var pending_retries: u8 = 0;

const DNS_RETRY_TICKS: u32 = 18; // ~1 second
const DNS_MAX_RETRIES: u8 = 5;

// Cache
const CacheEntry = struct {
    name: [MAX_NAME_LEN]u8,
    name_len: u8,
    ip: [4]u8,
    expire_tick: u32, // tick at which this entry expires
    valid: bool,
};

var cache: [MAX_CACHE]CacheEntry linksection(".bss") = undefined;

pub fn init() void {
    for (&cache) |*e| {
        e.valid = false;
        e.name_len = 0;
    }
    udp_conn = udp.alloc();
    if (udp_conn) |conn| {
        // Bind to a known port so responses are delivered back to us
        _ = udp.bind(conn, 10000);
    } else {
        klog.warn("dns: failed to allocate UDP connection\n");
    }
}

pub fn setNameserver(ip: [4]u8) void {
    nameserver = ip;
}

/// Look up a name in cache. Returns IP if cached and not expired.
pub fn cacheLookup(name: []const u8) ?[4]u8 {
    const now = timer.getTicks();
    for (&cache) |*e| {
        if (!e.valid) continue;
        if (e.name_len != name.len) continue;
        if (!strEql(e.name[0..e.name_len], name)) continue;
        if (now >= e.expire_tick) {
            e.valid = false; // expired
            continue;
        }
        return e.ip;
    }
    return null;
}

/// Send a DNS query for an A record. Non-blocking; result arrives via checkForResponse().
pub fn query(name: []const u8) bool {
    if (name.len == 0 or name.len > MAX_NAME_LEN) return false;

    // Check cache first
    if (cacheLookup(name)) |_| return true;

    const conn = udp_conn orelse return false;

    // Build DNS query packet
    var buf: [512]u8 = undefined;
    const len = buildQuery(&buf, name) orelse return false;

    @memcpy(pending_name[0..name.len], name);
    pending_name_len = @intCast(name.len);
    pending_qid = query_id -% 1; // buildQuery already incremented
    pending_result = null;
    pending_send_tick = timer.getTicks();
    pending_retries = 0;

    // Send via UDP
    const src_port = 10000 + @as(u16, @intCast(conn));
    _ = net.sendUdp(nameserver, src_port, DNS_PORT, buf[0..len]);

    klog.debug("dns: query sent for ");
    klog.debug(name);
    klog.debug("\n");
    return true;
}

/// Set the PID that's waiting for a DNS response.
pub fn setWaiter(pid: u16) void {
    pending_waiter_pid = pid;
}

/// Get the result of the last query.
pub fn getResult() ?[4]u8 {
    return pending_result;
}

/// Check for DNS responses on the UDP connection. Retries on timeout.
pub fn checkForResponse() void {
    const conn = udp_conn orelse return;

    if (udp.recv(conn)) |resp| {
        parseResponse(resp.data);
        return;
    }

    // No response yet — check if we should retry the pending query
    if (pending_name_len > 0 and pending_result == null) {
        const now = timer.getTicks();
        if (now -% pending_send_tick >= DNS_RETRY_TICKS) {
            if (pending_retries >= DNS_MAX_RETRIES) {
                klog.debug("dns: query timeout\n");
                wakeWaiter(true);
                pending_name_len = 0;
                return;
            }

            // Rebuild and resend
            var buf: [512]u8 = undefined;
            const len = buildQuery(&buf, pending_name[0..pending_name_len]) orelse return;
            pending_qid = query_id -% 1;

            const src_port = 10000 + @as(u16, @intCast(conn));
            _ = net.sendUdp(nameserver, src_port, DNS_PORT, buf[0..len]);

            pending_send_tick = now;
            pending_retries += 1;

            klog.debug("dns: retry #");
            klog.debugDec(pending_retries);
            klog.debug("\n");
        }
    }
}

/// Format cache contents into a text buffer for /net/dns/cache reads.
pub fn getCacheText(buf: []u8) u16 {
    var pos: u16 = 0;
    const now = timer.getTicks();

    for (&cache) |*e| {
        if (!e.valid) continue;
        if (now >= e.expire_tick) {
            e.valid = false;
            continue;
        }
        // Format: "name IP ttl\n"
        if (pos + e.name_len + 30 > buf.len) break;

        @memcpy(buf[pos..][0..e.name_len], e.name[0..e.name_len]);
        pos += e.name_len;
        buf[pos] = ' ';
        pos += 1;
        pos += formatIp(buf[pos..], e.ip);
        buf[pos] = ' ';
        pos += 1;
        const ttl_secs = (e.expire_tick -% now) / timer.TICKS_PER_SEC;
        pos += formatDec(buf[pos..], ttl_secs);
        buf[pos] = '\n';
        pos += 1;
    }
    return pos;
}

// ── DNS packet building/parsing ─────────────────────────────────────

fn buildQuery(buf: []u8, name: []const u8) ?usize {
    if (buf.len < 512) return null;

    // Header (12 bytes)
    const qid = query_id;
    query_id +%= 1;
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
    // Last label (after final dot, or if no trailing dot)
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

fn parseResponse(data: []const u8) void {
    if (data.len < 12) return;

    const resp_id = be16(data[0..2]);
    const flags = be16(data[2..4]);
    _ = flags;

    // Check if this matches our pending query
    if (resp_id != pending_qid) return;

    const ancount = be16(data[6..8]);
    if (ancount == 0) {
        klog.debug("dns: no answers\n");
        wakeWaiter(true);
        return;
    }

    // Skip question section
    var pos: usize = 12;
    // Skip QNAME
    while (pos < data.len) {
        const len = data[pos];
        if (len == 0) {
            pos += 1;
            break;
        }
        if (len & 0xC0 == 0xC0) {
            pos += 2; // compressed pointer
            break;
        }
        pos += 1 + @as(usize, len);
    }
    pos += 4; // skip QTYPE + QCLASS

    // Parse answer RRs — look for A record
    var i: u16 = 0;
    while (i < ancount and pos + 10 < data.len) : (i += 1) {
        // Skip NAME (may be compressed)
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
        const rclass = be16(data[pos..][0..2]);
        _ = rclass;
        pos += 2;
        const ttl = be32(data, pos);
        pos += 4;
        const rdlength = be16(data[pos..][0..2]);
        pos += 2;

        if (rtype == 1 and rdlength == 4 and pos + 4 <= data.len) {
            // A record
            const ip: [4]u8 = data[pos..][0..4].*;
            cacheInsert(pending_name[0..pending_name_len], ip, ttl);
            pending_result = ip;

            klog.debug("dns: resolved ");
            klog.debug(pending_name[0..pending_name_len]);
            klog.debug(" -> ");
            net.printIpDebug(ip);
            klog.debug("\n");

            wakeWaiter(false);
            return;
        }
        pos += rdlength;
    }

    klog.debug("dns: no A record found\n");
    wakeWaiter(true);
}

fn cacheInsert(name: []const u8, ip: [4]u8, ttl: u32) void {
    // Find an empty slot or the oldest entry
    var slot: ?*CacheEntry = null;
    for (&cache) |*e| {
        if (!e.valid) {
            slot = e;
            break;
        }
    }
    // If no empty slot, evict first expired or just first
    if (slot == null) {
        const now = timer.getTicks();
        for (&cache) |*e| {
            if (now >= e.expire_tick) {
                slot = e;
                break;
            }
        }
        if (slot == null) {
            slot = &cache[0]; // LRU eviction fallback
        }
    }

    const entry = slot.?;
    @memcpy(entry.name[0..name.len], name);
    entry.name_len = @intCast(name.len);
    entry.ip = ip;
    // Cap TTL at ~10 minutes to avoid overflow
    const capped_ttl = @min(ttl, 600);
    entry.expire_tick = timer.getTicks() +% (capped_ttl * timer.TICKS_PER_SEC);
    entry.valid = true;
}

fn wakeWaiter(is_error: bool) void {
    if (pending_waiter_pid == 0) return;
    const pid = pending_waiter_pid;
    pending_waiter_pid = 0;

    if (process.getByPid(pid)) |proc| {
        if (proc.state == .blocked) {
            if (is_error) {
                proc.syscall_ret = 0xFFFF_FFFF_FFFF_FFF6; // -ENOENT equivalent
            }
            process.markReady(proc);
        }
    }
}

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

// ── Formatting helpers ──────────────────────────────────────────────

fn formatIp(buf: []u8, ip: [4]u8) u16 {
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

fn formatDec(buf: []u8, val: u32) u16 {
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
    // Reverse
    var i: u16 = 0;
    while (i < len) : (i += 1) {
        buf[i] = tmp[len - 1 - i];
    }
    return len;
}

// ── Byte order helpers ──────────────────────────────────────────────

fn be16(bytes: *const [2]u8) u16 {
    return @as(u16, bytes[0]) << 8 | bytes[1];
}

fn be32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) << 24 |
        @as(u32, bytes[offset + 1]) << 16 |
        @as(u32, bytes[offset + 2]) << 8 |
        bytes[offset + 3];
}

fn writeBe16(buf: []u8, offset: usize, val: u16) void {
    buf[offset] = @truncate(val >> 8);
    buf[offset + 1] = @truncate(val);
}
