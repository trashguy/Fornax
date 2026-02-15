/// wc — word, line, and character count.
///
/// No args: read stdin and count.
/// With args: count each file, print per-file counts.
const fx = @import("fornax");

const out = fx.io.Writer.stdout;
const err = fx.io.Writer.stderr;

fn countFd(fd: i32) struct { lines: u64, words: u64, chars: u64 } {
    var lines: u64 = 0;
    var words: u64 = 0;
    var chars: u64 = 0;
    var in_word = false;

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = fx.read(fd, &buf);
        if (n <= 0) break;
        const len: usize = @intCast(n);
        for (buf[0..len]) |c| {
            chars += 1;
            if (c == '\n') lines += 1;
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                in_word = false;
            } else {
                if (!in_word) words += 1;
                in_word = true;
            }
        }
    }

    return .{ .lines = lines, .words = words, .chars = chars };
}

export fn _start() noreturn {
    const args = fx.getArgs();

    if (args.len <= 1) {
        // Read stdin
        const c = countFd(0);
        out.print("{d} {d} {d}\n", .{ c.lines, c.words, c.chars });
    } else {
        for (args[1..]) |arg| {
            var len: usize = 0;
            while (arg[len] != 0) : (len += 1) {}
            const name = arg[0..len];

            const fd = fx.open(name);
            if (fd < 0) {
                err.print("wc: {s}: not found\n", .{name});
                continue;
            }
            const c = countFd(fd);
            _ = fx.close(fd);
            out.print("{d} {d} {d} {s}\n", .{ c.lines, c.words, c.chars, name });
        }
    }

    fx.exit(0);
}
