/// fsh — Fornax shell.
///
/// rc-inspired interactive shell with quoting, variables, line editing,
/// and command history. Reads commands from stdin, executes builtins or
/// spawns programs from /bin/<name>.
/// Supports pipes (|), redirects (< >), semicolons (;), single/double
/// quotes, and $VAR expansion.
const fx = @import("fornax");

const out = fx.io.Writer.stdout;

// ── BSS buffers ────────────────────────────────────────────────────

/// 4 MB buffer for loading ELF binaries (matches spawn syscall limit).
var elf_buf: [4 * 1024 * 1024]u8 linksection(".bss") = undefined;

/// Scratch buffer for source builtin (separate from elf_buf to avoid
/// corruption when source'd scripts spawn external commands).
var source_buf: [4096]u8 linksection(".bss") = undefined;

/// Scratch buffer for materialized tokens (quoted strings, expanded vars).
var token_storage: [4096]u8 linksection(".bss") = undefined;
var token_storage_pos: usize = 0;

// ── Environment variables ──────────────────────────────────────────

const MAX_VARS = 64;
const MAX_VAR_NAME = 32;
const MAX_VAR_VALUE = 256;

const EnvVar = struct {
    name: [MAX_VAR_NAME]u8,
    name_len: u8,
    value: [MAX_VAR_VALUE]u8,
    value_len: u16,
    active: bool,
};

var env_vars: [MAX_VARS]EnvVar linksection(".bss") = undefined;
var last_exit_status: u32 = 0;
var exit_status_buf: [16]u8 = undefined;

// ── Command history ────────────────────────────────────────────────

const HISTORY_COUNT = 32;
const LINE_MAX = 512;

var history: [HISTORY_COUNT][LINE_MAX]u8 linksection(".bss") = undefined;
var history_len: [HISTORY_COUNT]u16 linksection(".bss") = undefined;
var history_head: usize = 0;
var history_count: usize = 0;

// ── Line editor state ──────────────────────────────────────────────

var edit_buf: [LINE_MAX]u8 = undefined;
var edit_len: usize = 0;
var edit_cursor: usize = 0;
var edit_saved: [LINE_MAX]u8 = undefined;
var edit_saved_len: usize = 0;
var edit_browsing: bool = false;
var history_pos: usize = 0;

// ── Environment variable functions ─────────────────────────────────

fn envInit() void {
    for (&env_vars) |*v| {
        v.active = false;
    }
    _ = envSet("PWD", "/");
}

fn envGet(name: []const u8) ?[]const u8 {
    for (&env_vars) |*v| {
        if (v.active and v.name_len == name.len) {
            if (fx.str.eql(v.name[0..v.name_len], name)) {
                return v.value[0..v.value_len];
            }
        }
    }
    return null;
}

fn envSet(name: []const u8, value: []const u8) bool {
    if (name.len == 0 or name.len > MAX_VAR_NAME) return false;
    if (value.len > MAX_VAR_VALUE) return false;

    // Update existing variable
    for (&env_vars) |*v| {
        if (v.active and v.name_len == name.len and fx.str.eql(v.name[0..v.name_len], name)) {
            const vlen = @min(value.len, MAX_VAR_VALUE);
            @memcpy(v.value[0..vlen], value[0..vlen]);
            v.value_len = @intCast(vlen);
            return true;
        }
    }

    // Find empty slot
    for (&env_vars) |*v| {
        if (!v.active) {
            const nlen = @min(name.len, MAX_VAR_NAME);
            @memcpy(v.name[0..nlen], name[0..nlen]);
            v.name_len = @intCast(nlen);
            const vlen = @min(value.len, MAX_VAR_VALUE);
            @memcpy(v.value[0..vlen], value[0..vlen]);
            v.value_len = @intCast(vlen);
            v.active = true;
            return true;
        }
    }
    return false;
}

fn envUnset(name: []const u8) void {
    for (&env_vars) |*v| {
        if (v.active and v.name_len == name.len and fx.str.eql(v.name[0..v.name_len], name)) {
            v.active = false;
            return;
        }
    }
}

// ── Variable expansion ─────────────────────────────────────────────

const VarExpansion = struct {
    consumed: usize,
    value: []const u8,
};

