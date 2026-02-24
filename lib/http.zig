// HTTP/1.1 GET client over Plan 9 /net/tcp/* virtual filesystem.
// All buffers caller-provided (BSS). No allocation.

const fx = @import("root.zig");

pub const MAX_HEADERS = 32;

pub const HeaderEntry = struct {
    name: []const u8,
    value: []const u8,
};

/// I/O function table for transport abstraction (e.g. TLS).
/// When set on a Connection, all reads/writes go through these
/// instead of raw fx.read/fx.write on the data fd.
pub const IoFns = struct {
    read: *const fn (ctx: *anyopaque, buf: []u8) isize,
    write: *const fn (ctx: *anyopaque, data: []const u8) isize,
    ctx: *anyopaque,
};

pub const Connection = struct {
    data_fd: i32,
    ctl_fd: i32,
    conn_num: []const u8,
    conn_num_buf: [16]u8,
    conn_num_len: usize,
    io: ?IoFns,

    /// Open a TCP connection. `header_buf` is scratch for path building.
    pub fn connect(host_ip: []const u8, port: u16, header_buf: []u8) ?Connection {
        // Open clone to allocate connection
        const clone_fd = fx.open("/net/tcp/clone");
        if (clone_fd < 0) {
            _ = fx.write(2, "http: clone open failed\n");
            return null;
        }

        // Read connection number
        var conn_buf: [16]u8 = undefined;
        const conn_n = fx.read(clone_fd, &conn_buf);
        _ = fx.close(clone_fd);
        if (conn_n <= 0) {
            _ = fx.write(2, "http: clone read failed\n");
            return null;
        }

        var conn_num_len: usize = @intCast(conn_n);
        if (conn_num_len > 0 and conn_buf[conn_num_len - 1] == '\n') {
            conn_num_len -= 1;
        }

        // Build ctl path: /net/tcp/N/ctl
        var path = fx.path.PathBuf.from("/net/tcp/");
        _ = path.appendRaw(conn_buf[0..conn_num_len]);
        _ = path.appendRaw("/ctl");

        const ctl_fd = fx.open(path.slice());
        if (ctl_fd < 0) {
            _ = fx.write(2, "http: ctl open failed\n");
            return null;
        }
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
            _ = fx.write(2, "http: data open failed\n");
            _ = fx.close(ctl_fd);
            return null;
        }

        var result: Connection = .{
            .data_fd = data_fd,
            .ctl_fd = ctl_fd,
            .conn_num = undefined,
            .conn_num_buf = undefined,
            .conn_num_len = conn_num_len,
            .io = null,
        };
        @memcpy(result.conn_num_buf[0..conn_num_len], conn_buf[0..conn_num_len]);
        result.conn_num = result.conn_num_buf[0..conn_num_len];
        return result;
    }

    /// Write data through IoFns or raw fd.
    pub fn writeData(self: *const Connection, data: []const u8) isize {
        if (self.io) |io| return io.write(io.ctx, data);
        const n = fx.write(self.data_fd, data);
        return @intCast(n);
    }

    /// Read data through IoFns or raw fd.
    pub fn readData(self: *const Connection, buf: []u8) isize {
        if (self.io) |io| return io.read(io.ctx, buf);
        return fx.read(self.data_fd, buf);
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
    io: ?IoFns,

    pub fn getHeader(self: *const Response, name: []const u8) ?[]const u8 {
        for (0..self.header_count) |i| {
            if (caseInsensitiveEql(self.headers[i].name, name)) {
                return self.headers[i].value;
            }
        }
        return null;
    }

    /// Internal: read from network (through IoFns if set, else raw fd).
    fn netRead(self: *const Response, buf: []u8) isize {
        if (self.io) |io| return io.read(io.ctx, buf);
        return fx.read(self.data_fd, buf);
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

            const n = self.netRead(buf[0..max]);
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

        return self.netRead(buf);
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
            const n = self.netRead(buf[0..max]);
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
        const n = self.netRead(&tmp);
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

    /// Read and discard remaining body data.
    pub fn drainBody(self: *Response) void {
        var discard: [512]u8 = undefined;
        while (true) {
            const n = self.readBody(&discard);
            if (n <= 0) break;
        }
    }
};

/// Parse HTTP response headers from the data fd.
/// `header_buf` is used to buffer the initial read.
/// `io` is optional transport I/O (e.g. TLS); null for raw fd.
pub fn parseResponse(data_fd: i32, header_buf: []u8, io: ?IoFns) ?Response {
    // Read initial data
    const n = if (io) |i| i.read(i.ctx, header_buf) else fx.read(data_fd, header_buf);
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
        .io = io,
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

    var resp = parseResponse(conn.data_fd, header_buf, null) orelse {
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

pub const RequestOptions = struct {
    headers: []const HeaderEntry = &.{},
    /// Called after TCP connect, before HTTP exchange. Returns IoFns for
    /// encrypted I/O (e.g. TLS), or null for plain TCP.
    on_connect: ?*const fn (data_fd: i32, host: []const u8) ?IoFns = null,
    /// Optional request body (for POST/PUT). Content-Length auto-generated.
    body: ?[]const u8 = null,
    /// Content-Type for body. Defaults to application/x-www-form-urlencoded.
    content_type: ?[]const u8 = null,
};

pub const UrlParts = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
    tls: bool,
};

/// Parse "http://host:port/path" or "https://host:port/path" into components.
pub fn parseUrl(url: []const u8, path_buf: []u8) ?UrlParts {
    var s = url;
    var use_tls = false;
    var default_port: u16 = 80;

    // Check for https:// prefix
    const https_prefix = "https://";
    if (s.len >= https_prefix.len and prefixMatchCI(s, https_prefix)) {
        s = s[https_prefix.len..];
        use_tls = true;
        default_port = 443;
    } else {
        // Check for http:// prefix
        const http_prefix = "http://";
        if (s.len >= http_prefix.len and prefixMatchCI(s, http_prefix)) {
            s = s[http_prefix.len..];
        }
    }

    // Find end of host:port (first '/')
    var host_end: usize = 0;
    while (host_end < s.len and s[host_end] != '/') : (host_end += 1) {}

    const host_port = s[0..host_end];
    const url_path = if (host_end < s.len) s[host_end..] else "/";

    // Copy path into buffer
    if (url_path.len > path_buf.len) return null;
    @memcpy(path_buf[0..url_path.len], url_path);

    // Split host:port
    var colon_pos: usize = host_port.len;
    var i: usize = 0;
    while (i < host_port.len) : (i += 1) {
        if (host_port[i] == ':') colon_pos = i;
    }

    var port: u16 = default_port;
    if (colon_pos < host_port.len) {
        port = @intCast(parseInt(host_port[colon_pos + 1 ..]));
        if (port == 0) port = default_port;
    }

    return UrlParts{
        .host = host_port[0..colon_pos],
        .port = port,
        .path = path_buf[0..url_path.len],
        .tls = use_tls,
    };
}

pub const RequestResult = struct {
    conn: Connection,
    resp: Response,
};

/// Result of parsing a WWW-Authenticate: Bearer header.
pub const AuthChallenge = struct {
    realm: []const u8, // token endpoint URL
    service: []const u8, // registry service name
    scope: []const u8, // e.g. "repository:library/alpine:pull"
};

/// Parse WWW-Authenticate: Bearer realm="...",service="...",scope="..." header.
/// Returns true if a valid Bearer challenge was extracted.
pub fn parseWwwAuthenticate(header_value: []const u8, challenge: *AuthChallenge) bool {
    // Skip leading whitespace
    var s = header_value;
    while (s.len > 0 and s[0] == ' ') s = s[1..];

    // Must start with "Bearer " (case-insensitive)
    const bearer = "Bearer ";
    if (s.len < bearer.len) return false;
    if (!prefixMatchCI(s, bearer)) return false;
    s = s[bearer.len..];

    challenge.realm = "";
    challenge.service = "";
    challenge.scope = "";

    // Parse comma-separated key="value" pairs
    while (s.len > 0) {
        // Skip whitespace and commas
        while (s.len > 0 and (s[0] == ' ' or s[0] == ',')) s = s[1..];
        if (s.len == 0) break;

        // Find '='
        var eq: usize = 0;
        while (eq < s.len and s[eq] != '=') : (eq += 1) {}
        if (eq >= s.len) break;

        const key = s[0..eq];
        s = s[eq + 1 ..];

        // Value may be quoted
        if (s.len > 0 and s[0] == '"') {
            s = s[1..]; // skip opening quote
            var end: usize = 0;
            while (end < s.len and s[end] != '"') : (end += 1) {}
            const val = s[0..end];
            if (end < s.len) s = s[end + 1 ..] else s = s[end..];

            if (caseInsensitiveEql(key, "realm")) {
                challenge.realm = val;
            } else if (caseInsensitiveEql(key, "service")) {
                challenge.service = val;
            } else if (caseInsensitiveEql(key, "scope")) {
                challenge.scope = val;
            }
        } else {
            // Unquoted value — up to comma or end
            var end: usize = 0;
            while (end < s.len and s[end] != ',' and s[end] != ' ') : (end += 1) {}
            const val = s[0..end];
            s = s[end..];

            if (caseInsensitiveEql(key, "realm")) {
                challenge.realm = val;
            } else if (caseInsensitiveEql(key, "service")) {
                challenge.service = val;
            } else if (caseInsensitiveEql(key, "scope")) {
                challenge.scope = val;
            }
        }
    }

    return challenge.realm.len > 0;
}

/// URL percent-encode a string (RFC 3986 unreserved chars pass through).
/// Returns the encoded slice within buf.
pub fn percentEncode(input: []const u8, buf: []u8) []const u8 {
    const hex = "0123456789ABCDEF";
    var pos: usize = 0;
    for (input) |ch| {
        if (isUnreserved(ch)) {
            if (pos >= buf.len) break;
            buf[pos] = ch;
            pos += 1;
        } else {
            if (pos + 3 > buf.len) break;
            buf[pos] = '%';
            buf[pos + 1] = hex[ch >> 4];
            buf[pos + 2] = hex[ch & 0x0F];
            pos += 3;
        }
    }
    return buf[0..pos];
}

/// Build a query string from key=value pairs (values percent-encoded).
/// Returns the encoded slice within buf (e.g. "key1=value1&key2=value2").
pub fn buildQueryString(params: []const HeaderEntry, buf: []u8) []const u8 {
    var pos: usize = 0;
    for (params, 0..) |param, idx| {
        if (idx > 0) {
            if (pos >= buf.len) break;
            buf[pos] = '&';
            pos += 1;
        }
        // Copy key as-is (should already be safe)
        const klen = @min(param.name.len, buf.len - pos);
        @memcpy(buf[pos..][0..klen], param.name[0..klen]);
        pos += klen;
        if (pos >= buf.len) break;
        buf[pos] = '=';
        pos += 1;
        // Percent-encode value
        const encoded = percentEncode(param.value, buf[pos..]);
        pos += encoded.len;
    }
    return buf[0..pos];
}

/// Base64 encode (RFC 4648 standard encoding).
/// Returns the encoded slice within buf.
pub fn base64Encode(input: []const u8, buf: []u8) []const u8 {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    var pos: usize = 0;
    var i: usize = 0;
    while (i + 3 <= input.len) : (i += 3) {
        if (pos + 4 > buf.len) break;
        const b0 = input[i];
        const b1 = input[i + 1];
        const b2 = input[i + 2];
        buf[pos] = alphabet[b0 >> 2];
        buf[pos + 1] = alphabet[((b0 & 0x03) << 4) | (b1 >> 4)];
        buf[pos + 2] = alphabet[((b1 & 0x0F) << 2) | (b2 >> 6)];
        buf[pos + 3] = alphabet[b2 & 0x3F];
        pos += 4;
    }
    // Handle remaining bytes
    const rem = input.len - i;
    if (rem == 1 and pos + 4 <= buf.len) {
        const b0 = input[i];
        buf[pos] = alphabet[b0 >> 2];
        buf[pos + 1] = alphabet[(b0 & 0x03) << 4];
        buf[pos + 2] = '=';
        buf[pos + 3] = '=';
        pos += 4;
    } else if (rem == 2 and pos + 4 <= buf.len) {
        const b0 = input[i];
        const b1 = input[i + 1];
        buf[pos] = alphabet[b0 >> 2];
        buf[pos + 1] = alphabet[((b0 & 0x03) << 4) | (b1 >> 4)];
        buf[pos + 2] = alphabet[(b1 & 0x0F) << 2];
        buf[pos + 3] = '=';
        pos += 4;
    }
    return buf[0..pos];
}

fn isUnreserved(ch: u8) bool {
    return (ch >= 'A' and ch <= 'Z') or
        (ch >= 'a' and ch <= 'z') or
        (ch >= '0' and ch <= '9') or
        ch == '-' or ch == '.' or ch == '_' or ch == '~';
}

/// Lower-level HTTP request that returns Connection + Response for streaming.
/// Caller must close the connection when done.
pub fn request(
    host: []const u8,
    port: u16,
    method: []const u8,
    url_path: []const u8,
    options: RequestOptions,
    header_buf: []u8,
) ?RequestResult {
    return requestWithRedirects(host, port, method, url_path, options, header_buf, 0);
}

fn requestWithRedirects(
    host: []const u8,
    port: u16,
    method: []const u8,
    url_path: []const u8,
    options: RequestOptions,
    header_buf: []u8,
    redirect_count: u8,
) ?RequestResult {
    // Resolve hostname if needed
    var ip_buf: [64]u8 = undefined;
    const host_ip = if (isIpAddress(host)) host else (resolve(host, &ip_buf) orelse {
        _ = fx.write(2, "http: DNS resolution failed for ");
        _ = fx.write(2, host);
        _ = fx.write(2, "\n");
        return null;
    });

    var conn = Connection.connect(host_ip, port, header_buf) orelse {
        _ = fx.write(2, "http: TCP connect failed\n");
        return null;
    };

    // Set up transport I/O (e.g. TLS handshake) if callback provided
    if (options.on_connect) |setup| {
        conn.io = setup(conn.data_fd, host);
        if (conn.io == null) {
            // Transport setup failed (e.g. TLS handshake failed)
            _ = fx.write(2, "http: transport setup failed\n");
            conn.close();
            return null;
        }
    }

    // Build HTTP request
    var req_pos: usize = 0;
    @memcpy(header_buf[req_pos..][0..method.len], method);
    req_pos += method.len;
    header_buf[req_pos] = ' ';
    req_pos += 1;
    @memcpy(header_buf[req_pos..][0..url_path.len], url_path);
    req_pos += url_path.len;
    const ver = " HTTP/1.1\r\nHost: ";
    @memcpy(header_buf[req_pos..][0..ver.len], ver);
    req_pos += ver.len;
    @memcpy(header_buf[req_pos..][0..host.len], host);
    req_pos += host.len;

    // User-Agent
    const ua = "\r\nUser-Agent: Fornax/1.0";
    @memcpy(header_buf[req_pos..][0..ua.len], ua);
    req_pos += ua.len;

    // Custom headers
    for (options.headers) |hdr| {
        const crlf = "\r\n";
        @memcpy(header_buf[req_pos..][0..crlf.len], crlf);
        req_pos += crlf.len;
        @memcpy(header_buf[req_pos..][0..hdr.name.len], hdr.name);
        req_pos += hdr.name.len;
        const sep = ": ";
        @memcpy(header_buf[req_pos..][0..sep.len], sep);
        req_pos += sep.len;
        @memcpy(header_buf[req_pos..][0..hdr.value.len], hdr.value);
        req_pos += hdr.value.len;
    }

    // Body headers (Content-Length + Content-Type)
    if (options.body) |body| {
        const ct_hdr = "\r\nContent-Type: ";
        @memcpy(header_buf[req_pos..][0..ct_hdr.len], ct_hdr);
        req_pos += ct_hdr.len;
        const ct = options.content_type orelse "application/x-www-form-urlencoded";
        @memcpy(header_buf[req_pos..][0..ct.len], ct);
        req_pos += ct.len;

        const cl_hdr = "\r\nContent-Length: ";
        @memcpy(header_buf[req_pos..][0..cl_hdr.len], cl_hdr);
        req_pos += cl_hdr.len;
        var cl_buf: [20]u8 = undefined;
        const cl_len = fmtUsize(body.len, &cl_buf);
        @memcpy(header_buf[req_pos..][0..cl_len], cl_buf[0..cl_len]);
        req_pos += cl_len;
    }

    const close_hdr = "\r\nConnection: close\r\n\r\n";
    @memcpy(header_buf[req_pos..][0..close_hdr.len], close_hdr);
    req_pos += close_hdr.len;

    _ = conn.writeData(header_buf[0..req_pos]);

    // Write body if present
    if (options.body) |body| {
        if (body.len > 0) {
            _ = conn.writeData(body);
        }
    }

    var resp = parseResponse(conn.data_fd, header_buf, conn.io) orelse {
        conn.close();
        return null;
    };

    // Handle redirects (301, 302, 307, 308)
    if ((resp.status_code == 301 or resp.status_code == 302 or
        resp.status_code == 307 or resp.status_code == 308) and
        redirect_count < 3)
    {
        if (resp.getHeader("Location")) |location| {
            // Copy location before closing (it points into header_buf)
            var loc_buf: [512]u8 = undefined;
            if (location.len <= loc_buf.len) {
                @memcpy(loc_buf[0..location.len], location);
                const loc = loc_buf[0..location.len];
                conn.close();

                // 301/302 change method to GET and drop body
                var redir_method = method;
                var redir_options = options;
                if (resp.status_code == 301 or resp.status_code == 302) {
                    redir_method = "GET";
                    redir_options.body = null;
                    redir_options.content_type = null;
                }

                // Strip Authorization on cross-domain redirects
                var redir_path_buf: [512]u8 = undefined;
                if (parseUrl(loc, &redir_path_buf)) |parts| {
                    // Cross-domain: strip auth headers
                    if (!caseInsensitiveEql(parts.host, host)) {
                        redir_options = stripAuthHeaders(redir_options);
                    }
                    return requestWithRedirects(
                        parts.host,
                        parts.port,
                        redir_method,
                        parts.path,
                        redir_options,
                        header_buf,
                        redirect_count + 1,
                    );
                }
                // Relative redirect — same host
                if (loc.len > 0 and loc[0] == '/') {
                    @memcpy(redir_path_buf[0..loc.len], loc);
                    return requestWithRedirects(
                        host,
                        port,
                        redir_method,
                        redir_path_buf[0..loc.len],
                        redir_options,
                        header_buf,
                        redirect_count + 1,
                    );
                }
            }
        }
        conn.close();
        return null;
    }

    return .{ .conn = conn, .resp = resp };
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
    for (0..len) |idx| {
        buf[idx] = tmp[len - 1 - idx];
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

pub fn containsCI(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (caseInsensitiveEql(hay[i..][0..needle.len], needle)) return true;
    }
    return false;
}

fn prefixMatchCI(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    for (0..prefix.len) |i| {
        if (toLower(s[i]) != toLower(prefix[i])) return false;
    }
    return true;
}

fn toLower(ch: u8) u8 {
    if (ch >= 'A' and ch <= 'Z') return ch + 32;
    return ch;
}

fn parseInt(s: []const u8) i64 {
    var val: i64 = 0;
    for (s) |ch| {
        if (ch >= '0' and ch <= '9') {
            val = val * 10 + (ch - '0');
        }
    }
    return val;
}

fn parseHex(s: []const u8) u64 {
    var val: u64 = 0;
    for (s) |ch| {
        val <<= 4;
        if (ch >= '0' and ch <= '9') {
            val |= ch - '0';
        } else if (ch >= 'a' and ch <= 'f') {
            val |= ch - 'a' + 10;
        } else if (ch >= 'A' and ch <= 'F') {
            val |= ch - 'A' + 10;
        }
    }
    return val;
}

fn isIpAddress(s: []const u8) bool {
    if (s.len == 0) return false;
    return s[0] >= '0' and s[0] <= '9';
}

fn fmtUsize(val: usize, buf: []u8) usize {
    var tmp: [20]u8 = undefined;
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
    for (0..len) |idx| {
        buf[idx] = tmp[len - 1 - idx];
    }
    return len;
}

/// Return options with Authorization headers removed (for cross-domain redirects).
fn stripAuthHeaders(options: RequestOptions) RequestOptions {
    // We can't easily filter the slice in-place, so we just check if any auth
    // headers exist. For the common case (0-1 auth headers among few total),
    // we use a static buffer to rebuild the header list.
    const S = struct {
        var filtered: [MAX_HEADERS]HeaderEntry = undefined;
    };
    var count: usize = 0;
    for (options.headers) |hdr| {
        if (!caseInsensitiveEql(hdr.name, "Authorization")) {
            S.filtered[count] = hdr;
            count += 1;
        }
    }
    var result = options;
    result.headers = S.filtered[0..count];
    return result;
}
