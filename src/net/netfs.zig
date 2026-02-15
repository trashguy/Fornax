/// Net file interface: maps /net/* paths to TCP/DNS kernel operations.
///
/// Implements the Plan 9 style file interface for network connections:
///   /net/tcp/clone     — allocate a new TCP connection
///   /net/tcp/N/ctl     — control (connect/announce)
///   /net/tcp/N/data    — read/write data
///   /net/tcp/N/listen  — accept incoming connections
///   /net/tcp/N/status  — connection state
///   /net/tcp/N/local   — local address
///   /net/tcp/N/remote  — remote address
///   /net/dns           — DNS query
///   /net/dns/ctl       — DNS configuration
///   /net/dns/cache     — DNS cache dump
const serial = @import("../serial.zig");
const process = @import("../process.zig");
const tcp = @import("tcp.zig");
const dns = @import("dns.zig");
const net = @import("../net.zig");
const timer = @import("../timer.zig");

const NetFdKind = process.NetFdKind;

/// Result of opening a /net/* path.
pub const OpenResult = struct {
    kind: NetFdKind,
    conn: u8,
};

/// Parse a /net/* path and perform the open operation.
/// `path` should have the leading "/net/" stripped (e.g., "tcp/clone").
pub fn netOpen(path: []const u8) ?OpenResult {
    if (startsWith(path, "tcp/clone")) {
        // Allocate a new TCP connection
        const idx = tcp.alloc() orelse return null;
        return .{ .kind = .tcp_clone, .conn = idx };
    }

    if (startsWith(path, "tcp/")) {
        // Parse "tcp/N/subfile"
        const rest = path[4..];
        const parsed = parseConnPath(rest) orelse return null;

        // Verify connection exists
        if (tcp.getState(parsed.conn) == null) return null;

        return .{ .kind = parsed.kind, .conn = parsed.conn };
    }

    if (eql(path, "dns") or eql(path, "dns/")) {
        return .{ .kind = .dns_query, .conn = 0 };
    }

    if (eql(path, "dns/ctl")) {
        return .{ .kind = .dns_ctl, .conn = 0 };
    }

    if (eql(path, "dns/cache")) {
        return .{ .kind = .dns_cache, .conn = 0 };
    }

    return null;
}

/// Read from a net fd. Returns bytes written to buf, or 0 for EOF/error.
/// Returns null if the caller should block (data not ready yet).
pub fn netRead(kind: NetFdKind, conn: u8, buf: []u8, read_done: *bool) ?u16 {
    switch (kind) {
        .tcp_clone => {
            if (read_done.*) return 0; // EOF on second read
            // Return connection index as "N\n"
            const len = formatDec(buf, conn);
            buf[len] = '\n';
            read_done.* = true;
            return len + 1;
        },
        .tcp_data => {
            // Try to read data from TCP connection
            const n = tcp.recvData(conn, buf);
            if (n > 0) return n;
            // No data — check if EOF
            if (tcp.isEof(conn)) return 0;
            // Otherwise caller should block
            return null;
        },
        .tcp_status => {
            if (read_done.*) return 0;
            const state = tcp.getState(conn) orelse return 0;
            const name = stateName(state);
            const len: u16 = @intCast(name.len);
            if (len + 1 > buf.len) return 0;
            @memcpy(buf[0..len], name);
            buf[len] = '\n';
            read_done.* = true;
            return len + 1;
        },
        .tcp_local => {
            if (read_done.*) return 0;
            const info = tcp.getLocal(conn) orelse return 0;
            var pos: u16 = 0;
            pos += formatIp(buf[pos..], info.ip);
            buf[pos] = '!';
            pos += 1;
            pos += formatDec(buf[pos..], info.port);
            buf[pos] = '\n';
            pos += 1;
            read_done.* = true;
            return pos;
        },
        .tcp_remote => {
            if (read_done.*) return 0;
            const info = tcp.getRemote(conn) orelse return 0;
            var pos: u16 = 0;
            pos += formatIp(buf[pos..], info.ip);
            buf[pos] = '!';
            pos += 1;
            pos += formatDec(buf[pos..], info.port);
            buf[pos] = '\n';
            pos += 1;
            read_done.* = true;
            return pos;
        },
        .tcp_listen => {
            // Listen read should never be called here — handled by blocking in syscall
            return 0;
        },
        .tcp_ctl => {
            return 0; // ctl reads return EOF
        },
        .dns_query => {
            if (read_done.*) return 0;
            // Return the result of the last DNS query
            const ip = dns.getResult() orelse return 0;
            var pos: u16 = 0;
            pos += formatIp(buf[pos..], ip);
            buf[pos] = '\n';
            pos += 1;
            read_done.* = true;
            return pos;
        },
        .dns_ctl => {
            return 0;
        },
        .dns_cache => {
            if (read_done.*) return 0;
            const len = dns.getCacheText(buf);
            read_done.* = true;
            return len;
        },
    }
}