fn expandVar(line: []const u8, pos: usize) VarExpansion {
    if (pos + 1 >= line.len) return .{ .consumed = 1, .value = "$" };

    const next = line[pos + 1];

    // $? → last exit status
    if (next == '?') {
        return .{ .consumed = 2, .value = fx.fmt.formatDec(&exit_status_buf, last_exit_status) };
    }

    // ${VAR} → braced variable
    if (next == '{') {
        var end = pos + 2;
        while (end < line.len and line[end] != '}') : (end += 1) {}
        if (end >= line.len) return .{ .consumed = 1, .value = "$" };
        const name = line[pos + 2 .. end];
        return .{ .consumed = end - pos + 1, .value = envGet(name) orelse "" };
    }

    // $NAME → scan alphanumeric/underscore
    if (isAlpha(next) or next == '_') {
        var end = pos + 1;
        while (end < line.len and isAlphaNumUnderscore(line[end])) : (end += 1) {}
        const name = line[pos + 1 .. end];
        return .{ .consumed = end - pos, .value = envGet(name) orelse "" };
    }

    return .{ .consumed = 1, .value = "$" };
}

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn isAlphaNumUnderscore(c: u8) bool {
    return isAlpha(c) or (c >= '0' and c <= '9') or c == '_';
}

fn isAssignment(token: []const u8) ?usize {
    const eq_idx = fx.str.indexOf(token, '=') orelse return null;
    if (eq_idx == 0) return null;
    const name = token[0..eq_idx];
    if (name[0] >= '0' and name[0] <= '9') return null;
    for (name) |c| {
        if (!isAlphaNumUnderscore(c)) return null;
    }
    return eq_idx;
}

// ── Shell tokenizer ────────────────────────────────────────────────

fn shellTokenize(line: []const u8, tokens: *[64][]const u8) usize {
    var argc: usize = 0;
    var i: usize = 0;

    while (i < line.len and argc < 64) {
        // Skip whitespace
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
        if (i >= line.len) break;

        // Special single-char tokens: ; | < >
        if (line[i] == ';' or line[i] == '|' or line[i] == '<' or line[i] == '>') {
            const start = token_storage_pos;
            storeChar(line[i]);
            tokens[argc] = token_storage[start..token_storage_pos];
            argc += 1;
            i += 1;
            continue;
        }

        // Build a regular token (may include quotes and $vars)
        const tok_start = token_storage_pos;
        var quoted = false;

        while (i < line.len and line[i] != ' ' and line[i] != '\t' and
            line[i] != ';' and line[i] != '|' and line[i] != '<' and line[i] != '>')
        {
            if (line[i] == '\'') {
                // Single quote: copy literally until closing quote
                quoted = true;
                i += 1;
                while (i < line.len and line[i] != '\'') : (i += 1) {
                    storeChar(line[i]);
                }
                if (i < line.len) i += 1;
            } else if (line[i] == '"') {
                // Double quote: expand $vars, handle backslash escapes
                quoted = true;
                i += 1;
                while (i < line.len and line[i] != '"') {
                    if (line[i] == '\\' and i + 1 < line.len) {
                        const esc = line[i + 1];
                        if (esc == '"' or esc == '\\' or esc == '$') {
                            storeChar(esc);
                            i += 2;
                        } else if (esc == 'n') {
                            storeChar('\n');
                            i += 2;
                        } else {
                            storeChar(line[i]);
                            i += 1;
                        }
                    } else if (line[i] == '$') {
                        const exp = expandVar(line, i);
                        storeSlice(exp.value);
                        i += exp.consumed;
                    } else {
                        storeChar(line[i]);
                        i += 1;
                    }
                }
                if (i < line.len) i += 1;
            } else if (line[i] == '$') {
                const exp = expandVar(line, i);
                storeSlice(exp.value);
                i += exp.consumed;
            } else {
                storeChar(line[i]);
                i += 1;
            }
        }

        if (token_storage_pos > tok_start or quoted) {
            tokens[argc] = token_storage[tok_start..token_storage_pos];
            argc += 1;
        }
    }

    return argc;
}

fn storeChar(c: u8) void {
    if (token_storage_pos < token_storage.len) {
        token_storage[token_storage_pos] = c;
        token_storage_pos += 1;
    }
}

