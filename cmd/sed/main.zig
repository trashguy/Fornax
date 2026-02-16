/// sed — stream editor (minimal).
///
/// Usage: sed 's/old/new/' [file...]
///        sed 's/old/new/g' [file...]
/// Only supports s (substitute) command with literal strings.
const fx = @import("fornax");

const out = fx.io.Writer.stdout;
const err = fx.io.Writer.stderr;

const LINE_BUF_SIZE = 4096;

var old_pat: []const u8 = "";
var new_pat: []const u8 = "";
var global_flag: bool = false;

/// Parse s-expression: s/old/new/[g]
/// Returns true on success.
fn parseExpr(expr: []const u8) bool {
    if (expr.len < 4) return false;
    if (expr[0] != 's') return false;

    const delim = expr[1];
    // Find second delimiter
    var i: usize = 2;
    while (i < expr.len and expr[i] != delim) : (i += 1) {}
    if (i >= expr.len) return false;
    old_pat = expr[2..i];

    // Find third delimiter
    const new_start = i + 1;
    i = new_start;
    while (i < expr.len and expr[i] != delim) : (i += 1) {}
    if (i > expr.len) return false;
    new_pat = expr[new_start..i];

    // Check for 'g' flag
    if (i + 1 < expr.len and expr[i + 1] == 'g') {
        global_flag = true;
    }

    return old_pat.len > 0;
}

/// Substitute old_pat with new_pat in line, write result to stdout.
fn substituteLine(line: []const u8) void {
    if (old_pat.len == 0) {
        _ = fx.write(1, line);
        out.putc('\n');
        return;
    }

    var result_buf: [LINE_BUF_SIZE]u8 = undefined;
    var result_len: usize = 0;
    var pos: usize = 0;

    while (pos <= line.len) {
        if (pos + old_pat.len <= line.len) {
            if (fx.str.eql(line[pos..][0..old_pat.len], old_pat)) {
                // Copy new_pat
                const copy_len = @min(new_pat.len, LINE_BUF_SIZE - result_len);
                @memcpy(result_buf[result_len..][0..copy_len], new_pat[0..copy_len]);
                result_len += copy_len;
                pos += old_pat.len;
                if (!global_flag) {
                    // Copy remainder
                    const rem = line[pos..];
                    const rem_copy = @min(rem.len, LINE_BUF_SIZE - result_len);
                    @memcpy(result_buf[result_len..][0..rem_copy], rem[0..rem_copy]);
                    result_len += rem_copy;
                    break;
                }
                continue;
            }
        }
        if (pos >= line.len) break;
        if (result_len < LINE_BUF_SIZE) {
            result_buf[result_len] = line[pos];
            result_len += 1;
        }
        pos += 1;
    }

    _ = fx.write(1, result_buf[0..result_len]);
    out.putc('\n');
}

fn sedFd(fd: i32) void {
    var line_buf: [LINE_BUF_SIZE]u8 = undefined;
    var line_len: usize = 0;
    var buf: [4096]u8 = undefined;

    while (true) {
        const n = fx.read(fd, &buf);
        if (n <= 0) break;
        const len: usize = @intCast(n);

        for (buf[0..len]) |c| {
            if (c == '\n') {
                substituteLine(line_buf[0..line_len]);
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
        substituteLine(line_buf[0..line_len]);
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
        err.puts("usage: sed 's/old/new/[g]' [file...]\n");
        fx.exit(1);
    }

    const expr = argStr(args[1]);
    if (!parseExpr(expr)) {
        err.puts("sed: invalid expression\n");
        fx.exit(1);
    }

    if (args.len <= 2) {
        sedFd(0);
    } else {
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const name = argStr(args[i]);
            const fd = fx.open(name);
            if (fd < 0) {
                err.print("sed: {s}: not found\n", .{name});
                continue;
            }
            sedFd(fd);
            _ = fx.close(fd);
        }
    }

    fx.exit(0);
}