/// Write to a net fd. Returns bytes consumed, or 0 on error.
/// Returns null if the caller should block.
pub fn netWrite(kind: NetFdKind, conn: u8, data: []const u8) ?u16 {
    switch (kind) {
        .tcp_ctl => {
            return handleCtlWrite(conn, data);
        },
        .tcp_data => {
            const sent = tcp.sendData(conn, data);
            return sent;
        },
        .dns_query => {
            return handleDnsWrite(data);
        },
        .dns_ctl => {
            return handleDnsCtlWrite(data);
        },
        else => return 0,
    }
}

/// Close a net fd.
pub fn netClose(kind: NetFdKind, conn: u8) void {
    switch (kind) {
        .tcp_data => {
            tcp.startClose(conn);
        },
        else => {}, // other fd types don't need close actions
    }
}

// ── Control commands ────────────────────────────────────────────────

/// Handle "connect IP!PORT" or "announce *!PORT" on tcp ctl.
/// Returns bytes consumed, or null if should block (for connect).
fn handleCtlWrite(conn: u8, data: []const u8) ?u16 {
    const trimmed = trimNewline(data);

    if (startsWith(trimmed, "connect ")) {
        const args = trimmed[8..];
        const parsed = parseAddr(args) orelse {
            serial.puts("netfs: bad connect address\n");
            return 0;
        };
        if (!tcp.connect(conn, parsed.ip, parsed.port)) {
            serial.puts("netfs: connect failed\n");
            return 0;
        }
        // Caller should block until ESTABLISHED
        return null;
    }

    if (startsWith(trimmed, "announce ")) {
        const args = trimmed[9..];
        // Parse "*!PORT" or "PORT"
        var port_str = args;
        if (startsWith(args, "*!")) {
            port_str = args[2..];
        }
        const port = parseDec(port_str) orelse {
            serial.puts("netfs: bad announce port\n");
            return 0;
        };
        if (!tcp.announce(conn, @intCast(port))) {
            serial.puts("netfs: announce failed\n");
            return 0;
        }
        return @intCast(data.len);
    }

    serial.puts("netfs: unknown ctl command\n");
    return 0;
}

/// Handle DNS query write: "query DOMAIN"
fn handleDnsWrite(data: []const u8) ?u16 {
    const trimmed = trimNewline(data);

    if (startsWith(trimmed, "query ")) {
        const name = trimmed[6..];
        if (name.len == 0) return 0;

        // Check cache first
        if (dns.cacheLookup(name)) |_| {
            // Already cached — immediate result
            return @intCast(data.len);
        }

        if (!dns.query(name)) return 0;
        // Caller should block until response
        return null;
    }

    return 0;
}

/// Handle DNS ctl write: "nameserver IP"
fn handleDnsCtlWrite(data: []const u8) ?u16 {
    const trimmed = trimNewline(data);

    if (startsWith(trimmed, "nameserver ")) {
        const ip_str = trimmed[11..];
        const ip = parseIp(ip_str) orelse return 0;
        dns.setNameserver(ip);
        return @intCast(data.len);
    }

    return 0;
}

