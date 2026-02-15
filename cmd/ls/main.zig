/// ls — list directory contents.
///
/// No args: list /boot (default).
/// With args: list each path.
const fx = @import("fornax");

const out = fx.io.Writer.stdout;
const err = fx.io.Writer.stderr;

fn listDir(path: []const u8) void {
    const fd = fx.open(path);
    if (fd < 0) {
        err.print("ls: {s}: not found\n", .{path});
        return;
    }
    defer _ = fx.close(fd);

    var dir_buf: [4096]u8 = undefined;
    const n = fx.read(fd, &dir_buf);
    if (n <= 0) return;

    const bytes: usize = @intCast(n);
    const entry_size = @sizeOf(fx.DirEntry);
    var off: usize = 0;
    while (off + entry_size <= bytes) : (off += entry_size) {
        const entry: *const fx.DirEntry = @ptrCast(@alignCast(dir_buf[off..][0..entry_size]));
        // Extract null-terminated name
        const name = blk: {
            for (entry.name, 0..) |c, j| {
                if (c == 0) break :blk entry.name[0..j];
            }
            break :blk &entry.name;
        };
        if (entry.file_type == 1) {
            out.print("{s}/\n", .{name});
        } else {
            out.print("{s}\n", .{name});
        }
    }
}

export fn _start() noreturn {
    const args = fx.getArgs();

    if (args.len <= 1) {
        listDir("/boot");
    } else {
        for (args[1..]) |arg| {
            var len: usize = 0;
            while (arg[len] != 0) : (len += 1) {}
            listDir(arg[0..len]);
        }
    }

    fx.exit(0);
}
