/// ICMP: Internet Control Message Protocol.
///
/// Handles echo request/reply (ping). When we receive an echo request
/// addressed to us, we build an echo reply. Also provides connection
/// tracking for outgoing echo requests (userspace ping).
const ipv4 = @import("ipv4.zig");
const klog = @import("../klog.zig");
const process = @import("../process.zig");
const timer = @import("../timer.zig");

const TYPE_ECHO_REPLY: u8 = 0;
const TYPE_ECHO_REQUEST: u8 = 8;

const HEADER_SIZE = 8; // type(1) + code(1) + checksum(2) + id(2) + seq(2)
const MAX_CONNECTIONS: u8 = 4;
const TIMEOUT_TICKS: u32 = 54; // ~3 seconds at 18 Hz

pub var stats = Stats{};

pub const Stats = struct {
    echo_requests_rx: u32 = 0,
    echo_replies_tx: u32 = 0,
    echo_requests_tx: u32 = 0,
    echo_replies_rx: u32 = 0,
};

const IcmpConn = struct {
    in_use: bool,
    dst_ip: [4]u8,
    echo_id: u16,
    next_seq: u16,
    got_reply: bool,
    timed_out: bool,
    reply_ttl: u8,
    reply_src: [4]u8,
    reply_seq: u16,
    waiter_pid: u16,
    send_tick: u32,
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
    .waiter_pid = 0,
    .send_tick = 0,
};

var connections: [MAX_CONNECTIONS]IcmpConn = .{empty_conn} ** MAX_CONNECTIONS;
var next_echo_id: u16 = 0x4600; // 'F' prefix for Fornax

pub fn alloc() ?u8 {
    for (&connections, 0..) |*c, i| {
        if (!c.in_use) {
            c.* = empty_conn;
            c.in_use = true;
            next_echo_id +%= 1;
            c.echo_id = next_echo_id;
            return @intCast(i);
        }
    }
    return null;
}

pub fn setDst(idx: u8, ip: [4]u8) void {
    if (idx >= MAX_CONNECTIONS) return;
    connections[idx].dst_ip = ip;
}

/// Build and send an ICMP echo request. Returns true on success.
pub fn sendEchoRequest(idx: u8, our_ip: [4]u8) bool {
    if (idx >= MAX_CONNECTIONS) return false;
    const c = &connections[idx];
    if (!c.in_use) return false;

    // Build ICMP echo request: type=8, code=0, checksum, id, seq
    var icmp_buf: [64]u8 = undefined;
    icmp_buf[0] = TYPE_ECHO_REQUEST;
    icmp_buf[1] = 0; // code
    icmp_buf[2] = 0; // checksum placeholder
    icmp_buf[3] = 0;
    // ID (big-endian)
    icmp_buf[4] = @truncate(c.echo_id >> 8);
    icmp_buf[5] = @truncate(c.echo_id);
    // Sequence (big-endian)
    icmp_buf[6] = @truncate(c.next_seq >> 8);
    icmp_buf[7] = @truncate(c.next_seq);

    // 56 bytes of payload data (standard ping size)
    for (icmp_buf[HEADER_SIZE..]) |*b| {
        b.* = 0x42;
    }

    const pkt_len: usize = 64;

    // Compute ICMP checksum
    const cksum = ipv4.computeChecksum(icmp_buf[0..pkt_len]);
    icmp_buf[2] = @truncate(cksum >> 8);
    icmp_buf[3] = @truncate(cksum);

    // Wrap in IP packet
    var ip_buf: [1600]u8 = undefined;
    const ip_len = ipv4.build(&ip_buf, our_ip, c.dst_ip, ipv4.PROTO_ICMP, icmp_buf[0..pkt_len]) orelse return false;

    // Send via net module
    const net = @import("../net.zig");
    net.sendIpPacket(c.dst_ip, ip_buf[0..ip_len]);

    c.got_reply = false;
    c.timed_out = false;
    c.send_tick = timer.getTicks();
    stats.echo_requests_tx += 1;
    c.next_seq +%= 1;

    klog.debug("icmp: sent echo request to ");
    printIp(c.dst_ip);
    klog.debug(" seq=");
    klog.debugDec(c.next_seq -% 1);
    klog.debug("\n");

    return true;
}

pub fn close(idx: u8) void {
    if (idx >= MAX_CONNECTIONS) return;
    connections[idx] = empty_conn;
}

pub fn setReadWaiter(idx: u8, pid: u16) void {
    if (idx >= MAX_CONNECTIONS) return;
    connections[idx].waiter_pid = pid;
}

pub fn hasReply(idx: u8) bool {
    if (idx >= MAX_CONNECTIONS) return false;
    return connections[idx].got_reply;
}

pub fn isTimedOut(idx: u8) bool {
    if (idx >= MAX_CONNECTIONS) return false;
    return connections[idx].timed_out;
}

pub fn clearTimeout(idx: u8) void {
    if (idx >= MAX_CONNECTIONS) return;
    connections[idx].timed_out = false;
}

