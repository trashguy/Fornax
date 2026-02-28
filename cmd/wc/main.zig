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

/// Result of last countFd call — avoids returning struct across function boundary
/// (riscv64 codegen corrupts multi-register return values).
var last_counts: Counts = .{ .lines = 0, .words = 0, .chars = 0 };

fn countFd(fd: i32) void {
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

    last_counts = .{ .lines = lines, .words = words, .chars = chars };
}

/// Name for printCounts — avoids passing optional slice across function boundary
/// (riscv64 codegen corrupts slice pointer in function args).
var print_name: ?[]const u8 = null;

/// Output buffer for printCounts — built with direct byte manipulation to avoid
/// formatDec slice return and putDec function call codegen bugs on riscv64.
var out_buf: [256]u8 = undefined;

/// Current write position in out_buf — module-level to avoid return value codegen bug on riscv64.
var out_pos: usize = 0;

/// Write a u64 as decimal digits into out_buf at out_pos.
/// Inline to avoid riscv64 function call boundary codegen bugs.
inline fn writeDec(val: u64) void {
    if (val == 0) {
        out_buf[out_pos] = '0';
        out_pos += 1;
        return;
    }
    // Format into temp buffer in reverse
    var tmp: [20]u8 = undefined;
    var v = val;
    var i: usize = 20;
    while (v > 0 and i > 0) {
        i -= 1;
        tmp[i] = '0' + @as(u8, @truncate(v % 10));
        v /= 10;
    }
    // Copy digits to out_buf
    while (i < 20) {
        out_buf[out_pos] = tmp[i];
        out_pos += 1;
        i += 1;
    }
}

/// Inline to avoid riscv64 function call boundary codegen bugs.
inline fn printCounts(show_lines: bool, show_words: bool, show_chars: bool) void {
    out_pos = 0;
    var first = true;
    if (show_lines) {
        writeDec(last_counts.lines);
        first = false;
    }
    if (show_words) {
        if (!first) {
            out_buf[out_pos] = ' ';
            out_pos += 1;
        }
        writeDec(last_counts.words);
        first = false;
    }
    if (show_chars) {
        if (!first) {
            out_buf[out_pos] = ' ';
            out_pos += 1;
        }
        writeDec(last_counts.chars);
    }
    if (print_name) |n| {
        out_buf[out_pos] = ' ';
        out_pos += 1;
        for (n) |c| {
            out_buf[out_pos] = c;
            out_pos += 1;
        }
    }
    out_buf[out_pos] = '\n';
    out_pos += 1;
    _ = fx.write(1, out_buf[0..out_pos]);
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
        countFd(0);
        print_name = null;
        printCounts(show_lines, show_words, show_chars);
    } else {
        for (args[file_start..]) |arg| {
            var len: usize = 0;
            while (arg[len] != 0) : (len += 1) {}
            const name = arg[0..len];

            const fd = fx.open(name);
            if (fd < 0) {
                err.puts("wc: ");
                err.puts(name);
                err.puts(": not found\n");
                continue;
            }
            countFd(fd);
            _ = fx.close(fd);
            print_name = name;
            printCounts(show_lines, show_words, show_chars);
        }
    }

    fx.exit(0);
}
