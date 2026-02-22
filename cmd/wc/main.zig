/// wc — word, line, and character count.
///
/// Usage: wc [-lwc] [file ...]
///   -l  lines only
///   -w  words only
///   -c  bytes only
/// No flags: show all three. No files: read stdin.
const fx = @import("fornax");

const out = fx.io.Writer.stdout;
const err = fx.io.Writer.stderr;

const Counts = struct { lines: u64, words: u64, chars: u64 };

fn countFd(fd: i32) Counts {
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

fn printCounts(c: Counts, show_lines: bool, show_words: bool, show_chars: bool, name: ?[]const u8) void {
    var first = true;
    if (show_lines) {
        out.print("{d}", .{c.lines});
        first = false;
    }
    if (show_words) {
        if (!first) out.puts(" ");
        out.print("{d}", .{c.words});
        first = false;
    }
    if (show_chars) {
        if (!first) out.puts(" ");
        out.print("{d}", .{c.chars});
    }
    if (name) |n| {
        out.print(" {s}", .{n});
    }
    out.puts("\n");
}

export fn _start() noreturn {
    const args = fx.getArgs();

    // Parse flags
    var show_lines = false;
    var show_words = false;
    var show_chars = false;
    var file_start: usize = 1;

    for (args[1..], 1..) |arg, idx| {
        var len: usize = 0;
        while (arg[len] != 0) : (len += 1) {}
        const s = arg[0..len];
        if (s.len > 0 and s[0] == '-' and s.len > 1) {
            for (s[1..]) |ch| {
                switch (ch) {
                    'l' => show_lines = true,
                    'w' => show_words = true,
                    'c' => show_chars = true,
                    else => {
                        err.print("wc: unknown flag: -{c}\n", .{ch});
                        fx.exit(1);
                    },
                }
            }
            file_start = idx + 1;
        } else break; // first non-flag arg
    }

    // Default: show all three
    if (!show_lines and !show_words and !show_chars) {
        show_lines = true;
        show_words = true;
        show_chars = true;
    }

    if (file_start >= args.len) {
        // No file args — read stdin
        const c = countFd(0);
        printCounts(c, show_lines, show_words, show_chars, null);
    } else {
        for (args[file_start..]) |arg| {
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
            printCounts(c, show_lines, show_words, show_chars, name);
        }
    }

    fx.exit(0);
}
