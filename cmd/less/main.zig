/// less — file pager.
///
/// Usage: less [file]
/// No args: read stdin. Display 24 lines at a time.
/// Keys: Space=next page, Enter=next line, b=back page, q=quit.
const fx = @import("fornax");

const out = fx.io.Writer.stdout;
const err = fx.io.Writer.stderr;

const BUF_SIZE = 64 * 1024;
const MAX_LINES = 4096;
const PAGE_SIZE: usize = 24;

var text_buf: [BUF_SIZE]u8 linksection(".bss") = undefined;
var text_len: usize = 0;

/// Offsets of each line start in text_buf.
var line_starts: [MAX_LINES]u32 linksection(".bss") = undefined;
var total_lines: usize = 0;

/// Read entire input into text_buf and index line starts.
fn loadInput(fd: i32) void {
    text_len = 0;
    total_lines = 0;

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = fx.read(fd, &buf);
        if (n <= 0) break;
        const len: usize = @intCast(n);
        const copy_len = @min(len, BUF_SIZE - text_len);
        @memcpy(text_buf[text_len..][0..copy_len], buf[0..copy_len]);
        text_len += copy_len;
        if (text_len >= BUF_SIZE) break;
    }

    // Index line starts
    if (text_len > 0 and total_lines < MAX_LINES) {
        line_starts[0] = 0;
        total_lines = 1;

        for (text_buf[0..text_len], 0..) |c, i| {
            if (c == '\n' and i + 1 < text_len and total_lines < MAX_LINES) {
                line_starts[total_lines] = @intCast(i + 1);
                total_lines += 1;
            }
        }
    }
}

/// Display lines from start_line for count lines.
fn displayPage(start_line: usize, count: usize) void {
    var line = start_line;
    const end = @min(start_line + count, total_lines);
    while (line < end) : (line += 1) {
        const start: usize = line_starts[line];
        const finish: usize = if (line + 1 < total_lines)
            line_starts[line + 1]
        else
            text_len;
        _ = fx.write(1, text_buf[start..finish]);
        // Ensure newline at end if not present
        if (finish > start and text_buf[finish - 1] != '\n') {
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

    if (args.len > 1) {
        const name = argStr(args[1]);
        const fd = fx.open(name);
        if (fd < 0) {
            err.print("less: {s}: not found\n", .{name});
            fx.exit(1);
        }
        loadInput(fd);
        _ = fx.close(fd);
    } else {
        loadInput(0);
    }

    if (total_lines == 0) {
        fx.exit(0);
    }

    // If content fits on one page, just print and exit
    if (total_lines <= PAGE_SIZE) {
        displayPage(0, PAGE_SIZE);
        fx.exit(0);
    }

    // Enter raw keyboard mode
    _ = fx.write(0, "rawon");
    _ = fx.write(0, "echo off");
    _ = fx.write(1, "\x1b[?25l"); // hide cursor

    var current_line: usize = 0;

    // Display first page
    _ = fx.write(1, "\x1b[2J\x1b[H");
    displayPage(current_line, PAGE_SIZE);
    showStatus(current_line);

    while (true) {
        var key: [4]u8 = undefined;
        const n = fx.read(0, &key);
        if (n <= 0) continue;

        const ch = key[0];

        switch (ch) {
            'q' => {
                _ = fx.write(1, "\x1b[?25h"); // show cursor
                _ = fx.write(0, "rawoff");
                _ = fx.write(0, "echo on");
                fx.exit(0);
            },
            ' ' => {
                // Next page
                if (current_line + PAGE_SIZE < total_lines) {
                    current_line += PAGE_SIZE;
                    _ = fx.write(1, "\x1b[2J\x1b[H");
                    displayPage(current_line, PAGE_SIZE);
                    showStatus(current_line);
                }
            },
            '\n', '\r' => {
                // Next line
                if (current_line + 1 < total_lines) {
                    current_line += 1;
                    _ = fx.write(1, "\x1b[2J\x1b[H");
                    displayPage(current_line, PAGE_SIZE);
                    showStatus(current_line);
                }
            },
            'b' => {
                // Previous page
                if (current_line >= PAGE_SIZE) {
                    current_line -= PAGE_SIZE;
                } else {
                    current_line = 0;
                }
                _ = fx.write(1, "\x1b[2J\x1b[H");
                displayPage(current_line, PAGE_SIZE);
                showStatus(current_line);
            },
            'g' => {
                // Go to top
                current_line = 0;
                _ = fx.write(1, "\x1b[2J\x1b[H");
                displayPage(current_line, PAGE_SIZE);
                showStatus(current_line);
            },
            'G' => {
                // Go to bottom
                if (total_lines > PAGE_SIZE) {
                    current_line = total_lines - PAGE_SIZE;
                } else {
                    current_line = 0;
                }
                _ = fx.write(1, "\x1b[2J\x1b[H");
                displayPage(current_line, PAGE_SIZE);
                showStatus(current_line);
            },
            0x1b => {
                // Escape sequence (arrow keys)
                if (n >= 3 and key[1] == '[') {
                    switch (key[2]) {
                        'B' => {
                            // Down arrow — next line
                            if (current_line + 1 < total_lines) {
                                current_line += 1;
                                _ = fx.write(1, "\x1b[2J\x1b[H");
                                displayPage(current_line, PAGE_SIZE);
                                showStatus(current_line);
                            }
                        },
                        'A' => {
                            // Up arrow — previous line
                            if (current_line > 0) {
                                current_line -= 1;
                                _ = fx.write(1, "\x1b[2J\x1b[H");
                                displayPage(current_line, PAGE_SIZE);
                                showStatus(current_line);
                            }
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
    }
}

fn showStatus(current_line: usize) void {
    // Show reverse-video status line
    _ = fx.write(1, "\x1b[7m");
    out.print(" line {d}/{d} ", .{ current_line + 1, total_lines });
    _ = fx.write(1, "\x1b[0m");
}
