/// DHCP client packet builder/parser per RFC 2131.
///
/// Provides buildDiscover(), buildRequest() for client→server packets
/// and parseReply() for server→client OFFER/ACK responses.
const ipv4 = @import("ipv4.zig");

// DHCP message types (option 53)
pub const MSG_DISCOVER: u8 = 1;
pub const MSG_OFFER: u8 = 2;
pub const MSG_REQUEST: u8 = 3;
pub const MSG_ACK: u8 = 5;
pub const MSG_NAK: u8 = 6;

// DHCP ports
pub const CLIENT_PORT: u16 = 68;
pub const SERVER_PORT: u16 = 67;

// DHCP magic cookie
const MAGIC_COOKIE: [4]u8 = .{ 0x63, 0x82, 0x53, 0x63 };

// Minimum DHCP packet size (without options)
const DHCP_HEADER_SIZE: usize = 236;

// Option codes
const OPT_SUBNET_MASK: u8 = 1;
const OPT_ROUTER: u8 = 3;
const OPT_DNS: u8 = 6;
const OPT_LEASE_TIME: u8 = 51;
const OPT_MSG_TYPE: u8 = 53;
const OPT_SERVER_ID: u8 = 54;
const OPT_PARAM_LIST: u8 = 55;
const OPT_END: u8 = 255;

pub const DhcpReply = struct {
    msg_type: u8, // MSG_OFFER or MSG_ACK
    your_ip: [4]u8, // yiaddr — offered/assigned IP
    server_ip: [4]u8, // siaddr or option 54
    subnet_mask: [4]u8,
    router: [4]u8,
    dns: [4]u8,
    lease_time: u32, // seconds
};

/// Build a DHCP DISCOVER packet.
/// Returns the number of bytes written to buf, or null if buf is too small.
pub fn buildDiscover(mac: [6]u8, xid: u32, buf: []u8) ?usize {
    const min_size = DHCP_HEADER_SIZE + 4 + 9 + 1; // header + cookie + options + end
    if (buf.len < min_size) return null;

    // Zero out the header area
    for (buf[0..DHCP_HEADER_SIZE]) |*b| b.* = 0;

    buf[0] = 1; // op: BOOTREQUEST
    buf[1] = 1; // htype: Ethernet
    buf[2] = 6; // hlen: MAC length
    buf[3] = 0; // hops

    // xid
    buf[4] = @truncate(xid >> 24);
    buf[5] = @truncate(xid >> 16);
    buf[6] = @truncate(xid >> 8);
    buf[7] = @truncate(xid);

    // flags: broadcast (0x8000) — ensures reply comes as broadcast
    buf[10] = 0x80;
    buf[11] = 0x00;

    // chaddr (client hardware address)
    @memcpy(buf[28..34], &mac);

    // Magic cookie
    @memcpy(buf[DHCP_HEADER_SIZE..][0..4], &MAGIC_COOKIE);

    // Options
    var pos: usize = DHCP_HEADER_SIZE + 4;

    // Option 53: DHCP Message Type = DISCOVER
    buf[pos] = OPT_MSG_TYPE;
    buf[pos + 1] = 1;
    buf[pos + 2] = MSG_DISCOVER;
    pos += 3;

    // Option 55: Parameter Request List
    buf[pos] = OPT_PARAM_LIST;
    buf[pos + 1] = 4;
    buf[pos + 2] = OPT_SUBNET_MASK;
    buf[pos + 3] = OPT_ROUTER;
    buf[pos + 4] = OPT_DNS;
    buf[pos + 5] = OPT_LEASE_TIME;
    pos += 6;

    // End
    buf[pos] = OPT_END;
    pos += 1;

    // Pad to minimum BOOTP size (300 bytes)
    while (pos < 300 and pos < buf.len) {
        buf[pos] = 0;
        pos += 1;
    }

    return pos;
}

/// Build a DHCP REQUEST packet (in response to an OFFER).
/// Returns the number of bytes written to buf, or null if buf is too small.
pub fn buildRequest(mac: [6]u8, xid: u32, offered_ip: [4]u8, server_ip: [4]u8, buf: []u8) ?usize {
    const min_size = DHCP_HEADER_SIZE + 4 + 15 + 1; // header + cookie + options + end
    if (buf.len < min_size) return null;

    // Zero out the header area
    for (buf[0..DHCP_HEADER_SIZE]) |*b| b.* = 0;

    buf[0] = 1; // op: BOOTREQUEST
    buf[1] = 1; // htype: Ethernet
    buf[2] = 6; // hlen
    buf[3] = 0; // hops

    // xid
    buf[4] = @truncate(xid >> 24);
    buf[5] = @truncate(xid >> 16);
    buf[6] = @truncate(xid >> 8);
    buf[7] = @truncate(xid);

    // flags: broadcast
    buf[10] = 0x80;
    buf[11] = 0x00;

    // chaddr
    @memcpy(buf[28..34], &mac);

    // Magic cookie
    @memcpy(buf[DHCP_HEADER_SIZE..][0..4], &MAGIC_COOKIE);

    // Options
    var pos: usize = DHCP_HEADER_SIZE + 4;

    // Option 53: DHCP Message Type = REQUEST
    buf[pos] = OPT_MSG_TYPE;
    buf[pos + 1] = 1;
    buf[pos + 2] = MSG_REQUEST;
    pos += 3;

    // Option 50: Requested IP Address
    buf[pos] = 50; // option code
    buf[pos + 1] = 4;
    @memcpy(buf[pos + 2 ..][0..4], &offered_ip);
    pos += 6;

    // Option 54: Server Identifier
    buf[pos] = OPT_SERVER_ID;
    buf[pos + 1] = 4;
    @memcpy(buf[pos + 2 ..][0..4], &server_ip);
    pos += 6;

    // End
    buf[pos] = OPT_END;
    pos += 1;

    // Pad to minimum BOOTP size (300 bytes)
    while (pos < 300 and pos < buf.len) {
        buf[pos] = 0;
        pos += 1;
    }

    return pos;
}