// ── Path parsing helpers ────────────────────────────────────────────

const ConnPathResult = struct {
    conn: u8,
    kind: NetFdKind,
};

fn parseConnPath(path: []const u8) ?ConnPathResult {
    // Parse "N/subfile" where N is a decimal connection index
    var i: usize = 0;
    while (i < path.len and path[i] >= '0' and path[i] <= '9') : (i += 1) {}
    if (i == 0) return null;

    const conn_num = parseDec(path[0..i]) orelse return null;
    if (conn_num >= 16) return null;

    if (i >= path.len or path[i] != '/') return null;
    const subfile = path[i + 1 ..];

    const kind: NetFdKind = if (eql(subfile, "ctl"))
        .tcp_ctl
    else if (eql(subfile, "data"))
        .tcp_data
    else if (eql(subfile, "listen"))
        .tcp_listen
    else if (eql(subfile, "status"))
        .tcp_status
    else if (eql(subfile, "local"))
        .tcp_local
    else if (eql(subfile, "remote"))
        .tcp_remote
    else
        return null;

    return .{ .conn = @intCast(conn_num), .kind = kind };
}

/// Parse "IP!PORT" — e.g., "10.0.2.2!80"
fn parseAddr(s: []const u8) ?struct { ip: [4]u8, port: u16 } {
    // Find '!'
    var bang: ?usize = null;
    for (s, 0..) |ch, i| {
        if (ch == '!') {
            bang = i;
            break;
        }
    }
    const bang_pos = bang orelse return null;

    const ip = parseIp(s[0..bang_pos]) orelse return null;
    const port = parseDec(s[bang_pos + 1 ..]) orelse return null;
    if (port > 65535) return null;

    return .{ .ip = ip, .port = @intCast(port) };
}

/// Parse dotted-decimal IP: "10.0.2.2"
fn parseIp(s: []const u8) ?[4]u8 {
    var ip: [4]u8 = undefined;
    var octet: u32 = 0;
    var idx: u8 = 0;
    var has_digit = false;

    for (s) |ch| {
        if (ch >= '0' and ch <= '9') {
            octet = octet * 10 + (ch - '0');
            if (octet > 255) return null;
            has_digit = true;
        } else if (ch == '.') {
            if (!has_digit or idx >= 3) return null;
            ip[idx] = @intCast(octet);
            idx += 1;
            octet = 0;
            has_digit = false;
        } else {
            return null;
        }
    }
    if (!has_digit or idx != 3) return null;
    ip[3] = @intCast(octet);
    return ip;
}

// ── String/number helpers ───────────────────────────────────────────

fn parseDec(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    var val: u32 = 0;
    for (s) |ch| {
        if (ch < '0' or ch > '9') return null;
        val = val * 10 + (ch - '0');
    }
    return val;
}

fn formatDec(buf: []u8, val: anytype) u16 {
    const v: u32 = @intCast(val);
    if (v == 0) {
        buf[0] = '0';
        return 1;
    }
    var tmp: [10]u8 = undefined;
    var len: u16 = 0;
    var x = v;
    while (x > 0) : (len += 1) {
        tmp[len] = @intCast('0' + x % 10);
        x /= 10;
    }
    var i: u16 = 0;
    while (i < len) : (i += 1) {
        buf[i] = tmp[len - 1 - i];
    }
    return len;
}

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

fn stateName(state: tcp.TcpState) []const u8 {
    return switch (state) {
        .closed => "Closed",
        .listen => "Listen",
        .syn_sent => "SynSent",
        .syn_received => "SynReceived",
        .established => "Established",
        .fin_wait_1 => "FinWait1",
        .fin_wait_2 => "FinWait2",
        .close_wait => "CloseWait",
        .last_ack => "LastAck",
        .time_wait => "TimeWait",
        .closing => "Closing",
    };
}

fn startsWith(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    return eql(s[0..prefix.len], prefix);
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

fn trimNewline(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and (s[end - 1] == '\n' or s[end - 1] == '\r')) {
        end -= 1;
    }
    return s[0..end];
}
