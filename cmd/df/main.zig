/// df — report filesystem disk space usage.
///
/// Reads /disk/ctl for filesystem stats and displays usage table.
const fx = @import("fornax");

const out = fx.io.Writer.stdout;

/// Parse a value from "KEY=VALUE\n" formatted text.
fn getValue(text: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < text.len) {
        var eol = i;
        while (eol < text.len and text[eol] != '\n') : (eol += 1) {}
        const line = text[i..eol];

        if (line.len > key.len and fx.str.startsWith(line, key) and line[key.len] == '=') {
            return line[key.len + 1 ..];
        }
        i = eol + 1;
    }
    return null;
}

/// Format blocks as human-readable size.
fn formatBlockSize(blocks: u64, bsize: u64, buf: []u8) []const u8 {
    const bytes = blocks * bsize;
    var pos: usize = 0;

    if (bytes >= 1024 * 1024 * 1024) {
        pos = appendDec(buf, pos, bytes / (1024 * 1024 * 1024));
        if (pos < buf.len) {
            buf[pos] = 'G';
            pos += 1;
        }
    } else if (bytes >= 1024 * 1024) {
        pos = appendDec(buf, pos, bytes / (1024 * 1024));
        if (pos < buf.len) {
            buf[pos] = 'M';
            pos += 1;
        }
    } else if (bytes >= 1024) {
        pos = appendDec(buf, pos, bytes / 1024);
        if (pos < buf.len) {
            buf[pos] = 'K';
            pos += 1;
        }
    } else {
        pos = appendDec(buf, pos, bytes);
        if (pos < buf.len) {
            buf[pos] = 'B';
            pos += 1;
        }
    }
    return buf[0..pos];
}

fn appendDec(buf: []u8, pos: usize, val: u64) usize {
    if (val == 0) {
        if (pos < buf.len) {
            buf[pos] = '0';
            return pos + 1;
        }
        return pos;
    }
    var tmp: [20]u8 = undefined;
    var len: usize = 0;
    var v = val;
    while (v > 0) : (v /= 10) {
        tmp[len] = '0' + @as(u8, @intCast(v % 10));
        len += 1;
    }
    if (pos + len > buf.len) return pos;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        buf[pos + i] = tmp[len - 1 - i];
    }
    return pos + len;
}

export fn _start() noreturn {
    var info_buf: [512]u8 = undefined;

    const fd = fx.open("/disk/ctl");
    if (fd < 0) {
        _ = fx.write(2, "df: cannot open /disk/ctl\n");
        fx.exit(1);
    }
    const n = fx.read(fd, &info_buf);
    _ = fx.close(fd);

    if (n <= 0) {
        _ = fx.write(2, "df: cannot read /disk/ctl\n");
        fx.exit(1);
    }

    const text = info_buf[0..@as(usize, @intCast(n))];

    const total = if (getValue(text, "TOTAL")) |s| fx.str.parseUint(s) orelse 0 else 0;
    const free = if (getValue(text, "FREE")) |s| fx.str.parseUint(s) orelse 0 else 0;
    const bsize = if (getValue(text, "BSIZE")) |s| fx.str.parseUint(s) orelse 4096 else 4096;
    const used = if (total > free) total - free else 0;

    var size_buf: [32]u8 = undefined;
    var used_buf: [32]u8 = undefined;
    var avail_buf: [32]u8 = undefined;

    const size_str = formatBlockSize(total, bsize, &size_buf);
    const used_str = formatBlockSize(used, bsize, &used_buf);
    const avail_str = formatBlockSize(free, bsize, &avail_buf);

    out.puts("Filesystem    Size  Used  Avail  Mounted on\n");
    out.print("/dev/blk0p1   {s: <5} {s: <5} {s: <6} /disk\n", .{ size_str, used_str, avail_str });

    fx.exit(0);
}