fn storeSlice(s: []const u8) void {
    for (s) |c| storeChar(c);
}

// ── Line editor ────────────────────────────────────────────────────

fn editLine(prompt: []const u8) ?[]const u8 {
    out.puts(prompt);
    _ = fx.write(0, "rawon");
    _ = fx.write(0, "echo off");

    edit_len = 0;
    edit_cursor = 0;
    edit_browsing = false;
    history_pos = 0;

    while (true) {
        const byte = readByte() orelse {
            _ = fx.write(0, "rawoff");
            _ = fx.write(0, "echo on");
            return null;
        };

        switch (byte) {
            0x0D, 0x0A => {
                out.putc('\n');
                const line = edit_buf[0..edit_len];
                historyAdd(line);
                _ = fx.write(0, "rawoff");
                _ = fx.write(0, "echo on");
                return line;
            },
            0x08, 0x7F => {
                if (edit_cursor > 0) {
                    var j = edit_cursor - 1;
                    while (j + 1 < edit_len) : (j += 1) {
                        edit_buf[j] = edit_buf[j + 1];
                    }
                    edit_len -= 1;
                    edit_cursor -= 1;
                    redrawLine(prompt);
                }
            },
            0x1B => {
                const b2 = readByte() orelse continue;
                if (b2 != '[') continue;
                const b3 = readByte() orelse continue;
                switch (b3) {
                    'A' => historyUp(prompt),
                    'B' => historyDown(prompt),
                    'C' => {
                        if (edit_cursor < edit_len) {
                            edit_cursor += 1;
                            redrawLine(prompt);
                        }
                    },
                    'D' => {
                        if (edit_cursor > 0) {
                            edit_cursor -= 1;
                            redrawLine(prompt);
                        }
                    },
                    'H' => {
                        edit_cursor = 0;
                        redrawLine(prompt);
                    },
                    'F' => {
                        edit_cursor = edit_len;
                        redrawLine(prompt);
                    },
                    else => {},
                }
            },
            0x03 => {
                edit_len = 0;
                edit_cursor = 0;
                edit_browsing = false;
                history_pos = 0;
                out.putc('\n');
                out.puts(prompt);
            },
            0x04 => {
                if (edit_len == 0) {
                    out.putc('\n');
                    _ = fx.write(0, "rawoff");
                    _ = fx.write(0, "echo on");
                    return null;
                }
            },
            else => {
                if (byte >= 0x20 and byte <= 0x7E and edit_len < LINE_MAX - 1) {
                    var j: usize = edit_len;
                    while (j > edit_cursor) {
                        edit_buf[j] = edit_buf[j - 1];
                        j -= 1;
                    }
                    edit_buf[edit_cursor] = byte;
                    edit_len += 1;
                    edit_cursor += 1;
                    redrawLine(prompt);
                }
            },
        }
    }
}

fn readByte() ?u8 {
    var buf: [1]u8 = undefined;
    const n = fx.read(0, &buf);
    if (n <= 0) return null;
    return buf[0];
}

fn redrawLine(prompt: []const u8) void {
    out.putc('\r');
    out.puts(prompt);
    if (edit_len > 0) {
        out.puts(edit_buf[0..edit_len]);
    }
    // Erase trailing characters
    var pad: usize = 0;
    while (pad < 8) : (pad += 1) out.putc(' ');
    // Move cursor to correct position
    var back: usize = 8 + (edit_len - edit_cursor);
    while (back > 0) : (back -= 1) out.putc(0x08);
}

fn historyUp(prompt: []const u8) void {
    if (history_count == 0) return;
    if (!edit_browsing) {
        @memcpy(edit_saved[0..edit_len], edit_buf[0..edit_len]);
        edit_saved_len = edit_len;
        edit_browsing = true;
        history_pos = 0;
    }
    if (history_pos < history_count) {
        history_pos += 1;
        if (historyGet(history_pos - 1)) |entry| {
            @memcpy(edit_buf[0..entry.len], entry);
            edit_len = entry.len;
            edit_cursor = edit_len;
        }
    }
    redrawLine(prompt);
}

