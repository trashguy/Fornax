const fx = @import("fornax");

const err = fx.io.Writer.stderr;

var copy_buf: [4096]u8 = undefined;
var src_path: [512]u8 = undefined;
var dst_path: [512]u8 = undefined;

fn argSlice(arg: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (arg[len] != 0) : (len += 1) {}
    return arg[0..len];
}

fn pathEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (ac != bc) return false;
    }
    return true;
}

export fn _start() noreturn {
    const args = fx.getArgs();

    // Parse args — find source and destination
    // Simple mode: cp src dst (no flags, no recursive)
    var pos_ptrs: [64][*:0]const u8 = undefined;
    var pos_count: usize = 0;
    for (args[1..]) |arg| {
        const a = argSlice(arg);
        if (a.len >= 2 and a[0] == '-') {
            // Skip flags (recursive not implemented)
        } else {
            if (pos_count < pos_ptrs.len) {
                pos_ptrs[pos_count] = arg;
                pos_count += 1;
            }
        }
    }

    if (pos_count < 2) {
        err.puts("usage: cp src dst\n");
        fx.exit(1);
    }

    var had_error = false;

    // Process each source
    var si: usize = 0;
    while (si < pos_count - 1) : (si += 1) {
        const src = argSlice(pos_ptrs[si]);
        const dst = argSlice(pos_ptrs[pos_count - 1]);

        // Strip trailing slashes from source for basename extraction
        var slen = src.len;
        while (slen > 1 and src[slen - 1] == '/') : (slen -= 1) {}

        // Bounds check source path
        if (slen > src_path.len) {
            err.puts("cp: source path too long\n");
            had_error = true;
            continue;
        }
        for (src[0..slen], 0..) |c, i| {
            src_path[i] = c;
        }

        // Bounds check destination path
        if (dst.len > dst_path.len) {
            err.puts("cp: destination path too long\n");
            had_error = true;
            continue;
        }
        var dlen = dst.len;
        for (dst[0..dlen], 0..) |c, i| {
            dst_path[i] = c;
        }

        // Check if dst is a directory
        const dfd = fx.open(dst_path[0..dlen]);
        if (dfd >= 0) {
            var st: fx.Stat = undefined;
            const stat_ret = fx.stat(dfd, &st);
            _ = fx.close(dfd);
            if (stat_ret >= 0 and st.file_type == 1) {
                // Append /basename(src) to dst
                if (dlen > 0 and dst_path[dlen - 1] != '/') {
                    if (dlen >= dst_path.len) {
                        err.puts("cp: destination path too long\n");
                        had_error = true;
                        continue;
                    }
                    dst_path[dlen] = '/';
                    dlen += 1;
                }
                // Find basename
                var bstart: usize = 0;
                var j: usize = slen;
                while (j > 0) {
                    j -= 1;
                    if (src_path[j] == '/') {
                        bstart = j + 1;
                        break;
                    }
                }
                const blen = slen - bstart;
                if (dlen + blen > dst_path.len) {
                    err.puts("cp: destination path too long\n");
                    had_error = true;
                    continue;
                }
                var k: usize = bstart;
                while (k < slen) : (k += 1) {
                    dst_path[dlen] = src_path[k];
                    dlen += 1;
                }
            }
        }

        // Self-copy check
        if (pathEql(src_path[0..slen], dst_path[0..dlen])) {
            err.puts("cp: ");
            err.puts(src_path[0..slen]);
            err.puts(" and ");
            err.puts(dst_path[0..dlen]);
            err.puts(" are the same file\n");
            had_error = true;
            continue;
        }

        // Open source
        const in_fd = fx.open(src_path[0..slen]);
        if (in_fd < 0) {
            err.puts("cp: ");
            err.puts(src_path[0..slen]);
            err.puts(": not found\n");
            had_error = true;
            continue;
        }

        // Create destination
        const out_fd = fx.create(dst_path[0..dlen], 0);
        if (out_fd < 0) {
            err.puts("cp: ");
            err.puts(dst_path[0..dlen]);
            err.puts(": cannot create\n");
            _ = fx.close(in_fd);
            had_error = true;
            continue;
        }

        // Copy data — handle partial writes
        var write_err = false;
        while (true) {
            const n = fx.read(in_fd, &copy_buf);
            if (n <= 0) break;
            const total: usize = @intCast(n);
            var written: usize = 0;
            while (written < total) {
                const w = fx.write(out_fd, copy_buf[written..total]);
                if (w <= 0) {
                    write_err = true;
                    break;
                }
                written += @intCast(w);
            }
            if (write_err) break;
        }

        if (write_err) {
            err.puts("cp: ");
            err.puts(dst_path[0..dlen]);
            err.puts(": write error\n");
            had_error = true;
        }

        _ = fx.close(out_fd);
        _ = fx.close(in_fd);
    }

    fx.exit(if (had_error) @as(u8, 1) else 0);
}
