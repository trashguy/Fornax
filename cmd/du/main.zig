const fx = @import("fornax");
const out = fx.io.Writer.stdout;
const err = fx.io.Writer.stderr;

const MAX_DEPTH = 8;

export fn _start() noreturn {
    const args = fx.getArgs();

    if (args.len <= 1) {
        const total = duDir("/", "/");
        printSize(total);
        out.putc('\t');
        out.puts("/\n");
    } else {
        for (args[1..]) |arg| {
            const path = argStr(arg);
            const total = duDir(path, path);
            printSize(total);
            out.putc('\t');
            out.puts(path);
            out.putc('\n');
        }
    }

    fx.exit(0);
}

fn duDir(path: []const u8, display: []const u8) u64 {
    const fd = fx.open(path);
    if (fd < 0) {
        err.puts("du: cannot open ");
        err.puts(display);
        err.putc('\n');
        return 0;
    }

    // Stat to check if it's a file
    var st: fx.Stat = undefined;
    _ = fx.stat(fd, &st);

    if (st.file_type != 1) {
        // Regular file — return its size
        _ = fx.close(fd);
        return st.size;
    }

    // Directory — read entries
    var dir_buf: [4096]u8 = undefined;
    const n = fx.read(fd, &dir_buf);
    _ = fx.close(fd);
    if (n <= 0) return 0;

    const entry_size: usize = 72;
    var total: u64 = 0;
    var off: usize = 0;
    const bytes: usize = @intCast(n);

    while (off + entry_size <= bytes) : (off += entry_size) {
        const name_bytes = dir_buf[off..][0..64];
        const file_type = readU32(dir_buf[off + 64 ..][0..4]);
        const size = readU32(dir_buf[off + 68 ..][0..4]);

        var name_len: usize = 0;
        while (name_len < 64 and name_bytes[name_len] != 0) : (name_len += 1) {}
        if (name_len == 0) continue;

        const name = name_bytes[0..name_len];

        // Skip . and ..
        if (fx.str.eql(name, ".") or fx.str.eql(name, "..")) continue;

        if (file_type == 1) {
            // Subdirectory — recurse
            var child_path: [256]u8 = undefined;
            const cp = joinPath(&child_path, path, name) orelse continue;
            const sub = duDir(cp, cp);
            total += sub;
            printSize(sub);
            out.putc('\t');
            out.puts(cp);
            out.putc('\n');
        } else {
            total += size;
        }
    }

    return total;
}

fn joinPath(buf: []u8, dir: []const u8, name: []const u8) ?[]const u8 {
    // Handle trailing slash
    const needs_slash = dir.len > 0 and dir[dir.len - 1] != '/';
    const total = dir.len + (if (needs_slash) @as(usize, 1) else 0) + name.len;
    if (total > buf.len) return null;
    @memcpy(buf[0..dir.len], dir);
    var pos = dir.len;
    if (needs_slash) {
        buf[pos] = '/';
        pos += 1;
    }
    @memcpy(buf[pos..][0..name.len], name);
    return buf[0..total];
}

fn printSize(bytes: u64) void {
    // Print size in KB (rounded up)
    const kb = (bytes + 1023) / 1024;
    padNum(kb, 8);
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
    var pad: usize = 0;
    while (pad + len < width) : (pad += 1) out.putc(' ');
    var j: usize = 0;
    while (j < len) : (j += 1) out.putc(buf[len - 1 - j]);
}

fn argStr(ptr: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (ptr[len] != 0) : (len += 1) {}
    return ptr[0..len];
}

fn readU32(bytes: *const [4]u8) u32 {
    return @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) | (@as(u32, bytes[3]) << 24);
}