fn historyDown(prompt: []const u8) void {
    if (!edit_browsing) return;
    if (history_pos > 1) {
        history_pos -= 1;
        if (historyGet(history_pos - 1)) |entry| {
            @memcpy(edit_buf[0..entry.len], entry);
            edit_len = entry.len;
            edit_cursor = edit_len;
        }
    } else {
        history_pos = 0;
        edit_browsing = false;
        @memcpy(edit_buf[0..edit_saved_len], edit_saved[0..edit_saved_len]);
        edit_len = edit_saved_len;
        edit_cursor = edit_len;
    }
    redrawLine(prompt);
}

fn historyAdd(line: []const u8) void {
    if (line.len == 0) return;
    if (history_count > 0) {
        const prev = (history_head + HISTORY_COUNT - 1) % HISTORY_COUNT;
        if (fx.str.eql(history[prev][0..history_len[prev]], line)) return;
    }
    const n = @min(line.len, LINE_MAX);
    @memcpy(history[history_head][0..n], line[0..n]);
    history_len[history_head] = @intCast(n);
    history_head = (history_head + 1) % HISTORY_COUNT;
    if (history_count < HISTORY_COUNT) history_count += 1;
}

fn historyGet(offset: usize) ?[]const u8 {
    if (offset >= history_count) return null;
    const idx = (history_head + HISTORY_COUNT - 1 - offset) % HISTORY_COUNT;
    const len = history_len[idx];
    return history[idx][0..len];
}

// ── Builtins ────────────────────────────────────────────────────────

fn builtinEcho(args: []const []const u8) void {
    for (args, 0..) |arg, i| {
        if (i > 0) out.putc(' ');
        out.puts(arg);
    }
    out.putc('\n');
    last_exit_status = 0;
}

fn builtinClear() void {
    var i: usize = 0;
    while (i < 50) : (i += 1) out.putc('\n');
    last_exit_status = 0;
}

fn builtinHelp() void {
    out.puts("fsh — Fornax shell\n");
    out.puts("builtins: echo clear help exit cd pwd set unset source true false\n");
    out.puts("syntax:   cmd | cmd    (pipe)\n");
    out.puts("          cmd > file   (redirect stdout)\n");
    out.puts("          cmd < file   (redirect stdin)\n");
    out.puts("          cmd ; cmd    (sequence)\n");
    out.puts("          'text'       (literal quoting)\n");
    out.puts("          \"$VAR\"       (variable expansion)\n");
    out.puts("          VAR=value    (set variable)\n");
    out.puts("programs:");

    const fd = fx.open("/boot");
    if (fd < 0) {
        out.putc('\n');
        last_exit_status = 0;
        return;
    }
    defer _ = fx.close(fd);

    var dir_buf: [4096]u8 = undefined;
    const n = fx.read(fd, &dir_buf);
    if (n > 0) {
        const bytes: usize = @intCast(n);
        const entry_size = @sizeOf(fx.DirEntry);
        var off: usize = 0;
        while (off + entry_size <= bytes) : (off += entry_size) {
            const entry: *const fx.DirEntry = @ptrCast(@alignCast(dir_buf[off..][0..entry_size]));
            if (entry.file_type == 0) {
                const name = blk: {
                    for (entry.name, 0..) |c, j| {
                        if (c == 0) break :blk entry.name[0..j];
                    }
                    break :blk &entry.name;
                };
                out.putc(' ');
                out.puts(name);
            }
        }
    }
    out.putc('\n');
    last_exit_status = 0;
}

fn builtinCd(args: []const []const u8) void {
    const target = if (args.len > 0) args[0] else "/";
    var p = resolvePath(target);
    _ = p.normalize();

    const fd = fx.open(p.slice());
    if (fd < 0) {
        out.print("fsh: cd: {s}: not found\n", .{p.slice()});
        last_exit_status = 1;
        return;
    }
    _ = fx.close(fd);
    _ = envSet("PWD", p.slice());
    last_exit_status = 0;
}

fn builtinPwd() void {
    out.puts(envGet("PWD") orelse "/");
    out.putc('\n');
    last_exit_status = 0;
}

fn builtinSet() void {
    for (&env_vars) |*v| {
        if (v.active) {
            out.puts(v.name[0..v.name_len]);
            out.putc('=');
            out.puts(v.value[0..v.value_len]);
            out.putc('\n');
        }
    }
    last_exit_status = 0;
}

