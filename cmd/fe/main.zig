/// fe — Fornax editor (minimal vi-like).
///
/// Usage: fe [file]
/// Modal editor: normal, insert, command modes.
/// Keybindings: h/j/k/l movement, i/a/o insert, dd/x delete,
///              :w save, :q quit, /search, u undo.
const fx = @import("fornax");

const out = fx.io.Writer.stdout;

// ── Constants ──────────────────────────────────────────────────────

const MAX_LINES = 1024;
const MAX_LINE_LEN = 256;
const MAX_UNDO = 64;
const MAX_CMD = 64;
const MAX_SEARCH = 64;
const MAX_FILENAME = 128;
const FILE_BUF_SIZE = 4096;

// ── Line storage (BSS) ────────────────────────────────────────────

const Line = struct {
    data: [MAX_LINE_LEN]u8,
    len: usize,
};

var lines: [MAX_LINES]Line linksection(".bss") = undefined;
var num_lines: usize = 0;

// ── Editor state ──────────────────────────────────────────────────

const Mode = enum { normal, insert, command, search };
var mode: Mode = .normal;

var cursor_row: usize = 0; // position in file (0-indexed)
var cursor_col: usize = 0;
var view_top: usize = 0; // first visible line

var screen_rows: usize = 24;
var screen_cols: usize = 80;
var text_rows: usize = 23; // screen_rows - 1 (status bar)

var filename: [MAX_FILENAME]u8 = undefined;
var filename_len: usize = 0;
var modified: bool = false;
var is_new_file: bool = false;

var cmd_buf: [MAX_CMD]u8 = undefined;
var cmd_len: usize = 0;

var search_buf: [MAX_SEARCH]u8 = undefined;
var search_len: usize = 0;

var status_msg: [80]u8 = undefined;
var status_msg_len: usize = 0;

// ── Yank buffer ────────────────────────────────────────────────────

var yank_line: Line = undefined;
var has_yank: bool = false;

// ── Undo stack ─────────────────────────────────────────────────────

const UndoOp = enum {
    insert_char,
    delete_char,
    insert_line,
    delete_line,
    split_line,
    join_lines,
    replace_char,
};

const UndoEntry = struct {
    op: UndoOp,
    row: u16,
    col: u16,
    char: u8,
    line: Line,
};

var undo_stack: [MAX_UNDO]UndoEntry linksection(".bss") = undefined;
var undo_count: usize = 0;
var undo_head: usize = 0;

// ── Numeric count prefix ───────────────────────────────────────────

var count_accum: usize = 0;
var has_count: bool = false;

fn getCount() usize {
    const c = if (has_count) count_accum else 1;
    count_accum = 0;
    has_count = false;
    return c;
}

// ── CSI output helpers ─────────────────────────────────────────────

var csi_buf: [32]u8 = undefined;

fn moveTo(row: usize, col: usize) void {
    // ESC[row+1;col+1H
    var len: usize = 0;
    csi_buf[len] = 0x1B;
    len += 1;
    csi_buf[len] = '[';
    len += 1;
    len += decInto(csi_buf[len..], row + 1);
    csi_buf[len] = ';';
    len += 1;
    len += decInto(csi_buf[len..], col + 1);
    csi_buf[len] = 'H';
    len += 1;
    _ = fx.write(1, csi_buf[0..len]);
}

fn clearScreenCsi() void {
    _ = fx.write(1, "\x1b[2J\x1b[H");
}

fn clearLineCsi() void {
    _ = fx.write(1, "\x1b[K");
}

fn setReverse() void {
    _ = fx.write(1, "\x1b[7m");
}

fn resetAttr() void {
    _ = fx.write(1, "\x1b[0m");
}

fn decInto(buf: []u8, val: usize) usize {
    if (val == 0) {
        if (buf.len > 0) buf[0] = '0';
        return 1;
    }
    var tmp: [12]u8 = undefined;
    var n = val;
    var i: usize = 0;
    while (n > 0) : (i += 1) {
        tmp[i] = @intCast(n % 10 + '0');
        n /= 10;
    }
    var j: usize = 0;
    while (j < i and j < buf.len) : (j += 1) {
        buf[j] = tmp[i - 1 - j];
    }
    return i;
}

