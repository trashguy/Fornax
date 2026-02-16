/// lsblk — list block devices and partitions.
///
/// Reads /dev/ directory entries and displays partition info.
const fx = @import("fornax");

const out = fx.io.Writer.stdout;

fn readInfo(path: []const u8, buf: []u8) usize {
    const fd = fx.open(path);
    if (fd < 0) return 0;
    const n = fx.read(fd, buf);
    _ = fx.close(fd);
    if (n <= 0) return 0;
    return @intCast(n);
}

/// Parse a value from "KEY=VALUE\n" formatted text.
fn getValue(text: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < text.len) {
        // Find end of line
        var eol = i;
        while (eol < text.len and text[eol] != '\n') : (eol += 1) {}
        const line = text[i..eol];

        // Check if line starts with key=
        if (line.len > key.len and fx.str.startsWith(line, key) and line[key.len] == '=') {
            return line[key.len + 1 ..];
        }
        i = eol + 1;
    }
    return null;
}

/// Format sectors as human-readable size (e.g., "64M", "512K").
fn formatSize(sectors: u64, buf: []u8) []const u8 {
    const bytes = sectors * 512;
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
    var size_buf: [32]u8 = undefined;

    out.puts("NAME      SIZE   TYPE\n");

    // Read blk0 info
    const n0 = readInfo("/dev/blk0", &info_buf);
    if (n0 > 0) {
        const text = info_buf[0..n0];
        const size_str = if (getValue(text, "SIZE")) |s|
            if (fx.str.parseUint(s)) |sectors|
                formatSize(sectors, &size_buf)
            else
                "?"
        else
            "?";
        const type_str = getValue(text, "TYPE") orelse "?";

        out.print("blk0      {s: <6} {s}\n", .{ size_str, type_str });
    }

    // Read partitions blk0p1..blk0p9
    var pi: u8 = 1;
    while (pi <= 9) : (pi += 1) {
        var path_buf: [16]u8 = undefined;
        @memcpy(path_buf[0..10], "/dev/blk0p");
        path_buf[10] = '0' + pi;
        path_buf[11] = 0;
        const path = path_buf[0..11];

        const n = readInfo(path, &info_buf);
        if (n == 0) break;

        const text = info_buf[0..n];
        const size_str = if (getValue(text, "SIZE")) |s|
            if (fx.str.parseUint(s)) |sectors|
                formatSize(sectors, &size_buf)
            else
                "?"
        else
            "?";
        const type_str = getValue(text, "TYPE") orelse "?";
        const name_str = getValue(text, "NAME") orelse "";

        out.print("+-blk0p{d}  {s: <6} {s}  {s}\n", .{ pi, size_str, type_str, name_str });
    }

    fx.exit(0);
}