/// Format reply text into buf. Returns number of bytes written.
/// Format: "N bytes from IP: seq=S ttl=T\n"
pub fn getReplyText(idx: u8, buf: []u8) u16 {
    if (idx >= MAX_CONNECTIONS) return 0;
    const c = &connections[idx];
    if (!c.got_reply) return 0;

    var pos: u16 = 0;

    // "64 bytes from "
    const size_str = "64 bytes from ";
    if (pos + size_str.len > buf.len) return 0;
    @memcpy(buf[pos..][0..size_str.len], size_str);
    pos += size_str.len;

    // IP address
    pos += formatIp(buf[pos..], c.reply_src);

    // ": seq="
    const seq_str = ": seq=";
    if (pos + seq_str.len > buf.len) return 0;
    @memcpy(buf[pos..][0..seq_str.len], seq_str);
    pos += seq_str.len;

    // Sequence number
    pos += formatDec(buf[pos..], c.reply_seq);

    // " ttl="
    const ttl_str = " ttl=";
    if (pos + ttl_str.len > buf.len) return 0;
    @memcpy(buf[pos..][0..ttl_str.len], ttl_str);
    pos += ttl_str.len;

    // TTL
    pos += formatDec(buf[pos..], c.reply_ttl);

    // newline
    if (pos < buf.len) {
        buf[pos] = '\n';
        pos += 1;
    }

    c.got_reply = false;
    return pos;
}

/// Check for ICMP read timeouts and wake blocked waiters.
pub fn checkTimeouts(current_tick: u32) void {
    for (&connections) |*c| {
        if (!c.in_use or c.waiter_pid == 0) continue;
        if (!c.got_reply and current_tick -% c.send_tick >= TIMEOUT_TICKS) {
            // Timeout — wake waiter with timeout indication
            klog.debug("icmp: timeout for echo request\n");
            c.timed_out = true;
            wakeWaiter(&c.waiter_pid);
        }
    }
}

/// Match an incoming echo reply to a connection. Called from handlePacket.
fn matchEchoReply(payload: []const u8, ip_hdr: ipv4.Header) void {
    if (payload.len < HEADER_SIZE) return;

    // Extract echo ID and sequence from reply
    const reply_id = @as(u16, payload[4]) << 8 | payload[5];
    const reply_seq = @as(u16, payload[6]) << 8 | payload[7];

    for (&connections) |*c| {
        if (!c.in_use) continue;
        if (c.echo_id == reply_id) {
            c.got_reply = true;
            c.reply_ttl = ip_hdr.ttl;
            c.reply_src = ip_hdr.src;
            c.reply_seq = reply_seq;
            klog.debug("icmp: matched echo reply to conn, seq=");
            klog.debugDec(reply_seq);
            klog.debug("\n");
            wakeWaiter(&c.waiter_pid);
            return;
        }
    }
}

fn wakeWaiter(waiter_pid: *u16) void {
    if (waiter_pid.* == 0) return;
    const pid = waiter_pid.*;
    waiter_pid.* = 0;

    if (process.getByPid(pid)) |proc| {
        if (proc.state == .blocked) {
            process.markReady(proc);
        }
    }
}

/// Process an incoming ICMP packet. Returns a reply IP packet in `reply_buf`, or null.
/// `payload` is the ICMP data (after IP header).
/// `ip_hdr` is the parsed IP header of the incoming packet.
pub fn handlePacket(
    payload: []const u8,
    ip_hdr: ipv4.Header,
    our_ip: [4]u8,
    reply_buf: []u8,
) ?usize {
    if (payload.len < HEADER_SIZE) return null;

    // Verify ICMP checksum
    if (ipv4.computeChecksum(payload) != 0) {
        klog.debug("icmp: bad checksum\n");
        return null;
    }

    const icmp_type = payload[0];

    if (icmp_type == TYPE_ECHO_REQUEST) {
        stats.echo_requests_rx += 1;
        klog.debug("icmp: echo request from ");
        printIp(ip_hdr.src);
        klog.debug("\n");

        // Build echo reply: same payload, swap type
        return buildEchoReply(reply_buf, our_ip, ip_hdr.src, payload);
    }

    if (icmp_type == TYPE_ECHO_REPLY) {
        stats.echo_replies_rx += 1;
        klog.debug("icmp: echo reply from ");
        printIp(ip_hdr.src);
        klog.debug("\n");

        // Try to match to a connection
        matchEchoReply(payload, ip_hdr);
    }

    return null;
}

fn buildEchoReply(buf: []u8, our_ip: [4]u8, dst_ip: [4]u8, request: []const u8) ?usize {
    if (request.len < HEADER_SIZE) return null;

    // Build ICMP reply: type=0 (reply), code=0, same id/seq/data
    var icmp_buf: [1500]u8 = undefined;
    if (request.len > icmp_buf.len) return null;

    @memcpy(icmp_buf[0..request.len], request);
    icmp_buf[0] = TYPE_ECHO_REPLY; // change type
    icmp_buf[1] = 0; // code
    icmp_buf[2] = 0; // zero checksum for computation
    icmp_buf[3] = 0;

    const cksum = ipv4.computeChecksum(icmp_buf[0..request.len]);
    icmp_buf[2] = @truncate(cksum >> 8);
    icmp_buf[3] = @truncate(cksum);

    stats.echo_replies_tx += 1;

    return ipv4.build(buf, our_ip, dst_ip, ipv4.PROTO_ICMP, icmp_buf[0..request.len]);
}

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

fn printIp(ip: [4]u8) void {
    klog.debugDec(ip[0]);
    klog.debug(".");
    klog.debugDec(ip[1]);
    klog.debug(".");
    klog.debugDec(ip[2]);
    klog.debug(".");
    klog.debugDec(ip[3]);
}