// ── Key input ──────────────────────────────────────────────────────

const Key = union(enum) {
    char: u8,
    ctrl: u8,
    arrow_up,
    arrow_down,
    arrow_left,
    arrow_right,
    home,
    end_key,
    backspace,
    enter,
    escape,
    delete,
    none,
};

fn readKey() Key {
    var buf: [4]u8 = undefined;
    const n = fx.read(0, &buf);
    if (n <= 0) return .none;

    const c = buf[0];

    if (c == 0x1B) {
        // Check for escape sequence
        if (n >= 3 and buf[1] == '[') {
            return switch (buf[2]) {
                'A' => .arrow_up,
                'B' => .arrow_down,
                'C' => .arrow_right,
                'D' => .arrow_left,
                'H' => .home,
                'F' => .end_key,
                '3' => .delete, // ESC[3~ (ignore ~)
                else => .escape,
            };
        }
        return .escape;
    }

    if (c == 0x08 or c == 0x7F) return .backspace;
    if (c == '\r' or c == '\n') return .enter;
    if (c >= 1 and c <= 26) return .{ .ctrl = c + 'a' - 1 };
    if (c >= 0x20 and c <= 0x7E) return .{ .char = c };
    return .none;
}

// ── File I/O ───────────────────────────────────────────────────────

fn loadFile(path: []const u8) void {
    num_lines = 0;
    cursor_row = 0;
    cursor_col = 0;
    view_top = 0;

    const fd = fx.open(path);
    if (fd < 0) {
        // New file
        is_new_file = true;
        lines[0].len = 0;
        num_lines = 1;
        return;
    }

    is_new_file = false;
    var buf: [FILE_BUF_SIZE]u8 = undefined;

    // Start with one empty line
    lines[0].len = 0;
    num_lines = 1;

    while (true) {
        const n = fx.read(fd, &buf);
        if (n <= 0) break;
        const len: usize = @intCast(n);

        for (buf[0..len]) |ch| {
            if (ch == '\n') {
                if (num_lines < MAX_LINES) {
                    num_lines += 1;
                    lines[num_lines - 1].len = 0;
                }
            } else {
                const li = num_lines - 1;
                if (lines[li].len < MAX_LINE_LEN) {
                    lines[li].data[lines[li].len] = ch;
                    lines[li].len += 1;
                }
            }
        }
    }
    _ = fx.close(fd);

    // Remove trailing empty line if file ended with \n
    if (num_lines > 1 and lines[num_lines - 1].len == 0) {
        num_lines -= 1;
    }
}

fn saveFile(path: []const u8) bool {
    // Remove existing file
    _ = fx.remove(path);

    // Create new file
    const fd = fx.create(path, 0);
    if (fd < 0) return false;

    var buf: [FILE_BUF_SIZE]u8 = undefined;
    var buf_len: usize = 0;

    for (0..num_lines) |i| {
        const line = &lines[i];

        // Flush if line won't fit
        if (buf_len + line.len + 1 > FILE_BUF_SIZE) {
            if (buf_len > 0) {
                _ = fx.write(fd, buf[0..buf_len]);
                buf_len = 0;
            }
        }

        // Copy line data
        if (line.len <= FILE_BUF_SIZE - buf_len) {
            @memcpy(buf[buf_len..][0..line.len], line.data[0..line.len]);
            buf_len += line.len;
        } else {
            // Line too long for buffer — write directly
            if (buf_len > 0) {
                _ = fx.write(fd, buf[0..buf_len]);
                buf_len = 0;
            }
            _ = fx.write(fd, line.data[0..line.len]);
        }

        // Add newline
        if (buf_len < FILE_BUF_SIZE) {
            buf[buf_len] = '\n';
            buf_len += 1;
        } else {
            _ = fx.write(fd, buf[0..buf_len]);
            buf_len = 0;
            buf[0] = '\n';
            buf_len = 1;
        }
    }

    if (buf_len > 0) {
        _ = fx.write(fd, buf[0..buf_len]);
    }

    _ = fx.close(fd);
    return true;
}

