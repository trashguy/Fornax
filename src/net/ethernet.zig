/// Ethernet frame parsing and building.
///
/// Frame layout: [dst MAC 6][src MAC 6][EtherType 2][payload 46-1500]
pub const ETHER_ARP: u16 = 0x0806;
pub const ETHER_IPV4: u16 = 0x0800;

pub const HEADER_SIZE = 14;
pub const MAX_PAYLOAD = 1500;
pub const MIN_PAYLOAD = 46;

pub const Header = struct {
    dst: [6]u8,
    src: [6]u8,
    ethertype: u16,
};

/// Parse an Ethernet header from raw frame bytes.
pub fn parse(frame: []const u8) ?struct { header: Header, payload: []const u8 } {
    if (frame.len < HEADER_SIZE) return null;

    const header = Header{
        .dst = frame[0..6].*,
        .src = frame[6..12].*,
        .ethertype = @as(u16, frame[12]) << 8 | frame[13],
    };

    return .{
        .header = header,
        .payload = frame[HEADER_SIZE..],
    };
}

/// Build an Ethernet frame into the provided buffer.
/// Returns the total frame length, or null if buffer too small.
pub fn build(buf: []u8, dst: [6]u8, src: [6]u8, ethertype: u16, payload: []const u8) ?usize {
    const total = HEADER_SIZE + payload.len;
    if (total > buf.len) return null;
    if (payload.len > MAX_PAYLOAD) return null;

    @memcpy(buf[0..6], &dst);
    @memcpy(buf[6..12], &src);
    buf[12] = @truncate(ethertype >> 8);
    buf[13] = @truncate(ethertype);
    @memcpy(buf[HEADER_SIZE..][0..payload.len], payload);

    return total;
}

pub const BROADCAST: [6]u8 = .{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };

pub fn macEqual(a: [6]u8, b: [6]u8) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2] and
        a[3] == b[3] and a[4] == b[4] and a[5] == b[5];
}

pub fn isBroadcast(mac: [6]u8) bool {
    return macEqual(mac, BROADCAST);
}