fn builtinUnset(args: []const []const u8) void {
    if (args.len == 0) {
        out.puts("fsh: unset: usage: unset VAR\n");
        last_exit_status = 1;
        return;
    }
    envUnset(args[0]);
    last_exit_status = 0;
}

fn builtinSource(args: []const []const u8) void {
    if (args.len == 0) {
        out.puts("fsh: source: usage: source <file>\n");
        last_exit_status = 1;
        return;
    }
    var p = resolvePath(args[0]);
    _ = p.normalize();
    const fd = fx.open(p.slice());
    if (fd < 0) {
        out.print("fsh: source: {s}: not found\n", .{p.slice()});
        last_exit_status = 1;
        return;
    }

    var total: usize = 0;
    while (total < source_buf.len) {
        const n = fx.read(fd, source_buf[total..]);
        if (n <= 0) break;
        total += @intCast(n);
    }
    _ = fx.close(fd);

    if (total == 0) return;

    var line_start: usize = 0;
    var si: usize = 0;
    while (si < total) : (si += 1) {
        if (source_buf[si] == '\n') {
            if (si > line_start) {
                processLine(source_buf[line_start..si]);
            }
            line_start = si + 1;
        }
    }
    if (line_start < total) {
        processLine(source_buf[line_start..total]);
    }
}

// ── Path resolution ────────────────────────────────────────────────

fn resolvePath(path: []const u8) fx.path.PathBuf {
    if (path.len > 0 and path[0] == '/') {
        return fx.path.PathBuf.from(path);
    }
    var p = fx.path.PathBuf.from(envGet("PWD") orelse "/");
    _ = p.append(path);
    return p;
}

// ── ELF loading ────────────────────────────────────────────────────

fn loadElfFromPath(path: []const u8) ?[]const u8 {
    const fd = fx.open(path);
    if (fd < 0) return null;

    var total: usize = 0;
    while (total < elf_buf.len) {
        const n = fx.read(fd, elf_buf[total..]);
        if (n <= 0) break;
        total += @intCast(n);
    }
    _ = fx.close(fd);

    if (total == 0) return null;
    return elf_buf[0..total];
}

fn loadElf(name: []const u8) ?[]const u8 {
    if (fx.str.indexOf(name, '/') != null) {
        var p = resolvePath(name);
        _ = p.normalize();
        return loadElfFromPath(p.slice());
    }
    var p = fx.path.PathBuf.from("/bin/");
    _ = p.appendRaw(name);
    return loadElfFromPath(p.slice());
}

fn buildArgv(name: []const u8, args: []const []const u8, buf: []u8) ?[]const u8 {
    var argv_parts: [65][]const u8 = undefined;
    argv_parts[0] = name;
    const n_args = @min(args.len, 64);
    for (0..n_args) |i| {
        argv_parts[1 + i] = args[i];
    }
    return fx.buildArgvBlock(buf, argv_parts[0 .. 1 + n_args]);
}

// ── External command execution ─────────────────────────────────────

fn runExternalWithFds(name: []const u8, args: []const []const u8, fd_map: []const fx.FdMapping) i32 {
    const elf_data = loadElf(name) orelse {
        out.print("fsh: {s}: not found\n", .{name});
        last_exit_status = 127;
        return -1;
    };

    var argv_buf: [4096]u8 = undefined;
    const argv_block = buildArgv(name, args, &argv_buf);

    const pid = fx.spawn(elf_data, fd_map, argv_block);
    if (pid < 0) {
        out.print("fsh: {s}: spawn failed\n", .{name});
        last_exit_status = 126;
    }
    return pid;
}

fn runExternal(name: []const u8, args: []const []const u8) void {
    const pid = runExternalWithFds(name, args, &.{});
    if (pid >= 0) {
        const status = fx.wait(@intCast(pid));
        last_exit_status = @truncate(status);
    }
}

// ── Pipeline execution ─────────────────────────────────────────────

const Stage = struct {
    cmd: []const u8,
    args: [64][]const u8 = undefined,
    argc: usize = 0,
};

fn parseStage(toks: []const []const u8) Stage {
    var s = Stage{ .cmd = toks[0] };
    const n = @min(toks.len - 1, 64);
    for (0..n) |j| {
        s.args[j] = toks[1 + j];
    }
    s.argc = n;
    return s;
}

