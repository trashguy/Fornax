/// ls — list directory contents.
///
/// Flags: -l long format, -a show dotfiles, -s show size, -h human-readable
/// Flags can be combined: -lash
const fx = @import("fornax");

const out = fx.io.Writer.stdout;
const err = fx.io.Writer.stderr;

var flag_long: bool = false;
var flag_all: bool = false;
var flag_size: bool = false;
var flag_human: bool = false;

fn listDir(path: []const u8) void {
    const fd = fx.open(path);
    if (fd < 0) {
        err.print("ls: {s}: not found\n", .{path});
        return;
    }
    defer _ = fx.close(fd);

    var dir_buf: [4096]u8 = undefined;
    const n = fx.read(fd, &dir_buf);
    if (n <= 0) return;

    const bytes: usize = @intCast(n);
    const entry_size = @sizeOf(fx.DirEntry);
    var off: usize = 0;
    while (off + entry_size <= bytes) : (off += entry_size) {
        const entry: *const fx.DirEntry = @ptrCast(@alignCast(dir_buf[off..][0..entry_size]));
        // Extract null-terminated name
        const name = blk: {
            for (entry.name, 0..) |c, j| {
                if (c == 0) break :blk entry.name[0..j];
            }
            break :blk &entry.name;
        };

        // Skip dotfiles unless -a
        if (!flag_all and name.len > 0 and name[0] == '.') continue;

        if (flag_long or flag_size) {
            // Need stat info — build full path
            var full_path: [320]u8 = undefined;
            var fp_len: usize = 0;

            if (path.len > 0) {
                @memcpy(full_path[0..path.len], path);
                fp_len = path.len;
                if (path[path.len - 1] != '/') {
                    full_path[fp_len] = '/';
                    fp_len += 1;
                }
            }
            if (fp_len + name.len < full_path.len) {
                @memcpy(full_path[fp_len..][0..name.len], name);
                fp_len += name.len;
            }

            const file_fd = fx.open(full_path[0..fp_len]);
            if (file_fd >= 0) {
                var st: fx.Stat = undefined;
                _ = fx.stat(file_fd, &st);
                _ = fx.close(file_fd);

                if (flag_long) {
                    const mode_str = formatMode(st.mode);
                    var uid_buf: [10]u8 = undefined;
                    const uid_str = fmtDec(st.uid, &uid_buf);
                    var size_buf: [10]u8 = undefined;
                    const size_str = if (flag_human) fmtHuman(st.size, &size_buf) else fmtDec(st.size, &size_buf);
                    out.print("{s} {s} {s} {s}\n", .{ &mode_str, uid_str, size_str, name });
                } else {
                    // -s only (no -l)
                    var size_buf: [10]u8 = undefined;
                    const size_str = if (flag_human) fmtHuman(st.size, &size_buf) else fmtDec(st.size, &size_buf);
                    out.print("{s} {s}\n", .{ size_str, name });
                }
            } else {
                printSimple(name, entry.file_type);
            }
        } else {
            printSimple(name, entry.file_type);
        }
    }
}

fn printSimple(name: []const u8, file_type: u32) void {
    if (file_type == 1) {
        out.print("{s}/\n", .{name});
    } else {
        out.print("{s}\n", .{name});
    }
}

fn formatMode(mode: u32) [10]u8 {
    var buf: [10]u8 = undefined;

    const ftype = mode & 0o170000;
    buf[0] = if (ftype == 0o040000) 'd' else if (ftype == 0o120000) 'l' else '-';

    buf[1] = if (mode & 0o400 != 0) 'r' else '-';
    buf[2] = if (mode & 0o200 != 0) 'w' else '-';
    buf[3] = if (mode & 0o100 != 0) 'x' else '-';

    buf[4] = if (mode & 0o040 != 0) 'r' else '-';
    buf[5] = if (mode & 0o020 != 0) 'w' else '-';
    buf[6] = if (mode & 0o010 != 0) 'x' else '-';

    buf[7] = if (mode & 0o004 != 0) 'r' else '-';
    buf[8] = if (mode & 0o002 != 0) 'w' else '-';
    buf[9] = if (mode & 0o001 != 0) 'x' else '-';

    return buf;
}

fn fmtDec(val: anytype, buf: *[10]u8) []const u8 {
    const v: u32 = @intCast(val);
    if (v == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var n = v;
    var i: usize = 0;
    while (n > 0) : (i += 1) {
        buf[i] = @intCast(n % 10 + '0');
        n /= 10;
    }
    var lo: usize = 0;
    var hi = i - 1;
    while (lo < hi) {
        const tmp = buf[lo];
        buf[lo] = buf[hi];
        buf[hi] = tmp;
        lo += 1;
        hi -= 1;
    }
    return buf[0..i];
}

fn fmtHuman(val: anytype, buf: *[10]u8) []const u8 {
    const v: u64 = @intCast(val);
    if (v < 1024) {
        // Show as plain bytes
        return fmtDec(@as(u32, @intCast(v)), buf);
    }
    const suffixes = [_]u8{ 'K', 'M', 'G' };
    var scaled = v;
    var idx: usize = 0;
    while (scaled >= 1024 * 1024 and idx < 2) {
        scaled /= 1024;
        idx += 1;
    }
    // Now divide once more to get into the suffix range
    if (scaled >= 1024) {
        scaled /= 1024;
        idx += 1;
    }
    // Clamp idx
    if (idx > 2) idx = 2;
    // Format number + suffix
    const n: u32 = @intCast(@min(scaled, 999999));
    const num_slice = fmtDec(n, buf);
    const num_len = num_slice.len;
    if (num_len < 9) {
        buf[num_len] = suffixes[idx];
        return buf[0 .. num_len + 1];
    }
    return num_slice;
}

export fn _start() noreturn {
    const args = fx.getArgs();

    var paths: [16][*:0]const u8 = undefined;
    var path_count: usize = 0;

    for (args[1..]) |arg| {
        const s = argSlice(arg);
        if (s.len >= 2 and s[0] == '-' and s[1] != '-') {
            // Parse flag characters
            for (s[1..]) |ch| {
                switch (ch) {
                    'l' => flag_long = true,
                    'a' => flag_all = true,
                    's' => flag_size = true,
                    'h' => flag_human = true,
                    else => {},
                }
            }
        } else {
            if (path_count < paths.len) {
                paths[path_count] = arg;
                path_count += 1;
            }
        }
    }

    if (path_count == 0) {
        listDir("/boot");
    } else {
        for (paths[0..path_count]) |arg| {
            listDir(argSlice(arg));
        }
    }

    fx.exit(0);
}

fn argSlice(arg: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (arg[len] != 0) : (len += 1) {}
    return arg[0..len];
}