// ── Undo ───────────────────────────────────────────────────────────

fn pushUndo(entry: UndoEntry) void {
    undo_stack[undo_head] = entry;
    undo_head = (undo_head + 1) % MAX_UNDO;
    if (undo_count < MAX_UNDO) undo_count += 1;
}

fn popUndo() ?UndoEntry {
    if (undo_count == 0) return null;
    undo_head = (undo_head + MAX_UNDO - 1) % MAX_UNDO;
    undo_count -= 1;
    return undo_stack[undo_head];
}

fn doUndo() void {
    const entry = popUndo() orelse {
        setStatus("nothing to undo");
        return;
    };

    switch (entry.op) {
        .insert_char => {
            // Undo insert: delete the char
            deleteCharAt(entry.row, entry.col);
        },
        .delete_char => {
            // Undo delete: re-insert the char
            insertCharAt(entry.row, entry.col, entry.char);
        },
        .insert_line => {
            // Undo insert line: delete it
            deleteLineAt(entry.row);
        },
        .delete_line => {
            // Undo delete line: re-insert it
            insertLineAt(entry.row, entry.line);
        },
        .split_line => {
            // Undo split: join the two lines
            joinLineAt(entry.row);
        },
        .join_lines => {
            // Undo join: split at the saved column
            splitLineAt(entry.row, entry.col);
        },
        .replace_char => {
            // Undo replace: put the old char back
            if (entry.row < num_lines and entry.col < lines[entry.row].len) {
                lines[entry.row].data[entry.col] = entry.char;
            }
        },
    }

    cursor_row = entry.row;
    cursor_col = entry.col;
    modified = true;
}

// ── Line manipulation primitives (no undo push) ────────────────────

fn insertCharAt(row: usize, col: usize, ch: u8) void {
    if (row >= num_lines) return;
    const line = &lines[row];
    if (line.len >= MAX_LINE_LEN) return;
    // Shift right
    var j: usize = line.len;
    while (j > col) : (j -= 1) {
        line.data[j] = line.data[j - 1];
    }
    line.data[col] = ch;
    line.len += 1;
}

fn deleteCharAt(row: usize, col: usize) void {
    if (row >= num_lines) return;
    const line = &lines[row];
    if (col >= line.len) return;
    // Shift left
    var j: usize = col;
    while (j + 1 < line.len) : (j += 1) {
        line.data[j] = line.data[j + 1];
    }
    line.len -= 1;
}

fn insertLineAt(row: usize, line: Line) void {
    if (num_lines >= MAX_LINES) return;
    // Shift lines down
    var j: usize = num_lines;
    while (j > row) : (j -= 1) {
        lines[j] = lines[j - 1];
    }
    lines[row] = line;
    num_lines += 1;
}

fn deleteLineAt(row: usize) void {
    if (row >= num_lines) return;
    if (num_lines <= 1) {
        lines[0].len = 0;
        return;
    }
    var j: usize = row;
    while (j + 1 < num_lines) : (j += 1) {
        lines[j] = lines[j + 1];
    }
    num_lines -= 1;
}

fn splitLineAt(row: usize, col: usize) void {
    if (row >= num_lines or num_lines >= MAX_LINES) return;
    const line = &lines[row];
    var new_line: Line = undefined;
    new_line.len = 0;
    if (col < line.len) {
        const tail_len = line.len - col;
        @memcpy(new_line.data[0..tail_len], line.data[col..line.len]);
        new_line.len = tail_len;
        line.len = col;
    }
    // Insert new line after row
    var j: usize = num_lines;
    while (j > row + 1) : (j -= 1) {
        lines[j] = lines[j - 1];
    }
    lines[row + 1] = new_line;
    num_lines += 1;
}

