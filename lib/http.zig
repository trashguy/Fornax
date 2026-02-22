// HTTP/1.1 GET client over Plan 9 /net/tcp/* virtual filesystem.
// All buffers caller-provided (BSS). No allocation.

const fx = @import("root.zig");

pub const MAX_HEADERS = 32;

pub const HeaderEntry = struct {
    name: []const u8,
    value: []const u8,
};

pub const Connection = struct {
    data_fd: i32,
    ctl_fd: i32,
    conn_num: []const u8,
    conn_num_buf: [16]u8,
    conn_num_len: usize,

    /// Open a TCP connection. `header_buf` is scratch for path building.
    pub fn connect(host_ip: []const u8, port: u16, header_buf: []u8) ?Connection {
        // Open clone to allocate connection
        const clone_fd = fx.open("/net/tcp/clone");
        if (clone_fd < 0) return null;

        // Read connection number
        var conn_buf: [16]u8 = undefined;
        const conn_n = fx.read(clone_fd, &conn_buf);
        _ = fx.close(clone_fd);
        if (conn_n <= 0) return null;

        var conn_num_len: usize = @intCast(conn_n);
        if (conn_num_len > 0 and conn_buf[conn_num_len - 1] == '\n') {
            conn_num_len -= 1;
        }

        // Build ctl path: /net/tcp/N/ctl
        var path = fx.path.PathBuf.from("/net/tcp/");
        _ = path.appendRaw(conn_buf[0..conn_num_len]);
        _ = path.appendRaw("/ctl");

        const ctl_fd = fx.open(path.slice());
        if (ctl_fd < 0) return null;

        // Write connect command: "connect IP!PORT\n"
        var cmd_pos: usize = 0;
        const prefix = "connect ";
        @memcpy(header_buf[cmd_pos..][0..prefix.len], prefix);
        cmd_pos += prefix.len;
        @memcpy(header_buf[cmd_pos..][0..host_ip.len], host_ip);
        cmd_pos += host_ip.len;
        header_buf[cmd_pos] = '!';
        cmd_pos += 1;
        cmd_pos += fmtU16(header_buf[cmd_pos..], port);
        header_buf[cmd_pos] = '\n';
        cmd_pos += 1;

        const wr = fx.write(ctl_fd, header_buf[0..cmd_pos]);
        if (wr == 0) {
            _ = fx.close(ctl_fd);
            return null;
        }

        // Open data fd
        var dpath = fx.path.PathBuf.from("/net/tcp/");
        _ = dpath.appendRaw(conn_buf[0..conn_num_len]);
        _ = dpath.appendRaw("/data");

        const data_fd = fx.open(dpath.slice());
        if (data_fd < 0) {
            _ = fx.close(ctl_fd);
            return null;
        }

        var result: Connection = .{
            .data_fd = data_fd,
            .ctl_fd = ctl_fd,
            .conn_num = undefined,
            .conn_num_buf = undefined,
            .conn_num_len = conn_num_len,
        };
        @memcpy(result.conn_num_buf[0..conn_num_len], conn_buf[0..conn_num_len]);
        result.conn_num = result.conn_num_buf[0..conn_num_len];
        return result;
    }

    pub fn close(self: *Connection) void {
        _ = fx.close(self.data_fd);
        _ = fx.close(self.ctl_fd);
        self.data_fd = -1;
        self.ctl_fd = -1;
    }
};

