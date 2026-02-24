/// curl — HTTP client for Fornax.
///
/// Usage: curl [options] <url>
///
/// Options:
///   -X METHOD        HTTP method (default: GET, or POST if -d used)
///   -H "Name: Value" Custom header (up to 8)
///   -d "data"        POST body (implies POST if no -X)
///   -o file          Write body to file
///   -O               Write to file named from URL's last path component
///   -s               Silent mode (suppress errors)
///   -v               Verbose (show request/response headers on stderr)
///   -I               HEAD request, show response headers only
///   -i               Include response headers in output
///   -L               Follow redirects (default, for compatibility)
///   -k               Skip TLS certificate verification (insecure)
///   -u user:pass     Basic authentication
///   -A "agent"       Custom User-Agent
///   -e url           Referer header
///   -b "cookies"     Send cookies
///   -w "\n"          Append string after output
///   --compressed     Request gzip and auto-decompress
const fx = @import("fornax");
const curl_options = @import("curl_options");
const has_tls = curl_options.has_tls;
const tls = if (has_tls) @import("tls") else struct {};

const http = fx.http;
const deflate = fx.deflate;
const out = fx.io.Writer.stdout;
const stderr = fx.io.Writer.stderr;

// --- BSS buffers ---
var header_buf: [8192]u8 linksection(".bss") = undefined;
var body_buf: [65536]u8 linksection(".bss") = undefined;
var custom_hdrs: [12]http.HeaderEntry = undefined;
var custom_hdr_count: usize = 0;

// Basic auth buffer
var basic_auth_buf: [256]u8 = undefined;
var basic_auth_len: usize = 0;

// Output file path
var out_file_buf: [256]u8 = undefined;
var out_file_len: usize = 0;

// Write-out string
var write_out_buf: [64]u8 = undefined;
var write_out_len: usize = 0;

// --- TLS support (conditionally compiled) ---
const TlsSupport = if (has_tls) struct {
    const T = @import("tls");

    pub var conn: T.TlsConnection linksection(".bss") = undefined;
    pub var pem_buf: [262144]u8 linksection(".bss") = undefined;
    pub var ta_data: [131072]u8 linksection(".bss") = undefined;
    pub var anchors: [200]T.TrustAnchor linksection(".bss") = undefined;
    pub var anchor_count: usize = 0;
    pub var initialized: bool = false;
    pub var server_name_buf: [256]u8 = undefined;
    pub var insecure_mode: bool = false;

    pub fn init() bool {
        if (initialized) return anchor_count > 0 or insecure_mode;
        initialized = true;
        if (insecure_mode) return true;

        const fd = fx.open("/etc/ssl/certs/ca-certificates.crt");
        if (fd < 0) return false;

        var pem_len: usize = 0;
        while (pem_len < pem_buf.len) {
            const n = fx.read(fd, pem_buf[pem_len..]);
            if (n <= 0) break;
            pem_len += @intCast(n);
        }
        _ = fx.close(fd);
        if (pem_len == 0) return false;

        var der_buf: [32768]u8 = undefined;
        if (T.loadTrustAnchors(pem_buf[0..pem_len], &der_buf, &ta_data, &anchors)) |count| {
            anchor_count = count;
            return true;
        }
        return false;
    }

    pub fn onConnect(data_fd: i32, host: []const u8) ?http.IoFns {
        if (host.len >= server_name_buf.len) return null;
        @memcpy(server_name_buf[0..host.len], host);
        server_name_buf[host.len] = 0;
        const sname: [*:0]const u8 = @ptrCast(&server_name_buf);

        if (insecure_mode) {
            if (!conn.initInsecure(data_fd, sname)) return null;
        } else {
            if (!conn.initInPlace(data_fd, sname, &anchors, anchor_count)) return null;
        }

        return conn.ioFns();
    }
} else struct {};

// --- Gzip decompression support ---
var sliding_window: [32768]u8 linksection(".bss") = undefined;
var inflate_out_buf: [8192]u8 linksection(".bss") = undefined;

const GzipReaderCtx = struct {
    resp: *http.Response,
    remaining: usize,
};

fn gzipReadFn(ctx_ptr: *anyopaque, buf: []u8) isize {
    const ctx: *GzipReaderCtx = @ptrCast(@alignCast(ctx_ptr));
    return ctx.resp.readBody(buf);
}

// --- Argument parsing state ---
const Options = struct {
    method: []const u8 = "GET",
    url: []const u8 = "",
    data: []const u8 = "",
    output_file: []const u8 = "",
    silent: bool = false,
    verbose: bool = false,
    head_only: bool = false,
    include_headers: bool = false,
    insecure: bool = false,
    user: []const u8 = "",
    user_agent: []const u8 = "",
    referer: []const u8 = "",
    cookies: []const u8 = "",
    write_out: []const u8 = "",
    compressed: bool = false,
    auto_output: bool = false,
    has_explicit_method: bool = false,
};

