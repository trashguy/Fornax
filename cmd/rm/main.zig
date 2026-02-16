/// rm — remove files or directories.
///
/// -f  force: skip confirmation prompts, suppress errors.
/// -r  recursive: remove directories and their contents.
const fx = @import("fornax");

const out = fx.io.Writer.stdout;
const err = fx.io.Writer.stderr;

var recursive = false;
var force = false;

export fn _start() noreturn {
    const args = fx.getArgs();

    if (args.len <= 1) {
        err.puts("usage: rm [-rf] file...\n");
        fx.exit(1);
    }

    var start: usize = 1;
    for (args[1..]) |arg| {
        const a = argSlice(arg);
        if (a.len > 0 and a[0] == '-') {
            start += 1;
            for (a[1..]) |ch| {
                if (ch == 'r') {
                    recursive = true;
                } else if (ch == 'f') {
                    force = true;
                } else {
                    err.print("rm: unknown option: -{c}\n", .{ch});
                    fx.exit(1);
                }
            }
        } else break;
    }

    if (start >= args.len) {
        err.puts("usage: rm [-rf] file...\n");
        fx.exit(1);
    }

    for (args[start..]) |arg| {
        const name = argSlice(arg);
        removeOne(name);
    }

    fx.exit(0);
}

fn confirm(path: []const u8, is_dir: bool) bool {
    if (force) return true;
    if (is_dir) {
        err.print("rm: remove directory '{s}'? ", .{path});
    } else {
        err.print("rm: remove '{s}'? ", .{path});
    }
    var buf: [16]u8 = undefined;
    const n = fx.read(0, &buf);
    if (n <= 0) return false;
    return buf[0] == 'y' or buf[0] == 'Y';
}

fn removeOne(path: []const u8) void {
    if (recursive) {
        const fd = fx.open(path);
        if (fd < 0) {
            if (!force) err.print("rm: {s}: not found\n", .{path});
            return;
        }
        var st: fx.Stat = undefined;
        const sr = fx.stat(fd, &st);
        _ = fx.close(fd);

        if (sr >= 0 and st.file_type == 1) {
            if (confirm(path, true)) removeDir(path);
            return;
        }
    }

    if (!confirm(path, false)) return;

    const result = fx.remove(path);
    if (result < 0 and !force) {
        err.print("rm: {s}: failed\n", .{path});
    }
}

fn removeDir(path: []const u8) void {
    const fd = fx.open(path);
    if (fd < 0) return;

    var dir_buf: [4096]u8 = undefined;
    const n = fx.read(fd, &dir_buf);
    _ = fx.close(fd);

    if (n > 0) {
        const bytes: usize = @intCast(n);
        const entry_size = @sizeOf(fx.DirEntry);
        var off: usize = 0;
        while (off + entry_size <= bytes) : (off += entry_size) {
            const entry: *const fx.DirEntry = @ptrCast(@alignCast(dir_buf[off..][0..entry_size]));
            const name = entryName(entry);
            if (name.len == 0) continue;

            var child: [256]u8 = undefined;
            if (path.len + 1 + name.len >= child.len) continue;
            @memcpy(child[0..path.len], path);
            child[path.len] = '/';
            @memcpy(child[path.len + 1 ..][0..name.len], name);
            const child_path = child[0 .. path.len + 1 + name.len];

            if (entry.file_type == 1) {
                removeDir(child_path);
            } else {
                const r = fx.remove(child_path);
                if (r < 0 and !force) {
                    err.print("rm: {s}: failed\n", .{child_path});
                }
            }
        }
    }

    const result = fx.remove(path);
    if (result < 0 and !force) {
        err.print("rm: {s}: failed\n", .{path});
    }
}

fn entryName(entry: *const fx.DirEntry) []const u8 {
    for (entry.name, 0..) |c, j| {
        if (c == 0) return entry.name[0..j];
    }
    return &entry.name;
}

fn argSlice(arg: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (arg[len] != 0) : (len += 1) {}
    return arg[0..len];
}