fn joinLineAt(row: usize) void {
    if (row + 1 >= num_lines) return;
    const line = &lines[row];
    const next = &lines[row + 1];
    const space = MAX_LINE_LEN - line.len;
    const copy_len = @min(next.len, space);
    @memcpy(line.data[line.len..][0..copy_len], next.data[0..copy_len]);
    line.len += copy_len;
    // Remove next line
    var j: usize = row + 1;
    while (j + 1 < num_lines) : (j += 1) {
        lines[j] = lines[j + 1];
    }
    num_lines -= 1;
}

// ── Screen rendering ───────────────────────────────────────────────

fn render() void {
    // Adjust view_top for scrolling
    if (cursor_row < view_top) view_top = cursor_row;
    if (cursor_row >= view_top + text_rows) view_top = cursor_row - text_rows + 1;

    for (0..text_rows) |screen_row| {
        moveTo(screen_row, 0);
        const file_row = view_top + screen_row;
        if (file_row < num_lines) {
            const line = &lines[file_row];
            const display_len = @min(line.len, screen_cols);
            if (display_len > 0) {
                _ = fx.write(1, line.data[0..display_len]);
            }
        } else {
            _ = fx.write(1, "~");
        }
        clearLineCsi();
    }

    // Status bar
    renderStatusBar();

    // Park cursor
    const screen_col = @min(cursor_col, screen_cols -| 1);
    moveTo(cursor_row - view_top, screen_col);
}

fn renderStatusBar() void {
    moveTo(text_rows, 0);
    setReverse();

    // Mode indicator
    switch (mode) {
        .insert => _ = fx.write(1, " -- INSERT -- "),
        .command => _ = fx.write(1, " :"),
        .search => _ = fx.write(1, " /"),
        .normal => _ = fx.write(1, " "),
    }

    if (mode == .command) {
        if (cmd_len > 0) _ = fx.write(1, cmd_buf[0..cmd_len]);
    } else if (mode == .search) {
        if (search_len > 0) _ = fx.write(1, search_buf[0..search_len]);
    } else {
        // Filename
        if (filename_len > 0) {
            _ = fx.write(1, filename[0..filename_len]);
        } else {
            _ = fx.write(1, "[No Name]");
        }

        if (modified) _ = fx.write(1, " [+]");

        // Status message or position
        if (status_msg_len > 0) {
            _ = fx.write(1, "  ");
            _ = fx.write(1, status_msg[0..status_msg_len]);
            status_msg_len = 0;
        } else {
            _ = fx.write(1, "  ");
            var pos_buf: [32]u8 = undefined;
            var pos_len: usize = 0;
            pos_len += decInto(pos_buf[pos_len..], cursor_row + 1);
            pos_buf[pos_len] = ',';
            pos_len += 1;
            pos_len += decInto(pos_buf[pos_len..], cursor_col + 1);
            pos_buf[pos_len] = '/';
            pos_len += 1;
            pos_len += decInto(pos_buf[pos_len..], num_lines);
            _ = fx.write(1, pos_buf[0..pos_len]);
        }
    }

    clearLineCsi();
    resetAttr();
}

fn setStatus(msg: []const u8) void {
    const len = @min(msg.len, status_msg.len);
    @memcpy(status_msg[0..len], msg[0..len]);
    status_msg_len = len;
}

// ── Cursor helpers ─────────────────────────────────────────────────

fn clampCursor() void {
    if (cursor_row >= num_lines) cursor_row = num_lines -| 1;
    const line_len = lines[cursor_row].len;
    if (mode == .insert) {
        if (cursor_col > line_len) cursor_col = line_len;
    } else {
        if (line_len == 0) {
            cursor_col = 0;
        } else if (cursor_col >= line_len) {
            cursor_col = line_len - 1;
        }
    }
}

fn isWordChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_';
}

fn wordForward() void {
    const line = &lines[cursor_row];
    if (cursor_col >= line.len) {
        if (cursor_row + 1 < num_lines) {
            cursor_row += 1;
            cursor_col = 0;
        }
        return;
    }
    // Skip current word chars
    while (cursor_col < line.len and isWordChar(line.data[cursor_col])) : (cursor_col += 1) {}
    // Skip non-word chars
    while (cursor_col < line.len and !isWordChar(line.data[cursor_col])) : (cursor_col += 1) {}
}

