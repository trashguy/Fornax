const fx = @import("fornax");
const out = fx.io.Writer.stdout;
const err = fx.io.Writer.stderr;

export fn _start() noreturn {
    // Open /proc directory
    const dir_fd = fx.open("/proc");
    if (dir_fd < 0) {
        err.puts("ps: cannot open /proc\n");
        fx.exit(1);
    }

    // Read directory entries to discover PIDs
    var dir_buf: [4096]u8 = undefined;
    const dir_n = fx.read(dir_fd, &dir_buf);
    _ = fx.close(dir_fd);
    if (dir_n <= 0) {
        err.puts("ps: empty /proc\n");
        fx.exit(1);
    }

    // Print header
    out.puts("  PID  PPID  STATE     PAGES\n");

    // Parse DirEntry structs (72 bytes each: name[64] + file_type u32 + size u32)
    const entry_size = 72;
    var off: usize = 0;
    const total: usize = @intCast(dir_n);
    while (off + entry_size <= total) : (off += entry_size) {
        const name_bytes = dir_buf[off..][0..64];
        const file_type = readU32(dir_buf[off + 64 ..][0..4]);

        // Skip non-directory entries (meminfo etc.)
        if (file_type != 1) continue;

        // Get name length
        var name_len: usize = 0;
        while (name_len < 64 and name_bytes[name_len] != 0) : (name_len += 1) {}
        if (name_len == 0) continue;

        const name = name_bytes[0..name_len];

        // Open /proc/N/status
        var path_buf: [80]u8 = undefined;
        const path = buildPath(&path_buf, "/proc/", name, "/status");

        const status_fd = fx.open(path);
        if (status_fd < 0) continue;

        var status_buf: [256]u8 = undefined;
        const sn = fx.read(status_fd, &status_buf);
        _ = fx.close(status_fd);
        if (sn <= 0) continue;

        // Parse key-value pairs from status text
        const status_text = status_buf[0..@intCast(sn)];
        const pid_val = findValue(status_text, "pid ");
        const ppid_val = findValue(status_text, "ppid ");
        const state_val = findStringValue(status_text, "state ");
        const pages_val = findValue(status_text, "pages ");

        // Format output: "  PID  PPID  STATE     PAGES"
        padNum(pid_val, 5);
        padNum(ppid_val, 6);
        out.puts("  ");
        padStr(state_val, 10);
        padNum(pages_val, 5);
        out.putc('\n');
    }

    fx.exit(0);
}

fn buildPath(buf: []u8, prefix: []const u8, mid: []const u8, suffix: []const u8) []const u8 {
    const total_len = prefix.len + mid.len + suffix.len;
    if (total_len > buf.len) return prefix;
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..mid.len], mid);
    @memcpy(buf[prefix.len + mid.len ..][0..suffix.len], suffix);
    return buf[0..total_len];
}

fn findValue(text: []const u8, key: []const u8) u64 {
    var i: usize = 0;
    while (i + key.len <= text.len) {
        if (fx.str.eql(text[i..][0..key.len], key)) {
            var val: u64 = 0;
            var j = i + key.len;
            while (j < text.len and text[j] >= '0' and text[j] <= '9') : (j += 1) {
                val = val * 10 + (text[j] - '0');
            }
            return val;
        }
        // Skip to next line
        while (i < text.len and text[i] != '\n') : (i += 1) {}
        i += 1;
    }
    return 0;
}

fn findStringValue(text: []const u8, key: []const u8) []const u8 {
    var i: usize = 0;
    while (i + key.len <= text.len) {
        if (fx.str.eql(text[i..][0..key.len], key)) {
            const start = i + key.len;
            var end = start;
            while (end < text.len and text[end] != '\n') : (end += 1) {}
            return text[start..end];
        }
        while (i < text.len and text[i] != '\n') : (i += 1) {}
        i += 1;
    }
    return "???";
}

fn padNum(val: u64, width: usize) void {
    var buf: [20]u8 = undefined;
    var len: usize = 0;
    var v = val;
    if (v == 0) {
        buf[0] = '0';
        len = 1;
    } else {
        while (v > 0) : (v /= 10) {
            buf[len] = @intCast('0' + (v % 10));
            len += 1;
        }
    }
    // Right-align with spaces
    var pad: usize = 0;
    while (pad + len < width) : (pad += 1) out.putc(' ');
    var j: usize = 0;
    while (j < len) : (j += 1) out.putc(buf[len - 1 - j]);
}

fn padStr(s: []const u8, width: usize) void {
    out.puts(s);
    var i: usize = s.len;
    while (i < width) : (i += 1) out.putc(' ');
}

fn readU32(bytes: *const [4]u8) u32 {
    return @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) | (@as(u32, bytes[3]) << 24);
}
