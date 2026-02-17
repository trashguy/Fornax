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

    const uid = fx.getuid();
    if (fx.passwd.lookupByUid(uid)) |entry| {
        const home = entry.homeSlice();
        _ = envSet("HOME", if (home.len > 0) home else "/");
        _ = envSet("PWD", if (home.len > 0) home else "/");
        _ = envSet("USER", entry.usernameSlice());
    } else {
        _ = envSet("HOME", "/");
        _ = envSet("PWD", "/");
    }
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

// ── Aliases ───────────────────────────────────────────────────────

const MAX_ALIASES = 32;
const MAX_ALIAS_NAME = 32;
const MAX_ALIAS_VALUE = 256;

const Alias = struct {
    name: [MAX_ALIAS_NAME]u8,
    name_len: u8,
    value: [MAX_ALIAS_VALUE]u8,
    value_len: u16,
    active: bool,
};

var aliases: [MAX_ALIASES]Alias linksection(".bss") = undefined;

fn aliasInit() void {
    for (&aliases) |*a| {
        a.active = false;
    }
}

fn aliasGet(name: []const u8) ?[]const u8 {
    for (&aliases) |*a| {
        if (a.active and a.name_len == name.len) {
            if (fx.str.eql(a.name[0..a.name_len], name)) {
                return a.value[0..a.value_len];
            }
        }
    }
    return null;
}

fn aliasSet(name: []const u8, value: []const u8) bool {
    if (name.len == 0 or name.len > MAX_ALIAS_NAME) return false;
    if (value.len > MAX_ALIAS_VALUE) return false;

    // Update existing alias
    for (&aliases) |*a| {
        if (a.active and a.name_len == name.len and fx.str.eql(a.name[0..a.name_len], name)) {
            const vlen = @min(value.len, MAX_ALIAS_VALUE);
            @memcpy(a.value[0..vlen], value[0..vlen]);
            a.value_len = @intCast(vlen);
            return true;
        }
    }

    // Find empty slot
    for (&aliases) |*a| {
        if (!a.active) {
            const nlen = @min(name.len, MAX_ALIAS_NAME);
            @memcpy(a.name[0..nlen], name[0..nlen]);
            a.name_len = @intCast(nlen);
            const vlen = @min(value.len, MAX_ALIAS_VALUE);
            @memcpy(a.value[0..vlen], value[0..vlen]);
            a.value_len = @intCast(vlen);
            a.active = true;
            return true;
        }
    }
    return false;
}