fn wordBack() void {
    if (cursor_col == 0) {
        if (cursor_row > 0) {
            cursor_row -= 1;
            cursor_col = lines[cursor_row].len -| 1;
        }
        return;
    }
    cursor_col -= 1;
    const line = &lines[cursor_row];
    // Skip non-word chars
    while (cursor_col > 0 and !isWordChar(line.data[cursor_col])) : (cursor_col -= 1) {}
    // Skip word chars
    while (cursor_col > 0 and isWordChar(line.data[cursor_col - 1])) : (cursor_col -= 1) {}
}

// ── Normal mode ────────────────────────────────────────────────────

var pending_g: bool = false;

fn handleNormal(key: Key) void {
    switch (key) {
        .char => |c| {
            // Numeric count prefix
            if (c >= '1' and c <= '9' and !pending_g) {
                count_accum = count_accum * 10 + (c - '0');
                has_count = true;
                return;
            }
            if (c == '0' and has_count) {
                count_accum = count_accum * 10;
                return;
            }

            if (pending_g) {
                pending_g = false;
                if (c == 'g') {
                    // gg — go to first line (or count-th line)
                    const target = getCount();
                    cursor_row = if (target > 0) target - 1 else 0;
                    cursor_col = 0;
                    clampCursor();
                }
                return;
            }

            switch (c) {
                'h' => {
                    const n = getCount();
                    cursor_col -|= n;
                },
                'j' => {
                    const n = getCount();
                    cursor_row = @min(cursor_row + n, num_lines -| 1);
                    clampCursor();
                },
                'k' => {
                    const n = getCount();
                    cursor_row -|= n;
                    clampCursor();
                },
                'l' => {
                    const n = getCount();
                    const max_col = lines[cursor_row].len -| 1;
                    cursor_col = @min(cursor_col + n, max_col);
                },
                'w' => {
                    const n = getCount();
                    for (0..n) |_| wordForward();
                    clampCursor();
                },
                'b' => {
                    const n = getCount();
                    for (0..n) |_| wordBack();
                    clampCursor();
                },
                '0' => {
                    cursor_col = 0;
                },
                '$' => {
                    cursor_col = lines[cursor_row].len -| 1;
                },
                'G' => {
                    if (has_count) {
                        const target = getCount();
                        cursor_row = if (target > 0) target - 1 else 0;
                    } else {
                        cursor_row = num_lines -| 1;
                    }
                    cursor_col = 0;
                    clampCursor();
                },
                'g' => {
                    pending_g = true;
                    return;
                },
                'i' => {
                    mode = .insert;
                    _ = getCount();
                },
                'a' => {
                    mode = .insert;
                    if (lines[cursor_row].len > 0) cursor_col += 1;
                    _ = getCount();
                },
                'A' => {
                    mode = .insert;
                    cursor_col = lines[cursor_row].len;
                    _ = getCount();
                },
                'I' => {
                    mode = .insert;
                    // Move to first non-space
                    cursor_col = 0;
                    const line = &lines[cursor_row];
                    while (cursor_col < line.len and (line.data[cursor_col] == ' ' or line.data[cursor_col] == '\t')) : (cursor_col += 1) {}
                    _ = getCount();
                },
                'o' => {
                    const new_line = Line{ .data = undefined, .len = 0 };
                    insertLineAt(cursor_row + 1, new_line);
                    pushUndo(.{ .op = .insert_line, .row = @intCast(cursor_row + 1), .col = 0, .char = 0, .line = undefined });
                    cursor_row += 1;
                    cursor_col = 0;
                    mode = .insert;
                    modified = true;
                    _ = getCount();
                },
                'O' => {
                    const new_line = Line{ .data = undefined, .len = 0 };
                    insertLineAt(cursor_row, new_line);
                    pushUndo(.{ .op = .insert_line, .row = @intCast(cursor_row), .col = 0, .char = 0, .line = undefined });
                    cursor_col = 0;
                    mode = .insert;
                    modified = true;
                    _ = getCount();
                },
                'x' => {
                    const n = getCount();
                    for (0..n) |_| {
                        if (cursor_row < num_lines and cursor_col < lines[cursor_row].len) {
                            const ch = lines[cursor_row].data[cursor_col];
                            pushUndo(.{ .op = .delete_char, .row = @intCast(cursor_row), .col = @intCast(cursor_col), .char = ch, .line = undefined });
                            deleteCharAt(cursor_row, cursor_col);
                            modified = true;
                        }
                    }
                    clampCursor();
                },
                'd' => {
                    // Wait for second 'd'
                    const key2 = readKey();
                    switch (key2) {
                        .char => |c2| {
                            if (c2 == 'd') {
                                const n = getCount();
                                for (0..n) |_| {
                                    if (cursor_row < num_lines) {
                                        yank_line = lines[cursor_row];
                                        has_yank = true;
                                        pushUndo(.{ .op = .delete_line, .row = @intCast(cursor_row), .col = 0, .char = 0, .line = lines[cursor_row] });
                                        deleteLineAt(cursor_row);
                                        modified = true;
                                    }
                                }
                                if (num_lines == 0) {
                                    lines[0].len = 0;
                                    num_lines = 1;
                                }
                                clampCursor();
                            }
                        },
                        else => {},
                    }
                },
                'p' => {
                    if (has_yank) {
                        const n = getCount();
                        for (0..n) |_| {
                            insertLineAt(cursor_row + 1, yank_line);
                            pushUndo(.{ .op = .insert_line, .row = @intCast(cursor_row + 1), .col = 0, .char = 0, .line = undefined });
                            cursor_row += 1;
                            modified = true;
                        }
                        cursor_col = 0;
                    }
                },
                'r' => {
                    _ = getCount();
                    const key2 = readKey();
                    switch (key2) {
                        .char => |c2| {
                            if (cursor_row < num_lines and cursor_col < lines[cursor_row].len) {
                                const old = lines[cursor_row].data[cursor_col];
                                pushUndo(.{ .op = .replace_char, .row = @intCast(cursor_row), .col = @intCast(cursor_col), .char = old, .line = undefined });
                                lines[cursor_row].data[cursor_col] = c2;
                                modified = true;
                            }
                        },
                        else => {},
                    }
                },
                '/' => {
                    mode = .search;
                    search_len = 0;
                    _ = getCount();
                },
                'n' => searchNext(),
                'N' => searchPrev(),
                ':' => {
                    mode = .command;
                    cmd_len = 0;
                    _ = getCount();
                },
                'u' => doUndo(),
                else => _ = getCount(),
            }
        },
        .arrow_up => {
            cursor_row -|= 1;
            clampCursor();
        },
        .arrow_down => {
            cursor_row = @min(cursor_row + 1, num_lines -| 1);
            clampCursor();
        },
        .arrow_left => {
            cursor_col -|= 1;
        },
        .arrow_right => {
            const max_col = lines[cursor_row].len -| 1;
            cursor_col = @min(cursor_col + 1, max_col);
        },
        .home => cursor_col = 0,
        .end_key => cursor_col = lines[cursor_row].len -| 1,
        else => {},
    }
}

