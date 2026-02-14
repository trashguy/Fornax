/// UDP: User Datagram Protocol.
///
/// Connectionless datagrams with port multiplexing.
/// Each "connection" is an entry that binds a local port and optionally
/// a remote address/port.
const ipv4 = @import("ipv4.zig");
const serial = @import("../serial.zig");

const HEADER_SIZE = 8; // src_port(2) + dst_port(2) + length(2) + checksum(2)
const MAX_CONNECTIONS = 16;
const RX_BUF_SIZE = 1500;

pub const Connection = struct {
    local_port: u16,
    remote_ip: [4]u8,
    remote_port: u16,
    bound: bool,
    connected: bool, // has remote set
    // Simple single-datagram receive buffer
    rx_buf: [RX_BUF_SIZE]u8,
    rx_len: usize,
    rx_ready: bool,
    rx_src_ip: [4]u8,
    rx_src_port: u16,
};

var connections: [MAX_CONNECTIONS]Connection = [_]Connection{emptyConn()} ** MAX_CONNECTIONS;
var next_ephemeral_port: u16 = 49152;

fn emptyConn() Connection {
    return Connection{
        .local_port = 0,
        .remote_ip = .{ 0, 0, 0, 0 },
        .remote_port = 0,
        .bound = false,
        .connected = false,
        .rx_buf = undefined,
        .rx_len = 0,
        .rx_ready = false,
        .rx_src_ip = .{ 0, 0, 0, 0 },
        .rx_src_port = 0,
    };
}

/// Allocate a new UDP connection slot. Returns the connection index.
pub fn alloc() ?usize {
    for (&connections, 0..) |*conn, i| {
        if (!conn.bound) {
            conn.* = emptyConn();
            conn.bound = true;
            conn.local_port = allocEphemeralPort();
            return i;
        }
    }
    return null;
}

/// Bind a connection to a specific local port.
pub fn bind(conn_idx: usize, port: u16) bool {
    if (conn_idx >= MAX_CONNECTIONS) return false;
    if (!connections[conn_idx].bound) return false;
    connections[conn_idx].local_port = port;
    return true;
}

/// Set the remote address for a connection ("connect").
pub fn connect(conn_idx: usize, remote_ip: [4]u8, remote_port: u16) bool {
    if (conn_idx >= MAX_CONNECTIONS) return false;
    const conn = &connections[conn_idx];
    if (!conn.bound) return false;
    conn.remote_ip = remote_ip;
    conn.remote_port = remote_port;
    conn.connected = true;
    return true;
}

/// Close a UDP connection.
pub fn close(conn_idx: usize) void {
    if (conn_idx >= MAX_CONNECTIONS) return;
    connections[conn_idx] = emptyConn();
}

/// Build a UDP datagram inside an IP packet.
/// Returns the total IP packet length written to `buf`.
pub fn buildPacket(
    buf: []u8,
    our_ip: [4]u8,
    dst_ip: [4]u8,
    src_port: u16,
    dst_port: u16,
    payload: []const u8,
) ?usize {
    const udp_len: u16 = @intCast(HEADER_SIZE + payload.len);
    if (udp_len > 1472) return null; // max UDP payload in single Ethernet frame

    var udp_buf: [1480]u8 = undefined;
    writeBe16(&udp_buf, 0, src_port);
    writeBe16(&udp_buf, 2, dst_port);
    writeBe16(&udp_buf, 4, udp_len);
    writeBe16(&udp_buf, 6, 0); // checksum (optional for IPv4 UDP)
    @memcpy(udp_buf[HEADER_SIZE..][0..payload.len], payload);

    return ipv4.build(buf, our_ip, dst_ip, ipv4.PROTO_UDP, udp_buf[0..@as(usize, udp_len)]);
}

/// Process an incoming UDP packet. Delivers to matching connection.
pub fn handlePacket(payload: []const u8, ip_hdr: ipv4.Header) void {
    if (payload.len < HEADER_SIZE) return;

    const src_port = be16(payload[0..2]);
    const dst_port = be16(payload[2..4]);
    const udp_len = be16(payload[4..6]);

    if (udp_len < HEADER_SIZE or udp_len > payload.len) return;

    const data = payload[HEADER_SIZE..@as(usize, udp_len)];

    // Find matching connection
    for (&connections) |*conn| {
        if (!conn.bound) continue;
        if (conn.local_port != dst_port) continue;

        // If connected, filter by remote
        if (conn.connected) {
            if (!ipv4.ipEqual(conn.remote_ip, ip_hdr.src)) continue;
            if (conn.remote_port != src_port) continue;
        }

        // Deliver
        if (data.len <= RX_BUF_SIZE) {
            @memcpy(conn.rx_buf[0..data.len], data);
            conn.rx_len = data.len;
            conn.rx_ready = true;
            conn.rx_src_ip = ip_hdr.src;
            conn.rx_src_port = src_port;
        }
        return;
    }

    serial.puts("udp: no listener for port ");
    serial.putDec(dst_port);
    serial.puts("\n");
}

/// Check if a connection has received data. Returns the data slice or null.
pub fn recv(conn_idx: usize) ?struct { data: []const u8, src_ip: [4]u8, src_port: u16 } {
    if (conn_idx >= MAX_CONNECTIONS) return null;
    const conn = &connections[conn_idx];
    if (!conn.rx_ready) return null;

    conn.rx_ready = false;
    return .{
        .data = conn.rx_buf[0..conn.rx_len],
        .src_ip = conn.rx_src_ip,
        .src_port = conn.rx_src_port,
    };
}

fn allocEphemeralPort() u16 {
    const port = next_ephemeral_port;
    next_ephemeral_port +%= 1;
    if (next_ephemeral_port < 49152) next_ephemeral_port = 49152;
    return port;
}

fn be16(bytes: *const [2]u8) u16 {
    return @as(u16, bytes[0]) << 8 | bytes[1];
}

fn writeBe16(buf: []u8, offset: usize, val: u16) void {
    buf[offset] = @truncate(val >> 8);
    buf[offset + 1] = @truncate(val);
}