pub const Response = struct {
    status_code: u16,
    headers: [MAX_HEADERS]HeaderEntry,
    header_count: usize,
    data_fd: i32,
    content_length: i64, // -1 if not present
    chunked: bool,
    // Internal: header source buffer info for zero-copy slicing
    header_buf: [*]const u8,
    header_buf_len: usize,
    // Leftover body data from header read
    body_start: usize,
    body_avail: usize,
    body_read: u64,
    chunk_remaining: u64,
    chunk_done: bool,

    pub fn getHeader(self: *const Response, name: []const u8) ?[]const u8 {
        for (0..self.header_count) |i| {
            if (caseInsensitiveEql(self.headers[i].name, name)) {
                return self.headers[i].value;
            }
        }
        return null;
    }

    /// Read body data into buf. Returns bytes read (0 on EOF).
    pub fn readBody(self: *Response, buf: []u8) isize {
        if (self.chunked) {
            return self.readChunked(buf);
        }

        // Content-Length or read-until-close
        if (self.content_length >= 0) {
            const remaining: u64 = @intCast(self.content_length);
            if (self.body_read >= remaining) return 0;
            const max: usize = @intCast(@min(remaining - self.body_read, buf.len));
            if (max == 0) return 0;

            // Drain leftover from header parse first
            if (self.body_avail > self.body_start) {
                const avail = self.body_avail - self.body_start;
                const take = @min(avail, max);
                @memcpy(buf[0..take], self.header_buf[self.body_start..][0..take]);
                self.body_start += take;
                self.body_read += take;
                return @intCast(take);
            }

            const n = fx.read(self.data_fd, buf[0..max]);
            if (n > 0) self.body_read += @intCast(n);
            return n;
        }

        // No content-length: read until close
        if (self.body_avail > self.body_start) {
            const avail = self.body_avail - self.body_start;
            const take = @min(avail, buf.len);
            @memcpy(buf[0..take], self.header_buf[self.body_start..][0..take]);
            self.body_start += take;
            self.body_read += take;
            return @intCast(take);
        }

        return fx.read(self.data_fd, buf);
    }

    fn readChunked(self: *Response, buf: []u8) isize {
        if (self.chunk_done) return 0;

        // If we have remaining chunk data, read it
        if (self.chunk_remaining > 0) {
            const max: usize = @intCast(@min(self.chunk_remaining, buf.len));
            // Drain leftover first
            if (self.body_avail > self.body_start) {
                const avail = self.body_avail - self.body_start;
                const take = @min(avail, max);
                @memcpy(buf[0..take], self.header_buf[self.body_start..][0..take]);
                self.body_start += take;
                self.chunk_remaining -= take;
                return @intCast(take);
            }
            const n = fx.read(self.data_fd, buf[0..max]);
            if (n > 0) self.chunk_remaining -= @intCast(n);
            return n;
        }

        // Read next chunk size (hex digits terminated by \r\n)
        // Skip \r\n from previous chunk
        self.skipCrlf();

        var size_buf: [16]u8 = undefined;
        var size_len: usize = 0;
        while (size_len < size_buf.len) {
            const b = self.readOneByte() orelse return 0;
            if (b == '\r') {
                _ = self.readOneByte(); // skip \n
                break;
            }
            if (b == '\n') break;
            size_buf[size_len] = b;
            size_len += 1;
        }

        const chunk_size = parseHex(size_buf[0..size_len]);
        if (chunk_size == 0) {
            self.chunk_done = true;
            return 0;
        }
        self.chunk_remaining = chunk_size;
        return self.readChunked(buf);
    }

    fn skipCrlf(self: *Response) void {
        // Try to skip \r\n
        if (self.body_avail > self.body_start) {
            if (self.header_buf[self.body_start] == '\r') self.body_start += 1;
            if (self.body_avail > self.body_start and self.header_buf[self.body_start] == '\n') self.body_start += 1;
        }
    }

    fn readOneByte(self: *Response) ?u8 {
        if (self.body_avail > self.body_start) {
            const b = self.header_buf[self.body_start];
            self.body_start += 1;
            return b;
        }
        var tmp: [1]u8 = undefined;
        const n = fx.read(self.data_fd, &tmp);
        if (n <= 0) return null;
        return tmp[0];
    }

    /// Download body to a file fd. Returns total bytes written.
    pub fn readBodyToFd(self: *Response, out_fd: i32, buf: []u8) u64 {
        var total: u64 = 0;
        while (true) {
            const n = self.readBody(buf);
            if (n <= 0) break;
            const nbytes: usize = @intCast(n);
            // Write all bytes, handling partial writes (IPC caps at 4092 bytes)
            var written: usize = 0;
            while (written < nbytes) {
                const w = fx.syscall.write(out_fd, buf[written..nbytes]);
                if (w <= 0) return total;
                written += @intCast(w);
            }
            total += nbytes;
        }
        return total;
    }
};

