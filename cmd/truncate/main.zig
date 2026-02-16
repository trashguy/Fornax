const fx = @import("fornax");

const err = fx.io.Writer.stderr;

export fn _start() noreturn {
    const args = fx.getArgs();

    if (args.len < 2 or args.len > 3) {
        err.puts("usage: truncate file [size]\n");
        fx.exit(1);
    }

    const path = argSlice(args[1]);
    const size: u64 = if (args.len == 3) parseSize(argSlice(args[2])) else 0;

    const fd = fx.open(path);
    if (fd < 0) {
        err.print("truncate: {s}: cannot open\n", .{path});
        fx.exit(1);
    }

    const result = fx.truncate(fd, size);
    _ = fx.close(fd);

    if (result < 0) {
        err.print("truncate: {s}: failed\n", .{path});
        fx.exit(1);
    }

    fx.exit(0);
}

fn parseSize(s: []const u8) u64 {
    var n: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') break;
        n = n * 10 + (c - '0');
    }
    return n;
}

fn argSlice(arg: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (arg[len] != 0) : (len += 1) {}
    return arg[0..len];
}