fn runPipeline(stages: []Stage, n_stages: usize) void {
    if (n_stages == 0) return;
    if (n_stages == 1) {
        runExternal(stages[0].cmd, stages[0].args[0..stages[0].argc]);
        return;
    }

    var pipe_fds: [7]struct { read_fd: i32, write_fd: i32 } = undefined;
    const n_pipes = n_stages - 1;
    if (n_pipes > 7) {
        out.puts("fsh: too many pipeline stages\n");
        return;
    }

    for (0..n_pipes) |i| {
        const p = fx.pipe();
        if (p.err != 0) {
            out.puts("fsh: pipe failed\n");
            for (0..i) |j| {
                _ = fx.close(pipe_fds[j].read_fd);
                _ = fx.close(pipe_fds[j].write_fd);
            }
            return;
        }
        pipe_fds[i] = .{ .read_fd = p.read_fd, .write_fd = p.write_fd };
    }

    var pids: [8]i32 = undefined;
    for (0..n_stages) |i| {
        var fd_map_buf: [2]fx.FdMapping = undefined;
        var fd_map_len: usize = 0;

        if (i > 0) {
            fd_map_buf[fd_map_len] = .{
                .child_fd = 0,
                .parent_fd = @intCast(pipe_fds[i - 1].read_fd),
            };
            fd_map_len += 1;
        }

        if (i < n_stages - 1) {
            fd_map_buf[fd_map_len] = .{
                .child_fd = 1,
                .parent_fd = @intCast(pipe_fds[i].write_fd),
            };
            fd_map_len += 1;
        }

        pids[i] = runExternalWithFds(
            stages[i].cmd,
            stages[i].args[0..stages[i].argc],
            fd_map_buf[0..fd_map_len],
        );
    }

    for (0..n_pipes) |i| {
        _ = fx.close(pipe_fds[i].read_fd);
        _ = fx.close(pipe_fds[i].write_fd);
    }

    for (0..n_stages) |i| {
        if (pids[i] >= 0) {
            const status = fx.wait(@intCast(pids[i]));
            if (i == n_stages - 1) {
                last_exit_status = @truncate(status);
            }
        }
    }
}

// ── Command dispatch ───────────────────────────────────────────────