fn cstr(ptr: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (ptr[len] != 0) : (len += 1) {}
    return ptr[0..len];
}

fn sliceEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (ac != bc) return false;
    }
    return true;
}

fn starts(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    return sliceEql(s[0..prefix.len], prefix);
}

export fn _start() noreturn {
    const args = fx.getArgs();

    if (args.len < 2) {
        stderr.puts("Usage: curl [options] <url>\n");
        fx.exit(1);
    }

    var opts = Options{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = cstr(args[i]);

        if (arg.len == 0) continue;

        if (arg[0] != '-') {
            // URL
            opts.url = arg;
            continue;
        }

        if (sliceEql(arg, "-X") or sliceEql(arg, "--request")) {
            i += 1;
            if (i >= args.len) break;
            opts.method = cstr(args[i]);
            opts.has_explicit_method = true;
        } else if (sliceEql(arg, "-H") or sliceEql(arg, "--header")) {
            i += 1;
            if (i >= args.len) break;
            addCustomHeader(cstr(args[i]));
        } else if (sliceEql(arg, "-d") or sliceEql(arg, "--data")) {
            i += 1;
            if (i >= args.len) break;
            opts.data = cstr(args[i]);
            if (!opts.has_explicit_method) opts.method = "POST";
        } else if (sliceEql(arg, "-o") or sliceEql(arg, "--output")) {
            i += 1;
            if (i >= args.len) break;
            opts.output_file = cstr(args[i]);
        } else if (sliceEql(arg, "-O")) {
            opts.auto_output = true;
        } else if (sliceEql(arg, "-s") or sliceEql(arg, "--silent")) {
            opts.silent = true;
        } else if (sliceEql(arg, "-v") or sliceEql(arg, "--verbose")) {
            opts.verbose = true;
        } else if (sliceEql(arg, "-I") or sliceEql(arg, "--head")) {
            opts.head_only = true;
            if (!opts.has_explicit_method) opts.method = "HEAD";
        } else if (sliceEql(arg, "-i") or sliceEql(arg, "--include")) {
            opts.include_headers = true;
        } else if (sliceEql(arg, "-L") or sliceEql(arg, "--location")) {
            // Already default — noop for compat
        } else if (sliceEql(arg, "-k") or sliceEql(arg, "--insecure")) {
            opts.insecure = true;
        } else if (sliceEql(arg, "-u") or sliceEql(arg, "--user")) {
            i += 1;
            if (i >= args.len) break;
            opts.user = cstr(args[i]);
        } else if (sliceEql(arg, "-A") or sliceEql(arg, "--user-agent")) {
            i += 1;
            if (i >= args.len) break;
            opts.user_agent = cstr(args[i]);
        } else if (sliceEql(arg, "-e") or sliceEql(arg, "--referer")) {
            i += 1;
            if (i >= args.len) break;
            opts.referer = cstr(args[i]);
        } else if (sliceEql(arg, "-b") or sliceEql(arg, "--cookie")) {
            i += 1;
            if (i >= args.len) break;
            opts.cookies = cstr(args[i]);
        } else if (sliceEql(arg, "-w") or sliceEql(arg, "--write-out")) {
            i += 1;
            if (i >= args.len) break;
            opts.write_out = cstr(args[i]);
        } else if (sliceEql(arg, "--compressed")) {
            opts.compressed = true;
        } else if (sliceEql(arg, "--help") or sliceEql(arg, "-h")) {
            printHelp();
            fx.exit(0);
        } else {
            if (!opts.silent) {
                stderr.puts("curl: unknown option '");
                stderr.puts(arg);
                stderr.puts("'\n");
            }
        }
    }

    if (opts.url.len == 0) {
        if (!opts.silent) stderr.puts("curl: no URL specified\n");
        fx.exit(1);
    }

    doRequest(&opts);
    fx.exit(0);
}

fn addCustomHeader(hdr_str: []const u8) void {
    if (custom_hdr_count >= 8) return;
    // Find ": " separator
    var colon: usize = 0;
    while (colon < hdr_str.len and hdr_str[colon] != ':') : (colon += 1) {}
    if (colon >= hdr_str.len) return;

    const name = hdr_str[0..colon];
    var vstart = colon + 1;
    while (vstart < hdr_str.len and hdr_str[vstart] == ' ') : (vstart += 1) {}
    const value = hdr_str[vstart..];

    custom_hdrs[custom_hdr_count] = .{ .name = name, .value = value };
    custom_hdr_count += 1;
}

