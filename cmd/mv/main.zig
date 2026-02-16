const fx = @import("fornax");

const err = fx.io.Writer.stderr;

export fn _start() noreturn {
    const args = fx.getArgs();

    if (args.len != 3) {
        err.puts("usage: mv src dst\n");
        fx.exit(1);
    }

    const src = argSlice(args[1]);
    const dst = argSlice(args[2]);

    const result = fx.rename(src, dst);
    if (result < 0) {
        err.print("mv: rename failed: {s} -> {s}\n", .{ src, dst });
        fx.exit(1);
    }

    fx.exit(0);
}

fn argSlice(arg: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (arg[len] != 0) : (len += 1) {}
    return arg[0..len];
}