// ── Insert mode ────────────────────────────────────────────────────

fn handleInsert(key: Key) void {
    switch (key) {
        .escape => {
            mode = .normal;
            if (cursor_col > 0) cursor_col -= 1;
            clampCursor();
        },
        .char => |c| {
            insertCharAt(cursor_row, cursor_col, c);
            pushUndo(.{ .op = .insert_char, .row = @intCast(cursor_row), .col = @intCast(cursor_col), .char = c, .line = undefined });
            cursor_col += 1;
            modified = true;
        },
        .enter => {
            pushUndo(.{ .op = .split_line, .row = @intCast(cursor_row), .col = @intCast(cursor_col), .char = 0, .line = undefined });
            splitLineAt(cursor_row, cursor_col);
            cursor_row += 1;
            cursor_col = 0;
            modified = true;
        },
        .backspace => {
            if (cursor_col > 0) {
                cursor_col -= 1;
                const ch = lines[cursor_row].data[cursor_col];
                pushUndo(.{ .op = .delete_char, .row = @intCast(cursor_row), .col = @intCast(cursor_col), .char = ch, .line = undefined });
                deleteCharAt(cursor_row, cursor_col);
                modified = true;
            } else if (cursor_row > 0) {
                // Join with previous line
                const prev_len = lines[cursor_row - 1].len;
                pushUndo(.{ .op = .join_lines, .row = @intCast(cursor_row - 1), .col = @intCast(prev_len), .char = 0, .line = undefined });
                cursor_row -= 1;
                cursor_col = prev_len;
                joinLineAt(cursor_row);
                modified = true;
            }
        },
        .arrow_up => {
            cursor_row -|= 1;
            clampCursor();
        },
        .arrow_down => {
            cursor_row = @min(cursor_row + 1, num_lines -| 1);
            clampCursor();
        },
        .arrow_left => {
            if (cursor_col > 0) cursor_col -= 1;
        },
        .arrow_right => {
            cursor_col = @min(cursor_col + 1, lines[cursor_row].len);
        },
        else => {},
    }
}