fn executeLine(tokens: []const []const u8) void {
    const argc = tokens.len;
    if (argc == 0) return;

    // Check for pipes — split into pipeline stages
    var stages: [8]Stage = undefined;
    var n_stages: usize = 0;
    var stage_start: usize = 0;

    var i: usize = 0;
    while (i < argc) : (i += 1) {
        if (fx.str.eql(tokens[i], "|")) {
            if (stage_start == i) {
                out.puts("fsh: syntax error near |\n");
                return;
            }
            if (n_stages >= 8) {
                out.puts("fsh: too many pipeline stages\n");
                return;
            }
            stages[n_stages] = parseStage(tokens[stage_start..i]);
            n_stages += 1;
            stage_start = i + 1;
        }
    }

    if (stage_start >= argc) {
        out.puts("fsh: syntax error near |\n");
        return;
    }

    if (n_stages >= 8) {
        out.puts("fsh: too many pipeline stages\n");
        return;
    }
    stages[n_stages] = parseStage(tokens[stage_start..argc]);
    n_stages += 1;

    if (n_stages == 1) {
        const stage = &stages[0];

        // Filter redirects
        var redir_in: ?[]const u8 = null;
        var redir_out: ?[]const u8 = null;
        var clean_argc: usize = 0;
        var clean_args: [64][]const u8 = undefined;

        var j: usize = 0;
        while (j < stage.argc) : (j += 1) {
            if (fx.str.eql(stage.args[j], ">") and j + 1 < stage.argc) {
                redir_out = stage.args[j + 1];
                j += 1;
            } else if (fx.str.eql(stage.args[j], "<") and j + 1 < stage.argc) {
                redir_in = stage.args[j + 1];
                j += 1;
            } else {
                clean_args[clean_argc] = stage.args[j];
                clean_argc += 1;
            }
        }

        const cmd = stage.cmd;

        // Dispatch builtins (no redirect support for builtins)
        if (redir_in == null and redir_out == null) {
            if (fx.str.eql(cmd, "exit")) {
                if (clean_argc > 0) {
                    if (fx.str.parseUint(clean_args[0])) |code| {
                        fx.exit(@intCast(code));
                    }
                }
                fx.exit(0);
            } else if (fx.str.eql(cmd, "echo")) {
                builtinEcho(clean_args[0..clean_argc]);
                return;
            } else if (fx.str.eql(cmd, "clear")) {
                builtinClear();
                return;
            } else if (fx.str.eql(cmd, "help")) {
                builtinHelp();
                return;
            } else if (fx.str.eql(cmd, "cd")) {
                builtinCd(clean_args[0..clean_argc]);
                return;
            } else if (fx.str.eql(cmd, "pwd")) {
                builtinPwd();
                return;
            } else if (fx.str.eql(cmd, "set")) {
                builtinSet();
                return;
            } else if (fx.str.eql(cmd, "unset")) {
                builtinUnset(clean_args[0..clean_argc]);
                return;
            } else if (fx.str.eql(cmd, "source")) {
                builtinSource(clean_args[0..clean_argc]);
                return;
            } else if (fx.str.eql(cmd, "true")) {
                last_exit_status = 0;
                return;
            } else if (fx.str.eql(cmd, "false")) {
                last_exit_status = 1;
                return;
            }
        }

        // External command with optional redirects
        var fd_map_buf: [2]fx.FdMapping = undefined;
        var fd_map_len: usize = 0;
        var in_fd: i32 = -1;
        var out_fd: i32 = -1;

        if (redir_in) |path| {
            in_fd = fx.open(path);
            if (in_fd < 0) {
                out.print("fsh: {s}: not found\n", .{path});
                last_exit_status = 1;
                return;
            }
            fd_map_buf[fd_map_len] = .{ .child_fd = 0, .parent_fd = @intCast(in_fd) };
            fd_map_len += 1;
        }

        if (redir_out) |path| {
            out_fd = fx.create(path, 0);
            if (out_fd < 0) {
                out.print("fsh: {s}: create failed\n", .{path});
                if (in_fd >= 0) _ = fx.close(in_fd);
                last_exit_status = 1;
                return;
            }
            fd_map_buf[fd_map_len] = .{ .child_fd = 1, .parent_fd = @intCast(out_fd) };
            fd_map_len += 1;
        }

        const pid = runExternalWithFds(cmd, clean_args[0..clean_argc], fd_map_buf[0..fd_map_len]);

        if (pid >= 0) {
            const status = fx.wait(@intCast(pid));
            last_exit_status = @truncate(status);
        }

        // Close redirect fds AFTER wait — closing before wait races with
        // the child's use of the same IPC channel (T_CLOSE frees the server
        // handle, and the channel's single client endpoint gets clobbered).
        if (in_fd >= 0) _ = fx.close(in_fd);
        if (out_fd >= 0) _ = fx.close(out_fd);
    } else {
        runPipeline(&stages, n_stages);
    }
}

// ── Line processing ────────────────────────────────────────────────

fn processLine(line: []const u8) void {
    const saved_pos = token_storage_pos;
    defer token_storage_pos = saved_pos;

    var tokens: [64][]const u8 = undefined;
    const argc = shellTokenize(line, &tokens);
    if (argc == 0) return;

    // Check for variable assignment (first token only)
    if (isAssignment(tokens[0])) |eq_idx| {
        const name = tokens[0][0..eq_idx];
        const value = tokens[0][eq_idx + 1 ..];
        _ = envSet(name, value);
        last_exit_status = 0;
        return;
    }

    executeTokens(tokens[0..argc]);
}

fn executeTokens(tokens: []const []const u8) void {
    var start: usize = 0;
    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        if (fx.str.eql(tokens[i], ";")) {
            if (i > start) {
                executeLine(tokens[start..i]);
            }
            start = i + 1;
        }
    }
    if (start < tokens.len) {
        executeLine(tokens[start..tokens.len]);
    }
}

// ── Entry point ────────────────────────────────────────────────────

export fn _start() noreturn {
    builtinClear();
    out.puts("fsh: Fornax shell\n");
    envInit();

    while (true) {
        const line = editLine("fornax% ") orelse break;
        if (line.len == 0) continue;
        processLine(line);
    }

    fx.exit(0);
}
