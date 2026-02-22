const fx = @import("fornax");

const out = fx.io.Writer.stdout;
const err = fx.io.Writer.stderr;

// 4 KB matches IPC MAX_MSG_DATA — the fxfs read path can't return more
// per syscall, so a larger buffer just means more syscalls with the same
// throughput.  A kernel copy_file_range or fxfs reflink clone would be
// the real optimization here (future work).
var copy_buf: [4096]u8 linksection(".bss") = undefined;

export fn _start() noreturn {
    const args = fx.getArgs();

    var recursive = false;
    var positional: [64][]const u8 = undefined;
    var pos_count: usize = 0;

    for (args[1..]) |arg| {
        const s = argSlice(arg);
        if (s.len >= 2 and s[0] == '-' and s[1] != '-') {
            for (s[1..]) |ch| {
                switch (ch) {
                    'r', 'R' => recursive = true,
                    else => {},
                }
            }
        } else {
            if (pos_count < positional.len) {
                positional[pos_count] = s;
                pos_count += 1;
            }
        }
    }

    if (pos_count < 2) {
        err.puts("usage: cp [-r] src... dst\n");
        fx.exit(1);
    }

    const dst = positional[pos_count - 1];
    const sources = positional[0 .. pos_count - 1];

    // Check if destination is an existing directory
    const dst_is_dir = isDir(dst);

    if (sources.len > 1 and !dst_is_dir) {
        err.puts("cp: target is not a directory\n");
        fx.exit(1);
    }

    for (sources) |src| {
        if (dst_is_dir) {
            // cp src dir/ → dir/basename(src)
            var target: [512]u8 = undefined;
            const tlen = buildPath(&target, dst, basename(src));
            copyEntry(src, target[0..tlen], recursive);
        } else {
            copyEntry(src, dst, recursive);
        }
    }

    fx.exit(0);
}

fn copyEntry(src: []const u8, dst: []const u8, recursive: bool) void {
    // Stat source to determine type
    const src_fd = fx.open(src);
    if (src_fd < 0) {
        err.print("cp: {s}: not found\n", .{src});
        return;
    }
    var st: fx.Stat = undefined;
    _ = fx.stat(src_fd, &st);
    _ = fx.close(src_fd);

    if (st.file_type == 1) {
        // Directory
        if (!recursive) {
            err.print("cp: {s}: is a directory (use -r)\n", .{src});
            return;
        }
        copyTree(src, dst);
    } else {
        copyFile(src, dst);
    }
}

fn copyFile(src: []const u8, dst: []const u8) void {
    const in_fd = fx.open(src);
    if (in_fd < 0) {
        err.print("cp: {s}: not found\n", .{src});
        return;
    }

    const out_fd = fx.create(dst, 0);
    if (out_fd < 0) {
        err.print("cp: {s}: cannot create\n", .{dst});
        _ = fx.close(in_fd);
        return;
    }

    // Preserve permissions from source
    var st: fx.Stat = undefined;
    _ = fx.stat(in_fd, &st);

    // Copy data
    while (true) {
        const n = fx.read(in_fd, &copy_buf);
        if (n <= 0) break;
        var written: usize = 0;
        const total: usize = @intCast(n);
        while (written < total) {
            const w = fx.write(out_fd, copy_buf[written..total]);
            if (w <= 0) break;
            written += @intCast(w);
        }
    }

    _ = fx.wstat(out_fd, @intCast(st.mode & 0o7777), st.uid, st.gid, fx.WSTAT_MODE | fx.WSTAT_UID | fx.WSTAT_GID);
    _ = fx.close(out_fd);
    _ = fx.close(in_fd);
}

fn copyTree(src: []const u8, dst: []const u8) void {
    _ = fx.mkdir(dst);

    const fd = fx.open(src);
    if (fd < 0) {
        err.print("cp: {s}: cannot open\n", .{src});
        return;
    }

    var dir_buf: [4096]u8 = undefined;
    const n = fx.read(fd, &dir_buf);
    _ = fx.close(fd);
    if (n <= 0) return;

    const bytes: usize = @intCast(n);
    const entry_size: usize = @sizeOf(fx.DirEntry);
    var off: usize = 0;

    while (off + entry_size <= bytes) : (off += entry_size) {
        const entry: *const fx.DirEntry = @ptrCast(@alignCast(dir_buf[off..][0..entry_size]));
        const name = extractName(&entry.name);
        if (name.len == 0) continue;
        if (name.len == 1 and name[0] == '.') continue;
        if (name.len == 2 and name[0] == '.' and name[1] == '.') continue;

        var child_src: [512]u8 = undefined;
        const cs_len = buildPath(&child_src, src, name);
        var child_dst: [512]u8 = undefined;
        const cd_len = buildPath(&child_dst, dst, name);

        if (entry.file_type == 1) {
            copyTree(child_src[0..cs_len], child_dst[0..cd_len]);
        } else {
            copyFile(child_src[0..cs_len], child_dst[0..cd_len]);
        }
    }
}

// ── Helpers ──────────────────────────────────────────────────────────

fn isDir(path: []const u8) bool {
    const fd = fx.open(path);
    if (fd < 0) return false;
    var st: fx.Stat = undefined;
    _ = fx.stat(fd, &st);
    _ = fx.close(fd);
    return st.file_type == 1;
}

fn basename(path: []const u8) []const u8 {
    var i: usize = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/') return path[i + 1 ..];
    }
    return path;
}

fn extractName(name_buf: *const [64]u8) []const u8 {
    for (name_buf, 0..) |c, i| {
        if (c == 0) return name_buf[0..i];
    }
    return name_buf;
}

fn buildPath(buf: *[512]u8, dir: []const u8, name: []const u8) usize {
    var pos: usize = 0;

    if (pos + dir.len < buf.len) {
        @memcpy(buf[pos..][0..dir.len], dir);
        pos += dir.len;
    }

    // Add separator if needed
    if (pos > 0 and buf[pos - 1] != '/' and name.len > 0 and name[0] != '/') {
        if (pos < buf.len) {
            buf[pos] = '/';
            pos += 1;
        }
    }

    if (pos + name.len < buf.len) {
        @memcpy(buf[pos..][0..name.len], name);
        pos += name.len;
    }

    return pos;
}

fn argSlice(arg: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (arg[len] != 0) : (len += 1) {}
    return arg[0..len];
}
