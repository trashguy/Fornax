/// fsh — Fornax shell.
///
/// rc-inspired interactive shell. Reads commands from stdin, executes
/// builtins or spawns programs from /boot/<name>.
const fx = @import("fornax");

/// 4 MB buffer for loading ELF binaries (matches spawn syscall limit).
/// linksection forces this into .bss so it doesn't bloat the ELF file.
var elf_buf: [4 * 1024 * 1024]u8 linksection(".bss") = undefined;

fn puts(s: []const u8) void {
    _ = fx.write(1, s);
}

fn putc(c: u8) void {
    _ = fx.write(1, @as(*const [1]u8, &c));
}

/// Read a full line from stdin into buf. Returns the slice up to (not
/// including) the trailing newline character, or null on read error.
fn readLine(buf: []u8) ?[]const u8 {
    const n = fx.read(0, buf);
    if (n <= 0) return null;
    const len: usize = @intCast(n);
    // Strip trailing newline if present
    if (len > 0 and buf[len - 1] == '\n') return buf[0 .. len - 1];
    return buf[0..len];
}

/// Tokenize a line on whitespace. Returns number of tokens stored.
fn tokenize(line: []const u8, tokens: [][]const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < line.len and count < tokens.len) {
        // Skip whitespace
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
        if (i >= line.len) break;
        const start = i;
        // Find end of token
        while (i < line.len and line[i] != ' ' and line[i] != '\t') : (i += 1) {}
        tokens[count] = line[start..i];
        count += 1;
    }
    return count;
}

/// Check if two slices are equal.
fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (ac != bc) return false;
    }
    return true;
}

// ── Builtins ────────────────────────────────────────────────────────

fn builtinEcho(args: [][]const u8) void {
    for (args, 0..) |arg, i| {
        if (i > 0) putc(' ');
        puts(arg);
    }
    putc('\n');
}

fn builtinClear() void {
    // Scroll screen by printing newlines — no ANSI codes needed.
    var i: usize = 0;
    while (i < 50) : (i += 1) putc('\n');
}

fn builtinHelp() void {
    puts("fsh — Fornax shell\n");
    puts("builtins: echo  clear  help  exit\n");
    puts("programs:");

    // List /boot/ directory entries
    const fd = fx.open("/boot");
    if (fd < 0) {
        putc('\n');
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
            if (entry.file_type == 0) { // files only
                // Extract null-terminated name
                const name = blk: {
                    for (entry.name, 0..) |c, j| {
                        if (c == 0) break :blk entry.name[0..j];
                    }
                    break :blk &entry.name;
                };
                putc(' ');
                puts(name);
            }
        }
    }
    putc('\n');
}

// ── External command execution ──────────────────────────────────────

fn runExternal(name: []const u8) void {
    // Build path: "/boot/" ++ name
    var path_buf: [128]u8 = undefined;
    const prefix = "/boot/";
    if (prefix.len + name.len > path_buf.len) {
        puts("fsh: command name too long\n");
        return;
    }
    @memcpy(path_buf[0..prefix.len], prefix);
    @memcpy(path_buf[prefix.len..][0..name.len], name);
    const path = path_buf[0 .. prefix.len + name.len];

    // Open the file
    const fd = fx.open(path);
    if (fd < 0) {
        puts("fsh: ");
        puts(name);
        puts(": not found\n");
        return;
    }

    // Read ELF in 4KB chunks
    var total: usize = 0;
    while (total < elf_buf.len) {
        const n = fx.read(fd, elf_buf[total..]);
        if (n <= 0) break;
        total += @intCast(n);
    }
    _ = fx.close(fd);

    if (total == 0) {
        puts("fsh: ");
        puts(name);
        puts(": empty file\n");
        return;
    }

    // Spawn child and wait
    const pid = fx.spawn(elf_buf[0..total], &.{});
    if (pid < 0) {
        puts("fsh: ");
        puts(name);
        puts(": spawn failed\n");
        return;
    }
    _ = fx.wait(@intCast(pid));
}

// ── Main shell loop ─────────────────────────────────────────────────

export fn _start() noreturn {
    puts("fsh: Fornax shell\n");

    while (true) {
        puts("fornax% ");

        var line_buf: [256]u8 = undefined;
        const line = readLine(&line_buf) orelse break;

        // Skip empty lines
        if (line.len == 0) continue;

        // Tokenize
        var tokens: [64][]const u8 = undefined;
        const argc = tokenize(line, &tokens);
        if (argc == 0) continue;

        const cmd = tokens[0];
        const args = tokens[1..argc];

        // Dispatch builtins
        if (strEql(cmd, "exit")) {
            fx.exit(0);
        } else if (strEql(cmd, "echo")) {
            builtinEcho(args);
        } else if (strEql(cmd, "clear")) {
            builtinClear();
        } else if (strEql(cmd, "help")) {
            builtinHelp();
        } else {
            runExternal(cmd);
        }
    }

    fx.exit(0);
}
