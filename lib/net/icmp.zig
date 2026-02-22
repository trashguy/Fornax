/// ICMP: Internet Control Message Protocol (userspace, struct-based).
///
/// Handles echo request/reply (ping). Each IcmpHandler instance maintains
/// its own connection tracking and stats — no global state.
const ipv4 = @import("ipv4.zig");

pub const TYPE_ECHO_REPLY: u8 = 0;
pub const TYPE_ECHO_REQUEST: u8 = 8;
pub const HEADER_SIZE = 8;
pub const MAX_CONNECTIONS: u8 = 4;
const TIMEOUT_MS: u64 = 3000;

pub const Stats = struct {
    echo_requests_rx: u32 = 0,
    echo_replies_tx: u32 = 0,
    echo_requests_tx: u32 = 0,
    echo_replies_rx: u32 = 0,
};

pub const IcmpConn = struct {
    in_use: bool,
    dst_ip: [4]u8,
    echo_id: u16,
    next_seq: u16,
    got_reply: bool,
    timed_out: bool,
    reply_ttl: u8,
    reply_src: [4]u8,
    reply_seq: u16,
    send_ms: u64,
};

const empty_conn = IcmpConn{
    .in_use = false,
    .dst_ip = .{ 0, 0, 0, 0 },
    .echo_id = 0,
    .next_seq = 0,
    .got_reply = false,
    .timed_out = false,
    .reply_ttl = 0,
    .reply_src = .{ 0, 0, 0, 0 },
    .reply_seq = 0,
    .send_ms = 0,
};

/// Callback for sending an IP packet.
pub const SendIpFn = *const fn (ctx: *anyopaque, dst_ip: [4]u8, ip_packet: []const u8) void;

/// Callback for getting current uptime in milliseconds.
pub const GetTimeFn = *const fn (ctx: *anyopaque) u64;