// ── Command mode ───────────────────────────────────────────────────

fn handleCommand(key: Key) void {
    switch (key) {
        .escape => {
            mode = .normal;
        },
        .enter => {
            executeCommand();
            mode = .normal;
        },
        .backspace => {
            if (cmd_len > 0) {
                cmd_len -= 1;
            } else {
                mode = .normal;
            }
        },
        .char => |c| {
            if (cmd_len < MAX_CMD) {
                cmd_buf[cmd_len] = c;
                cmd_len += 1;
            }
        },
        else => {},
    }
}

fn executeCommand() void {
    if (cmd_len == 0) return;
    const cmd = cmd_buf[0..cmd_len];

    if (fx.str.eql(cmd, "w")) {
        _ = doSave();
    } else if (fx.str.eql(cmd, "q")) {
        if (modified) {
            setStatus("unsaved changes (use :q! to force)");
        } else {
            doQuit();
        }
    } else if (fx.str.eql(cmd, "wq") or fx.str.eql(cmd, "x")) {
        if (doSave()) {
            doQuit();
        }
    } else if (fx.str.eql(cmd, "q!")) {
        doQuit();
    } else if (cmd.len > 2 and fx.str.eql(cmd[0..2], "w ")) {
        // :w filename
        const new_name = cmd[2..];
        const nlen = @min(new_name.len, MAX_FILENAME);
        @memcpy(filename[0..nlen], new_name[0..nlen]);
        filename_len = nlen;
        _ = doSave();
    } else {
        // Try to parse as line number
        if (fx.str.parseUint(cmd)) |line_num| {
            if (line_num > 0 and line_num <= num_lines) {
                cursor_row = @intCast(line_num - 1);
                cursor_col = 0;
                clampCursor();
            }
        } else {
            setStatus("unknown command");
        }
    }
}

fn doSave() bool {
    if (filename_len == 0) {
        setStatus("no filename");
        return false;
    }
    if (saveFile(filename[0..filename_len])) {
        modified = false;
        is_new_file = false;
        setStatus("written");
        return true;
    } else {
        setStatus("write failed");
        return false;
    }
}

fn doQuit() void {
    clearScreenCsi();
    _ = fx.write(0, "rawoff");
    _ = fx.write(0, "echo on");
    fx.exit(0);
}

// ── Search ─────────────────────────────────────────────────────────

fn handleSearch(key: Key) void {
    switch (key) {
        .escape => {
            mode = .normal;
        },
        .enter => {
            mode = .normal;
            searchNext();
        },
        .backspace => {
            if (search_len > 0) {
                search_len -= 1;
            } else {
                mode = .normal;
            }
        },
        .char => |c| {
            if (search_len < MAX_SEARCH) {
                search_buf[search_len] = c;
                search_len += 1;
            }
        },
        else => {},
    }
}