/// Parse HTTP response headers from the data fd.
/// `header_buf` is used to buffer the initial read.
pub fn parseResponse(data_fd: i32, header_buf: []u8) ?Response {
    // Read initial data
    const n = fx.read(data_fd, header_buf);
    if (n <= 0) return null;
    const nbytes: usize = @intCast(n);

    // Find end of headers (\r\n\r\n)
    var header_end: usize = 0;
    var i: usize = 0;
    while (i + 3 < nbytes) : (i += 1) {
        if (header_buf[i] == '\r' and header_buf[i + 1] == '\n' and
            header_buf[i + 2] == '\r' and header_buf[i + 3] == '\n')
        {
            header_end = i;
            break;
        }
    }

    if (header_end == 0) {
        // Try \n\n fallback
        i = 0;
        while (i + 1 < nbytes) : (i += 1) {
            if (header_buf[i] == '\n' and header_buf[i + 1] == '\n') {
                header_end = i;
                break;
            }
        }
    }

    if (header_end == 0) return null;

    // Parse status line: "HTTP/1.x SSS ..."
    var status_code: u16 = 0;
    const hdr = header_buf[0..header_end];
    var line_start: usize = 0;
    // Find first space
    var sp: usize = 0;
    while (sp < hdr.len and hdr[sp] != ' ') : (sp += 1) {}
    sp += 1; // skip space
    // Parse 3-digit status
    if (sp + 3 <= hdr.len) {
        status_code = (@as(u16, hdr[sp] - '0') * 100) +
            (@as(u16, hdr[sp + 1] - '0') * 10) +
            (@as(u16, hdr[sp + 2] - '0'));
    }

    // Find end of status line
    while (line_start < hdr.len and hdr[line_start] != '\n') : (line_start += 1) {}
    line_start += 1;

    // Parse headers
    var resp = Response{
        .status_code = status_code,
        .headers = undefined,
        .header_count = 0,
        .data_fd = data_fd,
        .content_length = -1,
        .chunked = false,
        .header_buf = header_buf.ptr,
        .header_buf_len = nbytes,
        .body_start = 0,
        .body_avail = nbytes,
        .body_read = 0,
        .chunk_remaining = 0,
        .chunk_done = false,
    };

    // Set body start past headers
    // header_end points to first \r of \r\n\r\n
    if (header_end + 3 < nbytes and header_buf[header_end] == '\r') {
        resp.body_start = header_end + 4;
    } else {
        resp.body_start = header_end + 2;
    }

    // Parse individual header lines
    while (line_start < header_end and resp.header_count < MAX_HEADERS) {
        var line_end = line_start;
        while (line_end < header_end and hdr[line_end] != '\r' and hdr[line_end] != '\n') : (line_end += 1) {}

        if (line_end > line_start) {
            // Find colon
            var colon: usize = line_start;
            while (colon < line_end and hdr[colon] != ':') : (colon += 1) {}
            if (colon < line_end) {
                const hname = hdr[line_start..colon];
                var vstart = colon + 1;
                while (vstart < line_end and hdr[vstart] == ' ') : (vstart += 1) {}
                const hvalue = hdr[vstart..line_end];

                resp.headers[resp.header_count] = .{ .name = hname, .value = hvalue };
                resp.header_count += 1;

                // Check for Content-Length
                if (caseInsensitiveEql(hname, "Content-Length")) {
                    resp.content_length = parseInt(hvalue);
                }
                // Check for Transfer-Encoding: chunked
                if (caseInsensitiveEql(hname, "Transfer-Encoding")) {
                    if (containsCI(hvalue, "chunked")) {
                        resp.chunked = true;
                    }
                }
            }
        }

        // Skip past line ending
        if (line_end < header_end and hdr[line_end] == '\r') line_end += 1;
        if (line_end < header_end and hdr[line_end] == '\n') line_end += 1;
        line_start = line_end;
    }

    return resp;
}

