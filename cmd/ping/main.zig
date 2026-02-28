/// ping — ICMP echo test for Fornax.
///
/// Usage: ping [-c count] [-i interval] [-s size] [-t ttl] [-w deadline]
///             [-W timeout] [-q] [-n] [-4] <host>
///
/// Sends ICMP echo requests and displays per-packet RTT and statistics.
const fx = @import("fornax");

const out = fx.io.Writer.stdout;
const stderr = fx.io.Writer.stderr;

// --- Argument parsing state ---
const Options = struct {
    host: []const u8 = "",
    count: u32 = 4,
    interval_ms: u64 = 1000,
    deadline_s: u32 = 0,
    size: u32 = 56,
    ttl: u32 = 0,
    quiet: bool = false,
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

/// Try to parse a dotted-decimal IP address. Returns true if valid.
fn parseIp(s: []const u8, ip_out: *[4]u8) bool {
    var octet: u32 = 0;
    var dots: u32 = 0;
    var has_digit = false;

    for (s) |ch| {
        if (ch >= '0' and ch <= '9') {
            octet = octet * 10 + (ch - '0');
            if (octet > 255) return false;
            has_digit = true;
        } else if (ch == '.') {
            if (!has_digit) return false;
            if (dots >= 3) return false;
            ip_out[dots] = @truncate(octet);
            dots += 1;
            octet = 0;
            has_digit = false;
        } else {
            return false;
        }
    }
    if (!has_digit or dots != 3) return false;
    ip_out[3] = @truncate(octet);
    return true;
}

/// Parse a decimal number from a string.
fn parseU32(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    var val: u32 = 0;
    for (s) |ch| {
        if (ch < '0' or ch > '9') return null;
        val = val * 10 + (ch - '0');
    }
    return val;
}

/// Parse "time=N" from reply text, return RTT in ms.
fn parseReplyRtt(reply: []const u8) u32 {
    // Search for "time="
    const needle = "time=";
    var i: usize = 0;
    while (i + needle.len <= reply.len) : (i += 1) {
        if (sliceEql(reply[i..][0..needle.len], needle)) {
            var j = i + needle.len;
            var val: u32 = 0;
            while (j < reply.len and reply[j] >= '0' and reply[j] <= '9') : (j += 1) {
                val = val * 10 + (reply[j] - '0');
            }
            return val;
        }
    }
    return 0;
}

/// Format a u32 into a decimal string, return slice.
fn fmtDec(buf: []u8, val: u32) []const u8 {
    if (val == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var v = val;
    var tmp: [10]u8 = undefined;
    var len: usize = 0;
    while (v > 0) : (len += 1) {
        tmp[len] = @truncate('0' + @as(u8, @truncate(v % 10)));
        v /= 10;
    }
    for (0..len) |j| {
        buf[j] = tmp[len - 1 - j];
    }
    return buf[0..len];
}

/// Write a ctl command: open ctl fd, write command, close.
fn writeCtl(ctl_path_slice: []const u8, cmd: []const u8, val: u32) void {
    const fd = fx.open(ctl_path_slice);
    if (fd < 0) return;
    var cmd_buf: [32]u8 = undefined;
    @memcpy(cmd_buf[0..cmd.len], cmd);
    cmd_buf[cmd.len] = ' ';
    var dec_buf: [10]u8 = undefined;
    const val_str = fmtDec(&dec_buf, val);
    @memcpy(cmd_buf[cmd.len + 1 ..][0..val_str.len], val_str);
    _ = fx.write(fd, cmd_buf[0 .. cmd.len + 1 + val_str.len]);
    _ = fx.close(fd);
}

export fn _start() noreturn {
    const args = fx.getArgs();

    if (args.len < 2) {
        stderr.puts("Usage: ping [-c count] [-i interval] [-s size] [-t ttl] [-w deadline] [-q] <host>\n");
        fx.exit(1);
    }

    var opts = Options{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = cstr(args[i]);
        if (arg.len == 0) continue;

        if (sliceEql(arg, "-c")) {
            i += 1;
            if (i >= args.len) break;
            opts.count = parseU32(cstr(args[i])) orelse 4;
        } else if (sliceEql(arg, "-i")) {
            i += 1;
            if (i >= args.len) break;
            const secs = parseU32(cstr(args[i])) orelse 1;
            opts.interval_ms = @as(u64, secs) * 1000;
        } else if (sliceEql(arg, "-s")) {
            i += 1;
            if (i >= args.len) break;
            opts.size = parseU32(cstr(args[i])) orelse 56;
            if (opts.size > 1472) opts.size = 1472;
        } else if (sliceEql(arg, "-t")) {
            i += 1;
            if (i >= args.len) break;
            opts.ttl = parseU32(cstr(args[i])) orelse 0;
            if (opts.ttl > 255) opts.ttl = 255;
        } else if (sliceEql(arg, "-w")) {
            i += 1;
            if (i >= args.len) break;
            opts.deadline_s = parseU32(cstr(args[i])) orelse 0;
        } else if (sliceEql(arg, "-W")) {
            i += 1; // accept but ignore — kernel handles timeout
        } else if (sliceEql(arg, "-q")) {
            opts.quiet = true;
        } else if (sliceEql(arg, "-n") or sliceEql(arg, "-4")) {
            // noop — already numeric, already IPv4-only
        } else if (arg[0] != '-') {
            opts.host = arg;
        } else {
            stderr.puts("ping: unknown option '");
            stderr.puts(arg);
            stderr.puts("'\n");
        }
    }

    if (opts.host.len == 0) {
        stderr.puts("ping: missing host operand\n");
        fx.exit(1);
    }

    // Resolve target IP
    var ip: [4]u8 = undefined;
    var ip_str_buf: [64]u8 = undefined;
    var ip_str: []const u8 = undefined;

    if (parseIp(opts.host, &ip)) {
        // Already an IP
        ip_str = opts.host;
    } else {
        // DNS resolution
        const dns_fd = fx.open("/net/dns");
        if (dns_fd < 0) {
            stderr.puts("ping: cannot open /net/dns\n");
            fx.exit(1);
        }

        // Build "query <host>"
        var query_buf: [256]u8 = undefined;
        const prefix = "query ";
        @memcpy(query_buf[0..prefix.len], prefix);
        if (opts.host.len > query_buf.len - prefix.len) {
            stderr.puts("ping: hostname too long\n");
            fx.exit(1);
        }
        @memcpy(query_buf[prefix.len..][0..opts.host.len], opts.host);
        const query_len = prefix.len + opts.host.len;

        const wr = fx.write(dns_fd, query_buf[0..query_len]);
        if (wr <= 0) {
            stderr.puts("ping: DNS query failed\n");
            _ = fx.close(dns_fd);
            fx.exit(1);
        }

        var dns_buf: [64]u8 = undefined;
        const rn = fx.read(dns_fd, &dns_buf);
        _ = fx.close(dns_fd);

        if (rn <= 0) {
            stderr.puts("ping: DNS resolution failed for ");
            stderr.puts(opts.host);
            stderr.puts("\n");
            fx.exit(1);
        }

        var dns_len: usize = @intCast(rn);
        // Trim trailing newline
        if (dns_len > 0 and dns_buf[dns_len - 1] == '\n') dns_len -= 1;
        const resolved = dns_buf[0..dns_len];

        if (!parseIp(resolved, &ip)) {
            stderr.puts("ping: bad DNS response: ");
            stderr.puts(resolved);
            stderr.puts("\n");
            fx.exit(1);
        }

        @memcpy(ip_str_buf[0..dns_len], resolved);
        ip_str = ip_str_buf[0..dns_len];
    }

    // Print header
    var dec_buf: [10]u8 = undefined;
    out.puts("PING ");
    out.puts(opts.host);
    out.puts(" (");
    out.puts(ip_str);
    out.puts("): ");
    out.puts(fmtDec(&dec_buf, opts.size));
    out.puts(" data bytes\n");

    // Open ICMP connection
    const clone_fd = fx.open("/net/icmp/clone");
    if (clone_fd < 0) {
        stderr.puts("ping: failed to open /net/icmp/clone\n");
        fx.exit(1);
    }

    var conn_buf: [16]u8 = undefined;
    const conn_n = fx.read(clone_fd, &conn_buf);
    if (conn_n <= 0) {
        stderr.puts("ping: failed to read clone\n");
        fx.exit(1);
    }
    _ = fx.close(clone_fd);

    var conn_num_len: usize = @intCast(conn_n);
    if (conn_num_len > 0 and conn_buf[conn_num_len - 1] == '\n') {
        conn_num_len -= 1;
    }
    const conn_num = conn_buf[0..conn_num_len];

    // Build ctl path and connect
    var ctl_path = fx.path.PathBuf.from("/net/icmp/");
    _ = ctl_path.appendRaw(conn_num);
    _ = ctl_path.appendRaw("/ctl");

    const ctl_fd = fx.open(ctl_path.slice());
    if (ctl_fd < 0) {
        stderr.puts("ping: failed to open ctl\n");
        fx.exit(1);
    }

    // Build "connect <ip>"
    var connect_cmd: [32]u8 = undefined;
    const connect_prefix = "connect ";
    @memcpy(connect_cmd[0..connect_prefix.len], connect_prefix);
    @memcpy(connect_cmd[connect_prefix.len..][0..ip_str.len], ip_str);
    _ = fx.write(ctl_fd, connect_cmd[0 .. connect_prefix.len + ip_str.len]);
    _ = fx.close(ctl_fd);

    // Send ctl commands for non-default size and TTL
    if (opts.size != 56) {
        writeCtl(ctl_path.slice(), "size", opts.size);
    }
    if (opts.ttl > 0) {
        writeCtl(ctl_path.slice(), "ttl", opts.ttl);
    }

    // Build data path
    var data_path = fx.path.PathBuf.from("/net/icmp/");
    _ = data_path.appendRaw(conn_num);
    _ = data_path.appendRaw("/data");

    const data_fd = fx.open(data_path.slice());
    if (data_fd < 0) {
        stderr.puts("ping: failed to open data\n");
        fx.exit(1);
    }

    // Stats
    var sent: u32 = 0;
    var received: u32 = 0;
    var rtt_min: u32 = 0xFFFFFFFF;
    var rtt_max: u32 = 0;
    var rtt_total: u64 = 0;

    // Deadline tracking
    const start_ms: u64 = if (opts.deadline_s > 0) fx.getUptime() else 0;
    const deadline_ms: u64 = @as(u64, opts.deadline_s) * 1000;

    // Ping loop
    var seq: u32 = 0;
    while (seq < opts.count) : (seq += 1) {
        // Check deadline before sending
        if (opts.deadline_s > 0) {
            const elapsed = fx.getUptime() - start_ms;
            if (elapsed >= deadline_ms) break;
        }

        _ = fx.write(data_fd, "ping");
        sent += 1;

        var reply_buf: [256]u8 = undefined;
        const n = fx.read(data_fd, &reply_buf);
        if (n > 0) {
            const reply = reply_buf[0..@intCast(n)];
            if (!opts.quiet) {
                out.puts(reply);
            }
            received += 1;

            const rtt = parseReplyRtt(reply);
            rtt_total += rtt;
            if (rtt < rtt_min) rtt_min = rtt;
            if (rtt > rtt_max) rtt_max = rtt;
        } else {
            if (!opts.quiet) {
                out.puts("Request timeout for seq ");
                var seq_buf: [10]u8 = undefined;
                out.puts(fmtDec(&seq_buf, seq));
                out.puts("\n");
            }
        }

        // Sleep between pings (skip after last)
        if (seq + 1 < opts.count) {
            // Check deadline before sleeping
            if (opts.deadline_s > 0) {
                const elapsed = fx.getUptime() - start_ms;
                if (elapsed >= deadline_ms) break;
                // Sleep the lesser of interval and remaining deadline
                const remaining = deadline_ms - elapsed;
                const sleep_ms = if (opts.interval_ms < remaining) opts.interval_ms else remaining;
                fx.sleep(sleep_ms);
            } else {
                fx.sleep(opts.interval_ms);
            }
        }
    }

    _ = fx.close(data_fd);

    // Statistics
    out.puts("\n--- ");
    out.puts(opts.host);
    out.puts(" ping statistics ---\n");

    out.puts(fmtDec(&dec_buf, sent));
    out.puts(" packets transmitted, ");
    out.puts(fmtDec(&dec_buf, received));
    out.puts(" received, ");

    // Compute packet loss percentage
    const loss: u32 = if (sent > 0) ((sent - received) * 100) / sent else 0;
    out.puts(fmtDec(&dec_buf, loss));
    out.puts("% packet loss\n");

    if (received > 0) {
        if (rtt_min == 0xFFFFFFFF) rtt_min = 0;
        const rtt_avg: u32 = @truncate(rtt_total / received);
        out.puts("rtt min/avg/max = ");
        out.puts(fmtDec(&dec_buf, rtt_min));
        out.puts("/");
        out.puts(fmtDec(&dec_buf, rtt_avg));
        out.puts("/");
        out.puts(fmtDec(&dec_buf, rtt_max));
        out.puts(" ms\n");
    }

    fx.exit(0);
}
