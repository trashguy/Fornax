const fx = @import("fornax");

const err = fx.io.Writer.stderr;

export fn _start() noreturn {
    const args = fx.getArgs();

    if (args.len != 3) {
        err.puts("usage: chmod mode file\n");
        fx.exit(1);
    }

    const mode = parseOctal(argSlice(args[1]));
    const path = argSlice(args[2]);

    const fd = fx.open(path);
    if (fd < 0) {
        err.print("chmod: {s}: cannot open\n", .{path});
        fx.exit(1);
    }

    const result = fx.wstat(fd, @truncate(mode), 0, 0, fx.WSTAT_MODE);
    _ = fx.close(fd);

    if (result < 0) {
        err.print("chmod: {s}: failed\n", .{path});
        fx.exit(1);
    }

    fx.exit(0);
}

fn parseOctal(s: []const u8) u32 {
    var n: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '7') break;
        n = n * 8 + (c - '0');
    }
    return n;
}

fn argSlice(arg: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (arg[len] != 0) : (len += 1) {}
    return arg[0..len];
}
