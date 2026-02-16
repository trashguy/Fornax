/// head — output the first part of files.
///
/// Usage: head [-n count] [file...]
/// No args: read stdin, print first 10 lines.
const fx = @import("fornax");

const out = fx.io.Writer.stdout;
const err = fx.io.Writer.stderr;

fn headFd(fd: i32, max_lines: u64) void {
    var lines: u64 = 0;
    var buf: [4096]u8 = undefined;

    while (lines < max_lines) {
        const n = fx.read(fd, &buf);
        if (n <= 0) break;
        const len: usize = @intCast(n);

        // Scan for newlines, print up to max_lines
        for (buf[0..len], 0..) |c, i| {
            if (c == '\n') {
                lines += 1;
                if (lines >= max_lines) {
                    _ = fx.write(1, buf[0 .. i + 1]);
                    return;
                }
            }
        }
        _ = fx.write(1, buf[0..len]);
    }
}

fn argStr(arg: [*]const u8) []const u8 {
    var len: usize = 0;
    while (arg[len] != 0) : (len += 1) {}
    return arg[0..len];
}

export fn _start() noreturn {
    const args = fx.getArgs();

    var count: u64 = 10;
    var file_start: usize = 1;

    // Parse -n option
    if (args.len > 2) {
        const a1 = argStr(args[1]);
        if (fx.str.eql(a1, "-n")) {
            if (args.len > 2) {
                const a2 = argStr(args[2]);
                count = fx.str.parseUint(a2) orelse 10;
                file_start = 3;
            }
        }
    }

    if (args.len <= file_start) {
        // Read stdin
        headFd(0, count);
    } else {
        var i = file_start;
        while (i < args.len) : (i += 1) {
            const name = argStr(args[i]);
            const fd = fx.open(name);
            if (fd < 0) {
                err.print("head: {s}: not found\n", .{name});
                continue;
            }
            headFd(fd, count);
            _ = fx.close(fd);
        }
    }

    fx.exit(0);
}