/// Resolve a hostname to an IP string via /net/dns.
pub fn resolve(hostname: []const u8, buf: []u8) ?[]const u8 {
    const dns_fd = fx.open("/net/dns");
    if (dns_fd < 0) return null;

    // Write "query hostname"
    var cmd: [256]u8 = undefined;
    const prefix = "query ";
    if (prefix.len + hostname.len > cmd.len) {
        _ = fx.close(dns_fd);
        return null;
    }
    @memcpy(cmd[0..prefix.len], prefix);
    @memcpy(cmd[prefix.len..][0..hostname.len], hostname);
    const cmd_len = prefix.len + hostname.len;

    const wr = fx.write(dns_fd, cmd[0..cmd_len]);
    if (wr == 0) {
        _ = fx.close(dns_fd);
        return null;
    }

    const n = fx.read(dns_fd, buf);
    _ = fx.close(dns_fd);
    if (n <= 0) return null;

    var result_len: usize = @intCast(n);
    // Strip trailing whitespace/newlines
    while (result_len > 0 and (buf[result_len - 1] == '\n' or buf[result_len - 1] == '\r' or buf[result_len - 1] == ' ')) {
        result_len -= 1;
    }
    if (result_len == 0) return null;
    return buf[0..result_len];
}

/// High-level: download a file via HTTP GET.
/// Returns total body bytes written to out_fd, or null on failure.
pub fn download(host: []const u8, url_path: []const u8, port: u16, out_fd: i32, buf: []u8, header_buf: []u8) ?u64 {
    // Resolve hostname if needed (check if it looks like an IP)
    var ip_buf: [64]u8 = undefined;
    const host_ip = if (isIpAddress(host)) host else (resolve(host, &ip_buf) orelse return null);

    var conn = Connection.connect(host_ip, port, header_buf) orelse return null;

    // Build HTTP request
    var req_pos: usize = 0;
    const get = "GET ";
    @memcpy(header_buf[req_pos..][0..get.len], get);
    req_pos += get.len;
    @memcpy(header_buf[req_pos..][0..url_path.len], url_path);
    req_pos += url_path.len;
    const ver = " HTTP/1.1\r\nHost: ";
    @memcpy(header_buf[req_pos..][0..ver.len], ver);
    req_pos += ver.len;
    @memcpy(header_buf[req_pos..][0..host.len], host);
    req_pos += host.len;
    const close_hdr = "\r\nConnection: close\r\n\r\n";
    @memcpy(header_buf[req_pos..][0..close_hdr.len], close_hdr);
    req_pos += close_hdr.len;

    _ = fx.write(conn.data_fd, header_buf[0..req_pos]);

    var resp = parseResponse(conn.data_fd, header_buf) orelse {
        conn.close();
        return null;
    };

    if (resp.status_code < 200 or resp.status_code >= 300) {
        conn.close();
        return null;
    }

    const total = resp.readBodyToFd(out_fd, buf);
    conn.close();
    return total;
}

// ── Internal helpers ─────────────────────────────────────────────────

fn fmtU16(buf: []u8, val: u16) usize {
    var tmp: [5]u8 = undefined;
    var len: usize = 0;
    var v = val;
    if (v == 0) {
        buf[0] = '0';
        return 1;
    }
    while (v > 0) : (v /= 10) {
        tmp[len] = @intCast('0' + (v % 10));
        len += 1;
    }
    for (0..len) |i| {
        buf[i] = tmp[len - 1 - i];
    }
    return len;
}

fn caseInsensitiveEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (toLower(ac) != toLower(bc)) return false;
    }
    return true;
}

fn containsCI(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (caseInsensitiveEql(hay[i..][0..needle.len], needle)) return true;
    }
    return false;
}

fn toLower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

fn parseInt(s: []const u8) i64 {
    var val: i64 = 0;
    for (s) |c| {
        if (c >= '0' and c <= '9') {
            val = val * 10 + (c - '0');
        }
    }
    return val;
}

fn parseHex(s: []const u8) u64 {
    var val: u64 = 0;
    for (s) |c| {
        val <<= 4;
        if (c >= '0' and c <= '9') {
            val |= c - '0';
        } else if (c >= 'a' and c <= 'f') {
            val |= c - 'a' + 10;
        } else if (c >= 'A' and c <= 'F') {
            val |= c - 'A' + 10;
        }
    }
    return val;
}

fn isIpAddress(s: []const u8) bool {
    if (s.len == 0) return false;
    return s[0] >= '0' and s[0] <= '9';
}
