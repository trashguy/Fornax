const fx = @import("fornax");
const out = fx.io.Writer.stdout;
const err = fx.io.Writer.stderr;

const MAX_DEPTH = 16;

export fn _start() noreturn {
    const args = fx.getArgs();

    if (args.len <= 1) {
        out.puts(".\n");
        const counts = printTree("/", 0);
        out.print("\n{d} directories, {d} files\n", .{ counts[0], counts[1] });
    } else {
        for (args[1..]) |arg| {
            var len: usize = 0;
            while (arg[len] != 0) : (len += 1) {}
            const path = arg[0..len];
            out.print("{s}\n", .{path});
            const counts = printTree(path, 0);
            out.print("\n{d} directories, {d} files\n", .{ counts[0], counts[1] });
        }
    }

    fx.exit(0);
}

/// Returns [dir_count, file_count]
fn printTree(dir_path: []const u8, depth: usize) [2]u64 {
    if (depth >= MAX_DEPTH) return .{ 0, 0 };

    const fd = fx.open(dir_path);
    if (fd < 0) return .{ 0, 0 };
    defer _ = fx.close(fd);

    var dir_buf: [4096]u8 = undefined;
    const n = fx.read(fd, &dir_buf);
    if (n <= 0) return .{ 0, 0 };

    const bytes: usize = @intCast(n);
    const entry_size = @sizeOf(fx.DirEntry);

    // Count entries first to know which is last
    var count: usize = 0;
    {
        var off: usize = 0;
        while (off + entry_size <= bytes) : (off += entry_size) {
            count += 1;
        }
    }

    var dirs: u64 = 0;
    var files: u64 = 0;
    var idx: usize = 0;
    var off: usize = 0;
    while (off + entry_size <= bytes) : (off += entry_size) {
        const entry: *const fx.DirEntry = @ptrCast(@alignCast(dir_buf[off..][0..entry_size]));
        const name = extractName(&entry.name);
        idx += 1;
        const is_last = (idx == count);

        // Print prefix for current depth
        var d: usize = 0;
        while (d < depth) : (d += 1) {
            out.puts("    ");
        }

        if (is_last) {
            out.puts("└── ");
        } else {
            out.puts("├── ");
        }

        if (entry.file_type == 1) {
            out.print("{s}/\n", .{name});
            dirs += 1;

            // Build child path and recurse
            var child = fx.path.PathBuf.from(dir_path);
            _ = child.appendRaw(name);
            const sub = printTree(child.slice(), depth + 1);
            dirs += sub[0];
            files += sub[1];
        } else {
            out.print("{s}\n", .{name});
            files += 1;
        }
    }

    return .{ dirs, files };
}

fn extractName(name: *const [64]u8) []const u8 {
    for (name, 0..) |c, j| {
        if (c == 0) return name[0..j];
    }
    return name;
}