fn aliasUnset(name: []const u8) void {
    for (&aliases) |*a| {
        if (a.active and a.name_len == name.len and fx.str.eql(a.name[0..a.name_len], name)) {
            a.active = false;
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

        // Comment: # to end-of-line (outside quotes)
        if (line[i] == '#') break;

        // Special tokens: ; | || < > >> &&
        if (line[i] == ';' or line[i] == '<') {
            const start = token_storage_pos;
            storeChar(line[i]);
            tokens[argc] = token_storage[start..token_storage_pos];
            argc += 1;
            i += 1;
            continue;
        }

        if (line[i] == '|') {
            const start = token_storage_pos;
            if (i + 1 < line.len and line[i + 1] == '|') {
                storeChar('|');
                storeChar('|');
                i += 2;
            } else {
                storeChar('|');
                i += 1;
            }
            tokens[argc] = token_storage[start..token_storage_pos];
            argc += 1;
            continue;
        }

        if (line[i] == '&' and i + 1 < line.len and line[i + 1] == '&') {
            const start = token_storage_pos;
            storeChar('&');
            storeChar('&');
            tokens[argc] = token_storage[start..token_storage_pos];
            argc += 1;
            i += 2;
            continue;
        }

        if (line[i] == '>') {
            const start = token_storage_pos;
            storeChar('>');
            if (i + 1 < line.len and line[i + 1] == '>') {
                storeChar('>');
                i += 2;
            } else {
                i += 1;
            }
            tokens[argc] = token_storage[start..token_storage_pos];
            argc += 1;
            continue;
        }

        // Build a regular token (may include quotes and $vars)
        const tok_start = token_storage_pos;
        var quoted = false;

        while (i < line.len and line[i] != ' ' and line[i] != '\t' and
            line[i] != ';' and line[i] != '|' and line[i] != '<' and line[i] != '>' and
            !(line[i] == '&' and i + 1 < line.len and line[i + 1] == '&'))
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
    out.puts("builtins: echo clear help exit cd pwd set unset export source\n");
    out.puts("          alias unalias true false test [ ]\n");
    out.puts("syntax:   cmd | cmd    (pipe)\n");
    out.puts("          cmd > file   (redirect stdout)\n");
    out.puts("          cmd < file   (redirect stdin)\n");
    out.puts("          cmd ; cmd    (sequence)\n");
    out.puts("          cmd && cmd   (run if success)\n");
    out.puts("          cmd || cmd   (run if failure)\n");
    out.puts("          'text'       (literal quoting)\n");
    out.puts("          \"$VAR\"       (variable expansion)\n");
    out.puts("          VAR=value    (set variable)\n");
    out.puts("          # comment\n");
    out.puts("          if cmd; then cmd; [else cmd;] fi\n");
    out.puts("          while cmd; do cmd; done\n");
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

fn builtinAlias(args: []const []const u8) void {
    if (args.len == 0) {
        // List all aliases
        for (&aliases) |*a| {
            if (a.active) {
                out.print("alias {s}='{s}'\n", .{ a.name[0..a.name_len], a.value[0..a.value_len] });
            }
        }
        last_exit_status = 0;
        return;
    }

    for (args) |arg| {
        // Parse name=value
        if (fx.str.indexOf(arg, '=')) |eq_idx| {
            if (eq_idx == 0) {
                out.puts("fsh: alias: invalid name\n");
                last_exit_status = 1;
                return;
            }
            const name = arg[0..eq_idx];
            const value = arg[eq_idx + 1 ..];
            if (!aliasSet(name, value)) {
                out.puts("fsh: alias: table full\n");
                last_exit_status = 1;
                return;
            }
        } else {
            // Print single alias
            if (aliasGet(arg)) |value| {
                out.print("alias {s}='{s}'\n", .{ arg, value });
            } else {
                out.print("fsh: alias: {s}: not found\n", .{arg});
                last_exit_status = 1;
                return;
            }
        }
    }
    last_exit_status = 0;
}

fn builtinUnalias(args: []const []const u8) void {
    if (args.len == 0) {
        out.puts("fsh: unalias: usage: unalias name\n");
        last_exit_status = 1;
        return;
    }
    for (args) |arg| {
        aliasUnset(arg);
    }
    last_exit_status = 0;
}

fn builtinExport(args: []const []const u8) void {
    if (args.len == 0) {
        // List all variables (same as set, for now)
        for (&env_vars) |*v| {
            if (v.active) {
                out.print("export {s}={s}\n", .{ v.name[0..v.name_len], v.value[0..v.value_len] });
            }
        }
        last_exit_status = 0;
        return;
    }

    for (args) |arg| {
        if (fx.str.indexOf(arg, '=')) |eq_idx| {
            if (eq_idx == 0) {
                out.puts("fsh: export: invalid name\n");
                last_exit_status = 1;
                return;
            }
            const name = arg[0..eq_idx];
            const value = arg[eq_idx + 1 ..];
            if (!envSet(name, value)) {
                out.puts("fsh: export: table full\n");
                last_exit_status = 1;
                return;
            }
        } else {
            // export FOO (without =value) — just check it exists
            if (envGet(arg) == null) {
                out.print("fsh: export: {s}: not set\n", .{arg});
            }
        }
    }
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
    redir_in: ?[]const u8 = null,
    redir_out: ?[]const u8 = null,
    redir_err: ?[]const u8 = null,
    redir_out_append: bool = false,
    redir_err_append: bool = false,
};

fn parseStage(toks: []const []const u8) Stage {
    var s = Stage{ .cmd = toks[0] };
    var j: usize = 0;
    var i: usize = 1;
    while (i < toks.len) : (i += 1) {
        const is_stderr = j > 0 and fx.str.eql(s.args[j - 1], "2");
        if (fx.str.eql(toks[i], ">>") and i + 1 < toks.len) {
            if (is_stderr) {
                j -= 1;
                s.redir_err = toks[i + 1];
                s.redir_err_append = true;
            } else {
                s.redir_out = toks[i + 1];
                s.redir_out_append = true;
            }
            i += 1;
        } else if (fx.str.eql(toks[i], ">") and i + 1 < toks.len) {
            if (is_stderr) {
                j -= 1;
                s.redir_err = toks[i + 1];
            } else {
                s.redir_out = toks[i + 1];
            }
            i += 1;
        } else if (fx.str.eql(toks[i], "<") and i + 1 < toks.len) {
            s.redir_in = toks[i + 1];
            i += 1;
        } else {
            if (j < 64) {
                s.args[j] = toks[i];
                j += 1;
            }
        }
    }
    s.argc = j;
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

    for (0..n_pipes) |pi| {
        const p = fx.pipe();
        if (p.err != 0) {
            out.puts("fsh: pipe failed\n");
            for (0..pi) |j| {
                _ = fx.close(pipe_fds[j].read_fd);
                _ = fx.close(pipe_fds[j].write_fd);
            }
            return;
        }
        pipe_fds[pi] = .{ .read_fd = p.read_fd, .write_fd = p.write_fd };
    }

    // Open redirect fds for all stages before spawning
    var redir: [8]RedirFds = undefined;
    for (0..n_stages) |si| {
        redir[si] = openRedirFds(&stages[si]);
        if (!redir[si].ok) {
            // Clean up already-opened redirect fds
            for (0..si) |j| closeRedirFds(&redir[j]);
            for (0..n_pipes) |j| {
                _ = fx.close(pipe_fds[j].read_fd);
                _ = fx.close(pipe_fds[j].write_fd);
            }
            last_exit_status = 1;
            return;
        }
    }

    var pids: [8]i32 = undefined;
    for (0..n_stages) |si| {
        var fd_map_buf: [5]fx.FdMapping = undefined;
        var fd_map_len: usize = 0;

        // Pipe stdin (overridden by redir_in if set)
        if (si > 0 and stages[si].redir_in == null) {
            fd_map_buf[fd_map_len] = .{
                .child_fd = 0,
                .parent_fd = @intCast(pipe_fds[si - 1].read_fd),
            };
            fd_map_len += 1;
        }

        // Pipe stdout (overridden by redir_out if set)
        if (si < n_stages - 1 and stages[si].redir_out == null) {
            fd_map_buf[fd_map_len] = .{
                .child_fd = 1,
                .parent_fd = @intCast(pipe_fds[si].write_fd),
            };
            fd_map_len += 1;
        }

        // Add redirect fd mappings
        for (redir[si].fd_map[0..redir[si].fd_map_len]) |m| {
            fd_map_buf[fd_map_len] = m;
            fd_map_len += 1;
        }

        pids[si] = runExternalWithFds(
            stages[si].cmd,
            stages[si].args[0..stages[si].argc],
            fd_map_buf[0..fd_map_len],
        );
    }

    for (0..n_pipes) |pi| {
        _ = fx.close(pipe_fds[pi].read_fd);
        _ = fx.close(pipe_fds[pi].write_fd);
    }

    for (0..n_stages) |si| {
        if (pids[si] >= 0) {
            const status = fx.wait(@intCast(pids[si]));
            if (si == n_stages - 1) {
                last_exit_status = @truncate(status);
            }
        }
    }

    // Close redirect fds after all children finish
    for (0..n_stages) |si| closeRedirFds(&redir[si]);
}

// ── Command dispatch ───────────────────────────────────────────────

const RedirFds = struct {
    fd_map: [5]fx.FdMapping = undefined,
    fd_map_len: usize = 0,
    in_fd: i32 = -1,
    out_fd: i32 = -1,
    err_fd: i32 = -1,
    ok: bool = true,
};

fn openRedirFds(stage: *const Stage) RedirFds {
    var r = RedirFds{};

    if (stage.redir_in) |path| {
        r.in_fd = fx.open(path);
        if (r.in_fd < 0) {
            out.print("fsh: {s}: not found\n", .{path});
            r.ok = false;
            return r;
        }
        r.fd_map[r.fd_map_len] = .{ .child_fd = 0, .parent_fd = @intCast(r.in_fd) };
        r.fd_map_len += 1;
    }

    if (stage.redir_out) |path| {
        const flags: u32 = if (stage.redir_out_append) 2 else 0;
        r.out_fd = fx.create(path, flags);
        if (r.out_fd < 0) {
            out.print("fsh: {s}: create failed\n", .{path});
            r.ok = false;
            closeRedirFds(&r);
            return r;
        }
        r.fd_map[r.fd_map_len] = .{ .child_fd = 1, .parent_fd = @intCast(r.out_fd) };
        r.fd_map_len += 1;
    }

    if (stage.redir_err) |path| {
        const flags: u32 = if (stage.redir_err_append) 2 else 0;
        r.err_fd = fx.create(path, flags);
        if (r.err_fd < 0) {
            out.print("fsh: {s}: create failed\n", .{path});
            r.ok = false;
            closeRedirFds(&r);
            return r;
        }
        r.fd_map[r.fd_map_len] = .{ .child_fd = 2, .parent_fd = @intCast(r.err_fd) };
        r.fd_map_len += 1;
    }

    return r;
}

fn closeRedirFds(r: *const RedirFds) void {
    if (r.in_fd >= 0) _ = fx.close(r.in_fd);
    if (r.out_fd >= 0) _ = fx.close(r.out_fd);
    if (r.err_fd >= 0) _ = fx.close(r.err_fd);
}

fn builtinTest(is_bracket: bool, args_in: []const []const u8) void {
    var args = args_in;

    // [ requires closing ]
    if (is_bracket) {
        if (args.len == 0 or !fx.str.eql(args[args.len - 1], "]")) {
            out.puts("fsh: [: missing ]\n");
            last_exit_status = 2;
            return;
        }
        args = args[0 .. args.len - 1];
    }

    if (args.len == 0) {
        last_exit_status = 1;
        return;
    }

    // test -f path (file/dir exists)
    if (args.len >= 2 and (fx.str.eql(args[0], "-f") or fx.str.eql(args[0], "-d"))) {
        const fd = fx.open(args[1]);
        if (fd >= 0) {
            _ = fx.close(fd);
            last_exit_status = 0;
        } else {
            last_exit_status = 1;
        }
        return;
    }

    // test str1 = str2
    if (args.len >= 3 and fx.str.eql(args[1], "=")) {
        last_exit_status = if (fx.str.eql(args[0], args[2])) 0 else 1;
        return;
    }

    // test str1 != str2
    if (args.len >= 3 and fx.str.eql(args[1], "!=")) {
        last_exit_status = if (!fx.str.eql(args[0], args[2])) 0 else 1;
        return;
    }

    // test -n str (non-empty)
    if (args.len >= 2 and fx.str.eql(args[0], "-n")) {
        last_exit_status = if (args[1].len > 0) 0 else 1;
        return;
    }

    // test -z str (empty)
    if (args.len >= 2 and fx.str.eql(args[0], "-z")) {
        last_exit_status = if (args[1].len == 0) 0 else 1;
        return;
    }

    // test string (true if non-empty)
    last_exit_status = if (args[0].len > 0) 0 else 1;
}

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
        const cmd = stage.cmd;
        const has_redir = stage.redir_in != null or stage.redir_out != null or stage.redir_err != null;

        // Dispatch builtins (no redirect support for builtins)
        if (!has_redir) {
            if (fx.str.eql(cmd, "exit")) {
                if (stage.argc > 0) {
                    if (fx.str.parseUint(stage.args[0])) |code| {
                        fx.exit(@intCast(code));
                    }
                }
                fx.exit(0);
            } else if (fx.str.eql(cmd, "echo")) {
                builtinEcho(stage.args[0..stage.argc]);
                return;
            } else if (fx.str.eql(cmd, "clear")) {
                builtinClear();
                return;
            } else if (fx.str.eql(cmd, "help")) {
                builtinHelp();
                return;
            } else if (fx.str.eql(cmd, "cd")) {
                builtinCd(stage.args[0..stage.argc]);
                return;
            } else if (fx.str.eql(cmd, "pwd")) {
                builtinPwd();
                return;
            } else if (fx.str.eql(cmd, "set")) {
                builtinSet();
                return;
            } else if (fx.str.eql(cmd, "unset")) {
                builtinUnset(stage.args[0..stage.argc]);
                return;
            } else if (fx.str.eql(cmd, "source")) {
                builtinSource(stage.args[0..stage.argc]);
                return;
            } else if (fx.str.eql(cmd, "true")) {
                last_exit_status = 0;
                return;
            } else if (fx.str.eql(cmd, "false")) {
                last_exit_status = 1;
                return;
            } else if (fx.str.eql(cmd, "alias")) {
                builtinAlias(stage.args[0..stage.argc]);
                return;
            } else if (fx.str.eql(cmd, "unalias")) {
                builtinUnalias(stage.args[0..stage.argc]);
                return;
            } else if (fx.str.eql(cmd, "export")) {
                builtinExport(stage.args[0..stage.argc]);
                return;
            } else if (fx.str.eql(cmd, "test")) {
                builtinTest(false, stage.args[0..stage.argc]);
                return;
            } else if (fx.str.eql(cmd, "[")) {
                builtinTest(true, stage.args[0..stage.argc]);
                return;
            }
        }

        // Command aliases
        const actual_cmd = if (fx.str.eql(cmd, "vi")) "fe" else cmd;

        // External command with optional redirects
        var r = openRedirFds(stage);
        if (!r.ok) {
            last_exit_status = 1;
            return;
        }

        const pid = runExternalWithFds(actual_cmd, stage.args[0..stage.argc], r.fd_map[0..r.fd_map_len]);

        if (pid >= 0) {
            const status = fx.wait(@intCast(pid));
            last_exit_status = @truncate(status);
        }

        // Close redirect fds AFTER wait — closing before wait races with
        // the child's use of the same IPC channel (T_CLOSE frees the server
        // handle, and the channel's single client endpoint gets clobbered).
        closeRedirFds(&r);
    } else {
        runPipeline(&stages, n_stages);
    }
}

// ── Line processing ────────────────────────────────────────────────

fn expandAlias(line: []const u8, buf: *[1024]u8) ?[]const u8 {
    // Skip leading whitespace
    var start: usize = 0;
    while (start < line.len and (line[start] == ' ' or line[start] == '\t')) : (start += 1) {}
    if (start >= line.len) return null;

    // Find end of first word
    var end: usize = start;
    while (end < line.len and line[end] != ' ' and line[end] != '\t' and
        line[end] != ';' and line[end] != '|' and line[end] != '<' and line[end] != '>') : (end += 1)
    {}

    const word = line[start..end];
    if (word.len == 0) return null;

    const value = aliasGet(word) orelse return null;

    // Build: leading_ws + value + rest_of_line
    const rest = line[end..];
    const total = start + value.len + rest.len;
    if (total > buf.len) return null;

    @memcpy(buf[0..start], line[0..start]);
    @memcpy(buf[start..][0..value.len], value);
    @memcpy(buf[start + value.len ..][0..rest.len], rest);
    return buf[0..total];
}

fn processLine(line: []const u8) void {
    const saved_pos = token_storage_pos;
    defer token_storage_pos = saved_pos;

    // Alias expansion: find first word, check alias table, substitute
    var expanded_buf: [1024]u8 = undefined;
    const actual_line = expandAlias(line, &expanded_buf) orelse line;

    var tokens: [64][]const u8 = undefined;
    const argc = shellTokenize(actual_line, &tokens);
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

// ── Control flow helpers ────────────────────────────────────────────

fn isSeparator(tok: []const u8) bool {
    return fx.str.eql(tok, ";") or fx.str.eql(tok, "&&") or fx.str.eql(tok, "||");
}

/// Find a control-flow keyword at nesting depth 0.
/// if/while increase depth, fi/done decrease depth.
fn findControlKeyword(tokens: []const []const u8, start: usize, keyword: []const u8) ?usize {
    var depth: usize = 0;
    var i = start;
    while (i < tokens.len) : (i += 1) {
        if (depth == 0 and fx.str.eql(tokens[i], keyword)) {
            return i;
        }
        if (fx.str.eql(tokens[i], "if") or fx.str.eql(tokens[i], "while")) {
            depth += 1;
        } else if (fx.str.eql(tokens[i], "fi") or fx.str.eql(tokens[i], "done")) {
            if (depth > 0) depth -= 1;
        }
    }
    return null;
}

fn handleIf(tokens: []const []const u8, pos: *usize) void {
    const if_pos = pos.*;

    const then_pos = findControlKeyword(tokens, if_pos + 1, "then") orelse {
        out.puts("fsh: syntax error: missing 'then'\n");
        last_exit_status = 2;
        pos.* = tokens.len;
        return;
    };

    const fi_pos = findControlKeyword(tokens, then_pos + 1, "fi") orelse {
        out.puts("fsh: syntax error: missing 'fi'\n");
        last_exit_status = 2;
        pos.* = tokens.len;
        return;
    };

    var else_pos: ?usize = findControlKeyword(tokens, then_pos + 1, "else");
    if (else_pos) |ep| {
        if (ep >= fi_pos) else_pos = null;
    }

    // Condition: tokens between if and then, stripping ; before then
    var cond_end = then_pos;
    if (cond_end > if_pos + 1 and fx.str.eql(tokens[cond_end - 1], ";")) cond_end -= 1;

    if (cond_end > if_pos + 1) {
        executeTokens(tokens[if_pos + 1 .. cond_end]);
    }

    if (last_exit_status == 0) {
        // Execute then-body
        const body_end = else_pos orelse fi_pos;
        executeTokens(tokens[then_pos + 1 .. body_end]);
    } else if (else_pos) |ep| {
        // Execute else-body
        executeTokens(tokens[ep + 1 .. fi_pos]);
    }

    pos.* = fi_pos + 1;
}

fn handleWhile(tokens: []const []const u8, pos: *usize) void {
    const while_pos = pos.*;

    const do_pos = findControlKeyword(tokens, while_pos + 1, "do") orelse {
        out.puts("fsh: syntax error: missing 'do'\n");
        last_exit_status = 2;
        pos.* = tokens.len;
        return;
    };

    const done_pos = findControlKeyword(tokens, do_pos + 1, "done") orelse {
        out.puts("fsh: syntax error: missing 'done'\n");
        last_exit_status = 2;
        pos.* = tokens.len;
        return;
    };

    // Condition: tokens between while and do, stripping ; before do
    var cond_end = do_pos;
    if (cond_end > while_pos + 1 and fx.str.eql(tokens[cond_end - 1], ";")) cond_end -= 1;

    const body = tokens[do_pos + 1 .. done_pos];

    var iterations: usize = 0;
    while (iterations < 10000) : (iterations += 1) {
        if (cond_end > while_pos + 1) {
            executeTokens(tokens[while_pos + 1 .. cond_end]);
        }
        if (last_exit_status != 0) break;
        executeTokens(body);
    }

    pos.* = done_pos + 1;
}

fn skipBlock(tokens: []const []const u8, pos: *usize, closer: []const u8) void {
    const end = findControlKeyword(tokens, pos.* + 1, closer);
    pos.* = if (end) |ep| ep + 1 else tokens.len;
}

fn executeTokens(tokens: []const []const u8) void {
    var i: usize = 0;
    var should_exec = true;

    while (i < tokens.len) {
        // Handle separators
        if (fx.str.eql(tokens[i], ";")) {
            should_exec = true;
            i += 1;
            continue;
        }
        if (fx.str.eql(tokens[i], "&&")) {
            should_exec = (last_exit_status == 0);
            i += 1;
            continue;
        }
        if (fx.str.eql(tokens[i], "||")) {
            should_exec = (last_exit_status != 0);
            i += 1;
            continue;
        }

        // Handle control flow blocks
        if (fx.str.eql(tokens[i], "if")) {
            if (should_exec) {
                handleIf(tokens, &i);
            } else {
                skipBlock(tokens, &i, "fi");
            }
            should_exec = true;
            continue;
        }
        if (fx.str.eql(tokens[i], "while")) {
            if (should_exec) {
                handleWhile(tokens, &i);
            } else {
                skipBlock(tokens, &i, "done");
            }
            should_exec = true;
            continue;
        }

        // Find end of command (next separator)
        var end = i;
        while (end < tokens.len) : (end += 1) {
            if (isSeparator(tokens[end])) break;
        }

        if (should_exec and end > i) {
            executeLine(tokens[i..end]);
        }
        i = end;
    }
}

// ── Entry point ────────────────────────────────────────────────────

var prompt_buf: [64]u8 = undefined;

fn buildPrompt() []const u8 {
    var pos: usize = 0;
    const user = envGet("USER") orelse "?";
    if (pos + user.len > prompt_buf.len) return "$ ";
    @memcpy(prompt_buf[pos..][0..user.len], user);
    pos += user.len;

    const suffix = "@fornax";
    if (pos + suffix.len > prompt_buf.len) return "$ ";
    @memcpy(prompt_buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;

    // # for root, $ for regular users
    const trail: []const u8 = if (fx.getuid() == 0) "# " else "$ ";
    if (pos + trail.len > prompt_buf.len) return "$ ";
    @memcpy(prompt_buf[pos..][0..trail.len], trail);
    pos += trail.len;

    return prompt_buf[0..pos];
}

export fn _start() noreturn {
    builtinClear();
    out.puts("fsh: Fornax shell\n");
    envInit();
    aliasInit();

    while (true) {
        const line = editLine(buildPrompt()) orelse break;
        if (line.len == 0) continue;
        processLine(line);
    }

    fx.exit(0);
}