/// Parse a DHCP reply (OFFER or ACK) from raw DHCP payload.
/// The payload should start at the DHCP/BOOTP header (after UDP).
pub fn parseReply(data: []const u8) ?DhcpReply {
    if (data.len < DHCP_HEADER_SIZE + 4) return null;

    // Check op == BOOTREPLY
    if (data[0] != 2) return null;

    // Verify magic cookie
    if (data[DHCP_HEADER_SIZE] != MAGIC_COOKIE[0] or
        data[DHCP_HEADER_SIZE + 1] != MAGIC_COOKIE[1] or
        data[DHCP_HEADER_SIZE + 2] != MAGIC_COOKIE[2] or
        data[DHCP_HEADER_SIZE + 3] != MAGIC_COOKIE[3])
        return null;

    var reply = DhcpReply{
        .msg_type = 0,
        .your_ip = .{ 0, 0, 0, 0 },
        .server_ip = .{ 0, 0, 0, 0 },
        .subnet_mask = .{ 255, 255, 255, 0 },
        .router = .{ 0, 0, 0, 0 },
        .dns = .{ 0, 0, 0, 0 },
        .lease_time = 0,
    };

    // yiaddr (bytes 16-19)
    reply.your_ip[0] = data[16];
    reply.your_ip[1] = data[17];
    reply.your_ip[2] = data[18];
    reply.your_ip[3] = data[19];

    // siaddr (bytes 20-23) — default server IP
    reply.server_ip[0] = data[20];
    reply.server_ip[1] = data[21];
    reply.server_ip[2] = data[22];
    reply.server_ip[3] = data[23];

    // Parse options (after magic cookie)
    var pos: usize = DHCP_HEADER_SIZE + 4;
    while (pos < data.len) {
        const opt = data[pos];
        if (opt == OPT_END) break;
        if (opt == 0) {
            // Padding
            pos += 1;
            continue;
        }

        pos += 1;
        if (pos >= data.len) break;
        const opt_len = data[pos];
        pos += 1;

        if (pos + opt_len > data.len) break;
        const opt_data = data[pos..][0..opt_len];

        switch (opt) {
            OPT_MSG_TYPE => {
                if (opt_len >= 1) reply.msg_type = opt_data[0];
            },
            OPT_SUBNET_MASK => {
                if (opt_len >= 4) {
                    reply.subnet_mask[0] = opt_data[0];
                    reply.subnet_mask[1] = opt_data[1];
                    reply.subnet_mask[2] = opt_data[2];
                    reply.subnet_mask[3] = opt_data[3];
                }
            },
            OPT_ROUTER => {
                if (opt_len >= 4) {
                    reply.router[0] = opt_data[0];
                    reply.router[1] = opt_data[1];
                    reply.router[2] = opt_data[2];
                    reply.router[3] = opt_data[3];
                }
            },
            OPT_DNS => {
                if (opt_len >= 4) {
                    reply.dns[0] = opt_data[0];
                    reply.dns[1] = opt_data[1];
                    reply.dns[2] = opt_data[2];
                    reply.dns[3] = opt_data[3];
                }
            },
            OPT_LEASE_TIME => {
                if (opt_len >= 4) {
                    reply.lease_time = @as(u32, opt_data[0]) << 24 |
                        @as(u32, opt_data[1]) << 16 |
                        @as(u32, opt_data[2]) << 8 |
                        @as(u32, opt_data[3]);
                }
            },
            OPT_SERVER_ID => {
                if (opt_len >= 4) {
                    reply.server_ip[0] = opt_data[0];
                    reply.server_ip[1] = opt_data[1];
                    reply.server_ip[2] = opt_data[2];
                    reply.server_ip[3] = opt_data[3];
                }
            },
            else => {},
        }

        pos += opt_len;
    }

    // Must have a message type
    if (reply.msg_type == 0) return null;

    return reply;
}