fn searchNext() void {
    if (search_len == 0) return;
    const pattern = search_buf[0..search_len];

    // Search from current position forward
    var row = cursor_row;
    var col = cursor_col + 1;

    var checked: usize = 0;
    while (checked < num_lines) {
        if (row >= num_lines) {
            row = 0;
            col = 0;
        }
        const line = &lines[row];
        if (col < line.len) {
            const haystack = line.data[col..line.len];
            if (fx.str.indexOfSlice(haystack, pattern)) |pos| {
                cursor_row = row;
                cursor_col = col + pos;
                clampCursor();
                return;
            }
        }
        row += 1;
        col = 0;
        checked += 1;
    }
    setStatus("not found");
}

fn searchPrev() void {
    if (search_len == 0) return;
    const pattern = search_buf[0..search_len];

    // Search from current position backward
    var row = cursor_row;
    var col: usize = if (cursor_col > 0) cursor_col - 1 else 0;

    var checked: usize = 0;
    while (checked < num_lines) {
        const line = &lines[row];
        // Search backward in this line
        if (line.len >= pattern.len) {
            var search_end = @min(col + 1, line.len - pattern.len + 1);
            while (search_end > 0) {
                search_end -= 1;
                if (fx.str.eql(line.data[search_end..][0..pattern.len], pattern)) {
                    cursor_row = row;
                    cursor_col = search_end;
                    clampCursor();
                    return;
                }
            }
        }
        if (row == 0) {
            row = num_lines - 1;
        } else {
            row -= 1;
        }
        col = lines[row].len;
        checked += 1;
    }
    setStatus("not found");
}

// ── Terminal setup/teardown ────────────────────────────────────────

fn termInit() void {
    _ = fx.write(0, "rawon");
    _ = fx.write(0, "echo off");

    // Query terminal size
    _ = fx.write(0, "size");
    var size_buf: [32]u8 = undefined;
    const n = fx.read(0, &size_buf);
    if (n > 0) {
        const size_str = size_buf[0..@intCast(n)];
        // Parse "cols rows\n"
        if (fx.str.indexOf(size_str, ' ')) |sp| {
            if (fx.str.parseUint(size_str[0..sp])) |c| {
                screen_cols = @intCast(c);
            }
            // Find end of rows (before \n)
            var end = sp + 1;
            while (end < size_str.len and size_str[end] >= '0' and size_str[end] <= '9') : (end += 1) {}
            if (fx.str.parseUint(size_str[sp + 1 .. end])) |r| {
                screen_rows = @intCast(r);
            }
        }
    }
    text_rows = screen_rows -| 1;

    clearScreenCsi();
}

fn argStr(arg: [*]const u8) []const u8 {
    var len: usize = 0;
    while (arg[len] != 0) : (len += 1) {}
    return arg[0..len];
}

// ── Entry point ────────────────────────────────────────────────────

export fn _start() noreturn {
    const args = fx.getArgs();

    // Initialize
    num_lines = 1;
    lines[0].len = 0;
    undo_count = 0;
    undo_head = 0;
    modified = false;
    is_new_file = true;
    filename_len = 0;
    status_msg_len = 0;
    has_yank = false;
    pending_g = false;
    has_count = false;
    count_accum = 0;

    // Load file if given
    if (args.len > 1) {
        const path = argStr(args[1]);
        const nlen = @min(path.len, MAX_FILENAME);
        @memcpy(filename[0..nlen], path[0..nlen]);
        filename_len = nlen;
        loadFile(path);
    }

    termInit();
    render();

    // Main loop
    while (true) {
        const key = readKey();
        if (key == .none) continue;

        switch (mode) {
            .normal => handleNormal(key),
            .insert => handleInsert(key),
            .command => handleCommand(key),
            .search => handleSearch(key),
        }

        clampCursor();
        render();
    }
}
