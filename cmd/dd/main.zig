const fx = @import("fornax");

const out = fx.io.Writer.stdout;
const err = fx.io.Writer.stderr;

var buf: [4096]u8 linksection(".bss") = undefined;

export fn _start() noreturn {
    const args = fx.getArgs();

    var if_path: ?[]const u8 = null;
    var of_path: ?[]const u8 = null;
    var bs: u64 = 4096;
    var count: u64 = 0;
    var count_set = false;
    var skip_blocks: u64 = 0;
    var seek_blocks: u64 = 0;

    // Parse key=value arguments
    for (args[1..]) |arg| {
        const s = argSlice(arg);
        if (startsWith(s, "if=")) {
            if_path = s[3..];
        } else if (startsWith(s, "of=")) {
            of_path = s[3..];
        } else if (startsWith(s, "bs=")) {
            bs = @min(parseNum(s[3..]), 4096);
            if (bs == 0) bs = 4096;
        } else if (startsWith(s, "count=")) {
            count = parseNum(s[6..]);
            count_set = true;
        } else if (startsWith(s, "skip=")) {
            skip_blocks = parseNum(s[5..]);
        } else if (startsWith(s, "seek=")) {
            seek_blocks = parseNum(s[5..]);
        } else {
            err.print("dd: unknown arg: {s}\n", .{s});
            fx.exit(1);
        }
    }

    // Open input
    var in_fd: i32 = 0; // stdin
    if (if_path) |path| {
        in_fd = fx.open(path);
        if (in_fd < 0) {
            err.print("dd: cannot open {s}\n", .{path});
            fx.exit(1);
        }
    }

    // Open output (create if needed)
    var out_fd: i32 = 1; // stdout
    if (of_path) |path| {
        out_fd = fx.open(path);
        if (out_fd < 0) {
            out_fd = fx.create(path, 0);
            if (out_fd < 0) {
                err.print("dd: cannot create {s}\n", .{path});
                fx.exit(1);
            }
        }
    }

    // Skip input blocks
    if (skip_blocks > 0 and in_fd > 0) {
        _ = fx.seek(in_fd, skip_blocks * bs, 0);
    }

    // Seek output blocks
    if (seek_blocks > 0 and out_fd > 1) {
        _ = fx.seek(out_fd, seek_blocks * bs, 0);
    }

    // Copy loop
    var blocks_in: u64 = 0;
    var blocks_out: u64 = 0;
    var total_bytes: u64 = 0;

    while (true) {
        if (count_set and blocks_in >= count) break;

        const n = fx.read(in_fd, buf[0..bs]);
        if (n <= 0) break; // EOF or error

        blocks_in += 1;
        const nbytes: usize = @intCast(n);

        // Handle short writes by looping
        var written_total: usize = 0;
        while (written_total < nbytes) {
            const w = fx.syscall.write(out_fd, buf[written_total..nbytes]);
            if (w == 0 or w > nbytes - written_total) break; // error or EOF
            written_total += w;
        }
        if (written_total == 0) break;

        blocks_out += 1;
        total_bytes += written_total;
    }

    // Close fds
    if (in_fd > 0) _ = fx.close(in_fd);
    if (out_fd > 1) _ = fx.close(out_fd);

    // Print stats to stderr
    err.print("{d}+0 records in\n", .{blocks_in});
    err.print("{d}+0 records out\n", .{blocks_out});
    err.print("{d} bytes copied\n", .{total_bytes});

    fx.exit(0);
}

fn argSlice(arg: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (arg[len] != 0) : (len += 1) {}
    return arg[0..len];
}

fn startsWith(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    for (prefix, 0..) |c, i| {
        if (s[i] != c) return false;
    }
    return true;
}

fn parseNum(s: []const u8) u64 {
    var n: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') break;
        n = n * 10 + (c - '0');
    }
    return n;
}