fn doRequest(opts: *const Options) void {
    // Parse URL
    var path_buf: [512]u8 = undefined;
    const parts = http.parseUrl(opts.url, &path_buf) orelse {
        if (!opts.silent) {
            stderr.puts("curl: invalid URL: ");
            stderr.puts(opts.url);
            stderr.puts("\n");
        }
        fx.exit(1);
    };

    const use_tls = parts.tls;

    // Initialize TLS if needed
    if (has_tls and use_tls) {
        if (opts.insecure) TlsSupport.insecure_mode = true;
        if (!TlsSupport.init()) {
            if (!opts.silent) stderr.puts("curl: TLS initialization failed\n");
            fx.exit(1);
        }
    } else if (use_tls and !has_tls) {
        if (!opts.silent) stderr.puts("curl: HTTPS not supported (built without TLS)\n");
        fx.exit(1);
    }

    // Build header list
    var all_hdrs: [12]http.HeaderEntry = undefined;
    var hdr_count: usize = 0;

    // Add Basic auth if -u specified
    if (opts.user.len > 0) {
        var b64_buf: [200]u8 = undefined;
        const encoded = http.base64Encode(opts.user, &b64_buf);
        // Build "Basic <encoded>" into basic_auth_buf
        const prefix = "Basic ";
        @memcpy(basic_auth_buf[0..prefix.len], prefix);
        @memcpy(basic_auth_buf[prefix.len..][0..encoded.len], encoded);
        basic_auth_len = prefix.len + encoded.len;
        all_hdrs[hdr_count] = .{ .name = "Authorization", .value = basic_auth_buf[0..basic_auth_len] };
        hdr_count += 1;
    }

    // Accept-Encoding if --compressed
    if (opts.compressed) {
        all_hdrs[hdr_count] = .{ .name = "Accept-Encoding", .value = "gzip" };
        hdr_count += 1;
    }

    // Custom User-Agent
    if (opts.user_agent.len > 0) {
        all_hdrs[hdr_count] = .{ .name = "User-Agent", .value = opts.user_agent };
        hdr_count += 1;
    }

    // Referer
    if (opts.referer.len > 0) {
        all_hdrs[hdr_count] = .{ .name = "Referer", .value = opts.referer };
        hdr_count += 1;
    }

    // Cookies
    if (opts.cookies.len > 0) {
        all_hdrs[hdr_count] = .{ .name = "Cookie", .value = opts.cookies };
        hdr_count += 1;
    }

    // Custom -H headers
    for (custom_hdrs[0..custom_hdr_count]) |h| {
        if (hdr_count < all_hdrs.len) {
            all_hdrs[hdr_count] = h;
            hdr_count += 1;
        }
    }

    var req_opts = http.RequestOptions{
        .headers = all_hdrs[0..hdr_count],
    };

    if (has_tls and use_tls) {
        req_opts.on_connect = &TlsSupport.onConnect;
    }

    // Set body for POST/PUT
    if (opts.data.len > 0) {
        req_opts.body = opts.data;
        req_opts.content_type = "application/x-www-form-urlencoded";
    }

    // Verbose: show request headers
    if (opts.verbose) {
        stderr.puts("> ");
        stderr.puts(opts.method);
        stderr.puts(" ");
        stderr.puts(parts.path);
        stderr.puts(" HTTP/1.1\n> Host: ");
        stderr.puts(parts.host);
        stderr.puts("\n");
        for (all_hdrs[0..hdr_count]) |h| {
            stderr.puts("> ");
            stderr.puts(h.name);
            stderr.puts(": ");
            stderr.puts(h.value);
            stderr.puts("\n");
        }
        stderr.puts(">\n");
    }

    var result = http.request(parts.host, parts.port, opts.method, parts.path, req_opts, &header_buf) orelse {
        if (!opts.silent) {
            stderr.puts("curl: failed to connect to ");
            stderr.puts(parts.host);
            stderr.puts("\n");
        }
        fx.exit(1);
    };

    // Verbose: show response headers
    if (opts.verbose) {
        stderr.print("< HTTP/1.1 {d}\n", .{result.resp.status_code});
        for (0..result.resp.header_count) |hi| {
            stderr.puts("< ");
            stderr.puts(result.resp.headers[hi].name);
            stderr.puts(": ");
            stderr.puts(result.resp.headers[hi].value);
            stderr.puts("\n");
        }
        stderr.puts("<\n");
    }

    // -I: show headers only
    if (opts.head_only) {
        if (opts.include_headers or !opts.verbose) {
            printResponseHeaders(&result.resp);
        }
        result.conn.close();
        return;
    }

    // -i: include headers in output
    if (opts.include_headers) {
        printResponseHeaders(&result.resp);
    }

    // Determine output fd
    var out_fd: i32 = 1; // stdout
    if (opts.output_file.len > 0) {
        out_fd = fx.create(opts.output_file, 0);
        if (out_fd < 0) {
            if (!opts.silent) {
                stderr.puts("curl: cannot create ");
                stderr.puts(opts.output_file);
                stderr.puts("\n");
            }
            result.conn.close();
            fx.exit(1);
        }
    } else if (opts.auto_output) {
        // -O: derive filename from URL path
        const fname = lastPathComponent(parts.path);
        if (fname.len > 0 and fname.len <= out_file_buf.len) {
            @memcpy(out_file_buf[0..fname.len], fname);
            out_file_len = fname.len;
            out_fd = fx.create(out_file_buf[0..out_file_len], 0);
            if (out_fd < 0) {
                if (!opts.silent) {
                    stderr.puts("curl: cannot create ");
                    stderr.puts(out_file_buf[0..out_file_len]);
                    stderr.puts("\n");
                }
                result.conn.close();
                fx.exit(1);
            }
        }
    }

    // Check for gzip content-encoding
    var is_gzip = false;
    if (opts.compressed) {
        if (result.resp.getHeader("Content-Encoding")) |ce| {
            if (http.containsCI(ce, "gzip")) {
                is_gzip = true;
            }
        }
    }

    // Read body
    if (is_gzip) {
        readGzipBody(&result.resp, out_fd);
    } else {
        _ = result.resp.readBodyToFd(out_fd, &body_buf);
    }

    // Close output file if not stdout
    if (out_fd != 1) _ = fx.close(out_fd);

    result.conn.close();

    // -w / --write-out
    if (opts.write_out.len > 0) {
        // Simple: interpret \n as newline
        writeOutString(opts.write_out);
    }
}

