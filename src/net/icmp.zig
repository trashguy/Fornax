/// ICMP: Internet Control Message Protocol.
///
/// Handles echo request/reply (ping). When we receive an echo request
/// addressed to us, we build an echo reply.
const ipv4 = @import("ipv4.zig");
const serial = @import("../serial.zig");

const TYPE_ECHO_REPLY: u8 = 0;
const TYPE_ECHO_REQUEST: u8 = 8;

const HEADER_SIZE = 8; // type(1) + code(1) + checksum(2) + id(2) + seq(2)

pub var stats = Stats{};

pub const Stats = struct {
    echo_requests_rx: u32 = 0,
    echo_replies_tx: u32 = 0,
    echo_requests_tx: u32 = 0,
    echo_replies_rx: u32 = 0,
};

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
        serial.puts("icmp: bad checksum\n");
        return null;
    }

    const icmp_type = payload[0];
    // const code = payload[1];

    if (icmp_type == TYPE_ECHO_REQUEST) {
        stats.echo_requests_rx += 1;
        serial.puts("icmp: echo request from ");
        printIp(ip_hdr.src);
        serial.puts("\n");

        // Build echo reply: same payload, swap type
        return buildEchoReply(reply_buf, our_ip, ip_hdr.src, payload);
    }

    if (icmp_type == TYPE_ECHO_REPLY) {
        stats.echo_replies_rx += 1;
        serial.puts("icmp: echo reply from ");
        printIp(ip_hdr.src);
        serial.puts("\n");
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

fn printIp(ip: [4]u8) void {
    serial.putDec(ip[0]);
    serial.putChar('.');
    serial.putDec(ip[1]);
    serial.putChar('.');
    serial.putDec(ip[2]);
    serial.putChar('.');
    serial.putDec(ip[3]);
}
