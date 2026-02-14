/// IPv4: Internet Protocol version 4.
///
/// Parses and builds IPv4 packets. Computes header checksums.
/// Minimal implementation: no fragmentation, no options.
const serial = @import("../serial.zig");

pub const PROTO_ICMP: u8 = 1;
pub const PROTO_TCP: u8 = 6;
pub const PROTO_UDP: u8 = 17;

pub const HEADER_SIZE = 20; // no options

pub const Header = struct {
    version_ihl: u8,
    tos: u8,
    total_length: u16,
    identification: u16,
    flags_fragment: u16,
    ttl: u8,
    protocol: u8,
    checksum: u16,
    src: [4]u8,
    dst: [4]u8,
};

pub const ParseResult = struct {
    header: Header,
    payload: []const u8,
};

/// Parse an IPv4 packet from raw bytes.
pub fn parse(data: []const u8) ?ParseResult {
    if (data.len < HEADER_SIZE) return null;

    const version_ihl = data[0];
    const version = version_ihl >> 4;
    if (version != 4) return null;

    const ihl = version_ihl & 0x0F;
    if (ihl < 5) return null;

    const header_len: usize = @as(usize, ihl) * 4;
    if (data.len < header_len) return null;

    const total_length = be16(data[2..4]);
    if (total_length < header_len) return null;

    // Verify checksum
    if (computeChecksum(data[0..header_len]) != 0) {
        serial.puts("ipv4: bad checksum\n");
        return null;
    }

    const actual_len = @min(data.len, @as(usize, total_length));
    const payload_start = header_len;
    if (actual_len <= payload_start) return null;

    return ParseResult{
        .header = Header{
            .version_ihl = version_ihl,
            .tos = data[1],
            .total_length = total_length,
            .identification = be16(data[4..6]),
            .flags_fragment = be16(data[6..8]),
            .ttl = data[8],
            .protocol = data[9],
            .checksum = be16(data[10..12]),
            .src = data[12..16].*,
            .dst = data[16..20].*,
        },
        .payload = data[payload_start..actual_len],
    };
}

var packet_id: u16 = 0;

/// Build an IPv4 packet into the provided buffer.
/// Returns total IP packet length, or null if buffer too small.
pub fn build(buf: []u8, src: [4]u8, dst: [4]u8, protocol: u8, payload: []const u8) ?usize {
    const total_len = HEADER_SIZE + payload.len;
    if (total_len > buf.len or total_len > 65535) return null;

    const total: u16 = @intCast(total_len);
    packet_id +%= 1;

    buf[0] = 0x45; // version 4, IHL 5
    buf[1] = 0; // TOS
    writeBe16(buf, 2, total);
    writeBe16(buf, 4, packet_id);
    writeBe16(buf, 6, 0x4000); // Don't Fragment
    buf[8] = 64; // TTL
    buf[9] = protocol;
    writeBe16(buf, 10, 0); // checksum placeholder
    @memcpy(buf[12..16], &src);
    @memcpy(buf[16..20], &dst);

    // Compute and fill checksum
    const cksum = computeChecksum(buf[0..HEADER_SIZE]);
    writeBe16(buf, 10, cksum);

    // Copy payload
    @memcpy(buf[HEADER_SIZE..][0..payload.len], payload);

    return total_len;
}

/// Internet checksum (RFC 1071).
pub fn computeChecksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) {
        sum += @as(u32, data[i]) << 8 | data[i + 1];
    }
    if (i < data.len) {
        sum += @as(u32, data[i]) << 8;
    }
    // Fold carry
    while (sum >> 16 != 0) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    return @truncate(~sum);
}

pub fn ipEqual(a: [4]u8, b: [4]u8) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2] and a[3] == b[3];
}

fn be16(bytes: *const [2]u8) u16 {
    return @as(u16, bytes[0]) << 8 | bytes[1];
}

fn writeBe16(buf: []u8, offset: usize, val: u16) void {
    buf[offset] = @truncate(val >> 8);
    buf[offset + 1] = @truncate(val);
}
