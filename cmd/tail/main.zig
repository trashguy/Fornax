/// tail — output the last part of files.
///
/// Usage: tail [-n count] [-f] [file...]
/// No args: read stdin, print last 10 lines.
/// -f: follow — keep reading and printing new data.
const fx = @import("fornax");

const out = fx.io.Writer.stdout;
const err = fx.io.Writer.stderr;

const MAX_LINES = 256;
const LINE_BUF_SIZE = 32 * 1024;

/// Ring buffer of line start/end offsets into a flat text buffer.
var text_buf: [LINE_BUF_SIZE]u8 linksection(".bss") = undefined;
var text_len: usize = 0;

const Line = struct {
    start: u32,
    end: u32,
};

var lines: [MAX_LINES]Line linksection(".bss") = undefined;
var line_count: usize = 0;
var line_head: usize = 0; // ring buffer head (oldest)

fn addLine(start: u32, end: u32) void {
    if (line_count < MAX_LINES) {
        lines[line_count] = .{ .start = start, .end = end };
        line_count += 1;
    } else {
        // Overwrite oldest
        lines[line_head] = .{ .start = start, .end = end };
        line_head = (line_head + 1) % MAX_LINES;
    }
}

fn tailFd(fd: i32, max_lines: u64) void {
    // Read entire input, tracking last max_lines line positions
    line_count = 0;
    line_head = 0;
    text_len = 0;

    var line_start: u32 = 0;
    var buf: [4096]u8 = undefined;

    while (true) {
        const n = fx.read(fd, &buf);
        if (n <= 0) break;
        const len: usize = @intCast(n);

        for (buf[0..len]) |c| {
            if (text_len < LINE_BUF_SIZE) {
                text_buf[text_len] = c;
            }
            text_len += 1;

            if (c == '\n') {
                const end: u32 = @intCast(@min(text_len, LINE_BUF_SIZE));
                addLine(line_start, end);
                line_start = end;
            }
        }
    }

    // Handle last line without trailing newline
    if (text_len > 0 and text_len < LINE_BUF_SIZE) {
        const end: u32 = @intCast(text_len);
        if (end > line_start) {
            addLine(line_start, end);
        }
    }

    // Print last max_lines lines
    const to_print = @min(max_lines, line_count);
    const total = @min(line_count, MAX_LINES);
    var start_idx: usize = 0;

    if (total <= to_print) {
        start_idx = line_head;
    } else {
        // Skip (total - to_print) entries from head
        start_idx = (line_head + total - to_print) % MAX_LINES;
    }

    var printed: usize = 0;
    while (printed < to_print) : (printed += 1) {
        const idx = (start_idx + printed) % MAX_LINES;
        const line = lines[idx];
        if (line.start < LINE_BUF_SIZE and line.end <= LINE_BUF_SIZE) {
            _ = fx.write(1, text_buf[line.start..line.end]);
        }
    }
}

fn followFd(fd: i32) void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = fx.read(fd, &buf);
        if (n <= 0) {
            fx.sleep(500);
            continue;
        }
        _ = fx.write(1, buf[0..@intCast(n)]);
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
    var follow = false;
    var file_start: usize = 1;

    // Parse options
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = argStr(args[i]);
        if (fx.str.eql(a, "-n")) {
            i += 1;
            if (i < args.len) {
                count = fx.str.parseUint(argStr(args[i])) orelse 10;
            }
            file_start = i + 1;
        } else if (fx.str.eql(a, "-f")) {
            follow = true;
            file_start = i + 1;
        } else {
            break;
        }
    }

    if (args.len <= file_start) {
        // Read stdin
        tailFd(0, count);
    } else {
        const name = argStr(args[file_start]);
        const fd = fx.open(name);
        if (fd < 0) {
            err.print("tail: {s}: not found\n", .{name});
            fx.exit(1);
        }
        tailFd(fd, count);

        if (follow) {
            followFd(fd);
            // Never returns
        }

        _ = fx.close(fd);
    }

    fx.exit(0);
}
