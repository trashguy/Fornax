/// awk — pattern scanning and processing (minimal).
///
/// Usage: awk '{print $N}' [file...]
///        awk -F: '{print $1}' [file...]
/// Only supports field extraction with print $N.
/// Multiple fields: awk '{print $1, $3}' (comma-separated).
const fx = @import("fornax");

const out = fx.io.Writer.stdout;
const err = fx.io.Writer.stderr;

const LINE_BUF_SIZE = 4096;
const MAX_FIELDS = 64;

var delim: u8 = ' ';
var use_whitespace: bool = true;

/// Indices of fields to print (1-based, 0 = whole line).
var print_fields: [MAX_FIELDS]u32 = undefined;
var print_count: usize = 0;

/// Parse '{print $N}' or '{print $1, $2, ...}'.
fn parseProgram(prog: []const u8) bool {
    // Strip braces
    var s = prog;
    if (s.len >= 2 and s[0] == '{' and s[s.len - 1] == '}') {
        s = s[1 .. s.len - 1];
    }

    // Skip leading whitespace
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}

    // Expect "print"
    if (i + 5 > s.len) return false;
    if (!fx.str.eql(s[i..][0..5], "print")) return false;
    i += 5;

    // Parse field references
    print_count = 0;
    while (i < s.len) {
        // Skip whitespace and commas
        while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == ',')) : (i += 1) {}
        if (i >= s.len) break;

        if (s[i] == '$') {
            i += 1;
            var num: u32 = 0;
            while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
                num = num * 10 + (s[i] - '0');
            }
            if (print_count < MAX_FIELDS) {
                print_fields[print_count] = num;
                print_count += 1;
            }
        } else {
            break;
        }
    }

    return print_count > 0;
}

/// Split line into fields based on delimiter.
fn splitFields(line: []const u8, fields: [][]const u8) usize {
    var count: usize = 0;
    var i: usize = 0;

    if (use_whitespace) {
        // Whitespace splitting: skip leading/consecutive whitespace
        while (i < line.len and count < fields.len) {
            while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
            if (i >= line.len) break;
            const start = i;
            while (i < line.len and line[i] != ' ' and line[i] != '\t') : (i += 1) {}
            fields[count] = line[start..i];
            count += 1;
        }
    } else {
        // Single-character delimiter
        var start = i;
        while (i <= line.len) : (i += 1) {
            if (i == line.len or line[i] == delim) {
                if (count < fields.len) {
                    fields[count] = line[start..i];
                    count += 1;
                }
                start = i + 1;
            }
        }
    }

    return count;
}

fn awkFd(fd: i32) void {
    var line_buf: [LINE_BUF_SIZE]u8 = undefined;
    var line_len: usize = 0;
    var buf: [4096]u8 = undefined;

    while (true) {
        const n = fx.read(fd, &buf);
        if (n <= 0) break;
        const len: usize = @intCast(n);

        for (buf[0..len]) |c| {
            if (c == '\n') {
                processLine(line_buf[0..line_len]);
                line_len = 0;
            } else {
                if (line_len < LINE_BUF_SIZE) {
                    line_buf[line_len] = c;
                    line_len += 1;
                }
            }
        }
    }

    if (line_len > 0) {
        processLine(line_buf[0..line_len]);
    }
}

fn processLine(line: []const u8) void {
    var fields: [MAX_FIELDS][]const u8 = undefined;
    const field_count = splitFields(line, &fields);

    var i: usize = 0;
    while (i < print_count) : (i += 1) {
        if (i > 0) out.putc(' ');

        const idx = print_fields[i];
        if (idx == 0) {
            // $0 = whole line
            _ = fx.write(1, line);
        } else if (idx <= field_count) {
            _ = fx.write(1, fields[idx - 1]);
        }
    }
    out.putc('\n');
}

fn argStr(arg: [*]const u8) []const u8 {
    var len: usize = 0;
    while (arg[len] != 0) : (len += 1) {}
    return arg[0..len];
}

export fn _start() noreturn {
    const args = fx.getArgs();

    if (args.len < 2) {
        err.puts("usage: awk [-F delim] '{print $N}' [file...]\n");
        fx.exit(1);
    }

    var prog_idx: usize = 1;

    // Parse -F option
    if (args.len > 2) {
        const a1 = argStr(args[1]);
        if (fx.str.startsWith(a1, "-F")) {
            if (a1.len > 2) {
                // -F: (delimiter attached)
                delim = a1[2];
                use_whitespace = false;
            } else if (args.len > 2) {
                // -F :
                const d = argStr(args[2]);
                if (d.len > 0) {
                    delim = d[0];
                    use_whitespace = false;
                }
                prog_idx = 3;
            }
            if (prog_idx == 1) prog_idx = 2;
        }
    }

    if (prog_idx >= args.len) {
        err.puts("awk: missing program\n");
        fx.exit(1);
    }

    const prog = argStr(args[prog_idx]);
    if (!parseProgram(prog)) {
        err.puts("awk: invalid program (use '{print $N}')\n");
        fx.exit(1);
    }

    const file_start = prog_idx + 1;

    if (args.len <= file_start) {
        awkFd(0);
    } else {
        var i: usize = file_start;
        while (i < args.len) : (i += 1) {
            const name = argStr(args[i]);
            const fd = fx.open(name);
            if (fd < 0) {
                err.print("awk: {s}: not found\n", .{name});
                continue;
            }
            awkFd(fd);
            _ = fx.close(fd);
        }
    }

    fx.exit(0);
}
