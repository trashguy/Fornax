const fx = @import("fornax");

const err = fx.io.Writer.stderr;

export fn _start() noreturn {
    const args = fx.getArgs();

    if (args.len != 3) {
        err.puts("usage: cp src dst\n");
        fx.exit(1);
    }

    const src = argSlice(args[1]);
    const dst = argSlice(args[2]);

    const src_fd = fx.open(src);
    if (src_fd < 0) {
        err.print("cp: {s}: not found\n", .{src});
        fx.exit(1);
    }

    const dst_fd = fx.create(dst, 0);
    if (dst_fd < 0) {
        err.print("cp: {s}: cannot create\n", .{dst});
        _ = fx.close(src_fd);
        fx.exit(1);
    }

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = fx.read(src_fd, &buf);
        if (n <= 0) break;
        _ = fx.write(dst_fd, buf[0..@intCast(n)]);
    }

    _ = fx.close(src_fd);
    _ = fx.close(dst_fd);
    fx.exit(0);
}

fn argSlice(arg: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (arg[len] != 0) : (len += 1) {}
    return arg[0..len];
}