fn readGzipBody(resp: *http.Response, out_fd: i32) void {
    var ctx = GzipReaderCtx{ .resp = resp, .remaining = 0 };
    var io_buf: [4096]u8 = undefined;
    var bit_reader = deflate.BitReader.init(&gzipReadFn, @ptrCast(&ctx), &io_buf);
    var inflater = deflate.Inflater.init(&sliding_window, &inflate_out_buf);

    if (!deflate.skipGzipHeader(&bit_reader)) return;

    while (!inflater.done) {
        const n = inflater.readBytes(&bit_reader, &body_buf);
        if (n == 0) break;
        var written: usize = 0;
        while (written < n) {
            const w = fx.syscall.write(out_fd, body_buf[written..n]);
            if (w <= 0) return;
            written += @intCast(w);
        }
    }
}

fn printResponseHeaders(resp: *const http.Response) void {
    out.print("HTTP/1.1 {d}\n", .{resp.status_code});
    for (0..resp.header_count) |i| {
        out.puts(resp.headers[i].name);
        out.puts(": ");
        out.puts(resp.headers[i].value);
        out.puts("\n");
    }
    out.puts("\n");
}

fn lastPathComponent(path: []const u8) []const u8 {
    var last_slash: usize = 0;
    for (0..path.len) |i| {
        if (path[i] == '/') last_slash = i + 1;
    }
    const component = path[last_slash..];
    // Strip query string
    for (0..component.len) |i| {
        if (component[i] == '?') return component[0..i];
    }
    return component;
}

fn writeOutString(s: []const u8) void {
    var i: usize = 0;
    while (i < s.len) {
        if (i + 1 < s.len and s[i] == '\\' and s[i + 1] == 'n') {
            _ = fx.write(1, "\n");
            i += 2;
        } else {
            _ = fx.write(1, s[i..][0..1]);
            i += 1;
        }
    }
}

fn printHelp() void {
    out.puts(
        \\curl — HTTP client for Fornax
        \\
        \\Usage: curl [options] <url>
        \\
        \\Options:
        \\  -X METHOD       HTTP method (GET, POST, PUT, DELETE, PATCH, HEAD)
        \\  -H "Name: Val"  Custom header (up to 8)
        \\  -d "data"       POST body (implies POST)
        \\  -o file         Write body to file
        \\  -O              Write to file named from URL
        \\  -s              Silent mode
        \\  -v              Verbose (show headers on stderr)
        \\  -I              HEAD request (headers only)
        \\  -i              Include response headers in output
        \\  -L              Follow redirects (default)
        \\  -k              Skip TLS verification (insecure)
        \\  -u user:pass    Basic authentication
        \\  -A "agent"      Custom User-Agent
        \\  -e url          Referer header
        \\  -b "cookies"    Send cookies
        \\  -w "\n"         Append string after output
        \\  --compressed    Request gzip decompression
        \\
    );
}