pub const IcmpHandler = struct {
    connections: [MAX_CONNECTIONS]IcmpConn,
    next_echo_id: u16,
    stats: Stats,

    send_ip: SendIpFn,
    get_time: GetTimeFn,
    cb_ctx: *anyopaque,

    pub fn init(send_ip: SendIpFn, get_time: GetTimeFn, cb_ctx: *anyopaque) IcmpHandler {
        return .{
            .connections = .{empty_conn} ** MAX_CONNECTIONS,
            .next_echo_id = 0x4600, // 'F' prefix for Fornax
            .stats = .{},
            .send_ip = send_ip,
            .get_time = get_time,
            .cb_ctx = cb_ctx,
        };
    }

    pub fn alloc(self: *IcmpHandler) ?u8 {
        for (&self.connections, 0..) |*c, i| {
            if (!c.in_use) {
                c.* = empty_conn;
                c.in_use = true;
                self.next_echo_id +%= 1;
                c.echo_id = self.next_echo_id;
                return @intCast(i);
            }
        }
        return null;
    }

    pub fn setDst(self: *IcmpHandler, idx: u8, ip: [4]u8) void {
        if (idx >= MAX_CONNECTIONS) return;
        self.connections[idx].dst_ip = ip;
    }

    /// Build and send an ICMP echo request. Returns true on success.
    pub fn sendEchoRequest(self: *IcmpHandler, idx: u8, our_ip: [4]u8) bool {
        if (idx >= MAX_CONNECTIONS) return false;
        const c = &self.connections[idx];
        if (!c.in_use) return false;

        // Build ICMP echo request
        var icmp_buf: [64]u8 = undefined;
        icmp_buf[0] = TYPE_ECHO_REQUEST;
        icmp_buf[1] = 0;
        icmp_buf[2] = 0; // checksum placeholder
        icmp_buf[3] = 0;
        icmp_buf[4] = @truncate(c.echo_id >> 8);
        icmp_buf[5] = @truncate(c.echo_id);
        icmp_buf[6] = @truncate(c.next_seq >> 8);
        icmp_buf[7] = @truncate(c.next_seq);

        // 56 bytes of payload (standard ping)
        for (icmp_buf[HEADER_SIZE..]) |*b| {
            b.* = 0x42;
        }

        const pkt_len: usize = 64;
        const cksum = ipv4.computeChecksum(icmp_buf[0..pkt_len]);
        icmp_buf[2] = @truncate(cksum >> 8);
        icmp_buf[3] = @truncate(cksum);

        // Wrap in IP packet
        var ip_buf: [1600]u8 = undefined;
        const ip_len = ipv4.build(&ip_buf, our_ip, c.dst_ip, ipv4.PROTO_ICMP, 64, 0, icmp_buf[0..pkt_len]) orelse return false;

        self.send_ip(self.cb_ctx, c.dst_ip, ip_buf[0..ip_len]);

        c.got_reply = false;
        c.timed_out = false;
        c.send_ms = self.get_time(self.cb_ctx);
        self.stats.echo_requests_tx += 1;
        c.next_seq +%= 1;

        return true;
    }

    pub fn close(self: *IcmpHandler, idx: u8) void {
        if (idx >= MAX_CONNECTIONS) return;
        self.connections[idx] = empty_conn;
    }

    pub fn hasReply(self: *const IcmpHandler, idx: u8) bool {
        if (idx >= MAX_CONNECTIONS) return false;
        return self.connections[idx].got_reply;
    }

    pub fn isTimedOut(self: *const IcmpHandler, idx: u8) bool {
        if (idx >= MAX_CONNECTIONS) return false;
        return self.connections[idx].timed_out;
    }

    pub fn clearTimeout(self: *IcmpHandler, idx: u8) void {
        if (idx >= MAX_CONNECTIONS) return;
        self.connections[idx].timed_out = false;
    }

    /// Format reply text into buf. Returns bytes written.
    /// Format: "64 bytes from IP: seq=S ttl=T\n"
    pub fn getReplyText(self: *IcmpHandler, idx: u8, buf: []u8) u16 {
        if (idx >= MAX_CONNECTIONS) return 0;
        const c = &self.connections[idx];
        if (!c.got_reply) return 0;

        var pos: u16 = 0;

        const size_str = "64 bytes from ";
        if (pos + size_str.len > buf.len) return 0;
        @memcpy(buf[pos..][0..size_str.len], size_str);
        pos += size_str.len;

        pos += formatIp(buf[pos..], c.reply_src);

        const seq_str = ": seq=";
        if (pos + seq_str.len > buf.len) return 0;
        @memcpy(buf[pos..][0..seq_str.len], seq_str);
        pos += seq_str.len;

        pos += formatDec(buf[pos..], c.reply_seq);

        const ttl_str = " ttl=";
        if (pos + ttl_str.len > buf.len) return 0;
        @memcpy(buf[pos..][0..ttl_str.len], ttl_str);
        pos += ttl_str.len;

        pos += formatDec(buf[pos..], c.reply_ttl);

        if (pos < buf.len) {
            buf[pos] = '\n';
            pos += 1;
        }

        c.got_reply = false;
        return pos;
    }

    /// Check for timeouts. Returns list of timed-out connection indices.
    pub fn checkTimeouts(self: *IcmpHandler, timed_out_buf: []u8) u8 {
        var count: u8 = 0;
        const now = self.get_time(self.cb_ctx);

        for (&self.connections, 0..) |*c, i| {
            if (!c.in_use) continue;
            if (!c.got_reply and !c.timed_out and now -% c.send_ms >= TIMEOUT_MS) {
                c.timed_out = true;
                if (count < timed_out_buf.len) {
                    timed_out_buf[count] = @intCast(i);
                    count += 1;
                }
            }
        }
        return count;
    }

    /// Process an incoming ICMP packet.
    /// Returns a reply IP packet in reply_buf (for echo requests), or null.
    pub fn handlePacket(
        self: *IcmpHandler,
        payload: []const u8,
        ip_hdr: ipv4.Header,
        our_ip: [4]u8,
        reply_buf: []u8,
    ) ?usize {
        if (payload.len < HEADER_SIZE) return null;

        // Verify ICMP checksum
        if (ipv4.computeChecksum(payload) != 0) return null;

        const icmp_type = payload[0];

        if (icmp_type == TYPE_ECHO_REQUEST) {
            self.stats.echo_requests_rx += 1;
            return self.buildEchoReply(reply_buf, our_ip, ip_hdr.src, payload);
        }

        if (icmp_type == TYPE_ECHO_REPLY) {
            self.stats.echo_replies_rx += 1;
            self.matchEchoReply(payload, ip_hdr);
        }

        return null;
    }

    /// Returns the index of the connection that matched the reply, or null.
    fn matchEchoReply(self: *IcmpHandler, payload: []const u8, ip_hdr: ipv4.Header) void {
        if (payload.len < HEADER_SIZE) return;

        const reply_id = @as(u16, payload[4]) << 8 | payload[5];
        const reply_seq = @as(u16, payload[6]) << 8 | payload[7];

        for (&self.connections) |*c| {
            if (!c.in_use) continue;
            if (c.echo_id == reply_id) {
                c.got_reply = true;
                c.reply_ttl = ip_hdr.ttl;
                c.reply_src = ip_hdr.src;
                c.reply_seq = reply_seq;
                return;
            }
        }
    }

    fn buildEchoReply(self: *IcmpHandler, buf: []u8, our_ip: [4]u8, dst_ip: [4]u8, request: []const u8) ?usize {
        if (request.len < HEADER_SIZE) return null;

        var icmp_buf: [1500]u8 = undefined;
        if (request.len > icmp_buf.len) return null;

        @memcpy(icmp_buf[0..request.len], request);
        icmp_buf[0] = TYPE_ECHO_REPLY;
        icmp_buf[1] = 0;
        icmp_buf[2] = 0;
        icmp_buf[3] = 0;

        const cksum = ipv4.computeChecksum(icmp_buf[0..request.len]);
        icmp_buf[2] = @truncate(cksum >> 8);
        icmp_buf[3] = @truncate(cksum);

        self.stats.echo_replies_tx += 1;

        return ipv4.build(buf, our_ip, dst_ip, ipv4.PROTO_ICMP, 64, 0, icmp_buf[0..request.len]);
    }
};

fn formatDec(buf: []u8, val: anytype) u16 {
    var v: u32 = @intCast(val);
    var tmp: [10]u8 = undefined;
    var len: u16 = 0;
    if (v == 0) {
        if (buf.len > 0) buf[0] = '0';
        return 1;
    }
    while (v > 0) : (len += 1) {
        tmp[len] = @truncate('0' + (v % 10));
        v /= 10;
    }
    var i: u16 = 0;
    while (i < len) : (i += 1) {
        if (i < buf.len) buf[i] = tmp[len - 1 - i];
    }
    return len;
}

fn formatIp(buf: []u8, ip: [4]u8) u16 {
    var pos: u16 = 0;
    for (ip, 0..) |octet, i| {
        pos += formatDec(buf[pos..], octet);
        if (i < 3 and pos < buf.len) {
            buf[pos] = '.';
            pos += 1;
        }
    }
    return pos;
}
