/// grep — search for a pattern in files.
///
/// Usage: grep pattern [file...]
/// No args after pattern: read stdin, print matching lines.
const fx = @import("fornax");

const out = fx.io.Writer.stdout;
const err = fx.io.Writer.stderr;

const LINE_BUF_SIZE = 4096;

/// Read lines from fd, print those containing pattern.
fn grepFd(fd: i32, pattern: []const u8, prefix: []const u8) void {
    var line_buf: [LINE_BUF_SIZE]u8 = undefined;
    var line_len: usize = 0;
    var buf: [4096]u8 = undefined;

    while (true) {
        const n = fx.read(fd, &buf);
        if (n <= 0) break;
        const len: usize = @intCast(n);

        for (buf[0..len]) |c| {
            if (c == '\n') {
                const line = line_buf[0..line_len];
                if (fx.str.indexOfSlice(line, pattern) != null) {
                    if (prefix.len > 0) {
                        out.puts(prefix);
                        out.putc(':');
                    }
                    _ = fx.write(1, line);
                    out.putc('\n');
                }
                line_len = 0;
            } else {
                if (line_len < LINE_BUF_SIZE) {
                    line_buf[line_len] = c;
                    line_len += 1;
                }
            }
        }
    }

    // Handle last line without trailing newline
    if (line_len > 0) {
        const line = line_buf[0..line_len];
        if (fx.str.indexOfSlice(line, pattern) != null) {
            if (prefix.len > 0) {
                out.puts(prefix);
                out.putc(':');
            }
            _ = fx.write(1, line);
            out.putc('\n');
        }
    }
}

fn argStr(arg: [*]const u8) []const u8 {
    var len: usize = 0;
    while (arg[len] != 0) : (len += 1) {}
    return arg[0..len];
}

export fn _start() noreturn {
    const args = fx.getArgs();

    if (args.len < 2) {
        err.puts("usage: grep pattern [file...]\n");
        fx.exit(1);
    }

    const pattern = argStr(args[1]);

    if (args.len <= 2) {
        // Read stdin
        grepFd(0, pattern, "");
    } else {
        const multi = args.len > 3;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const name = argStr(args[i]);
            const fd = fx.open(name);
            if (fd < 0) {
                err.print("grep: {s}: not found\n", .{name});
                continue;
            }
            grepFd(fd, pattern, if (multi) name else "");
            _ = fx.close(fd);
        }
    }

    fx.exit(0);
}
