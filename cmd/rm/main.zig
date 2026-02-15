/// rm — remove files.
const fx = @import("fornax");

const err = fx.io.Writer.stderr;

export fn _start() noreturn {
    const args = fx.getArgs();

    if (args.len <= 1) {
        err.puts("usage: rm file...\n");
        fx.exit(1);
    }

    for (args[1..]) |arg| {
        var len: usize = 0;
        while (arg[len] != 0) : (len += 1) {}
        const name = arg[0..len];

        const result = fx.remove(name);
        if (result < 0) {
            err.print("rm: {s}: failed\n", .{name});
        }
    }

    fx.exit(0);
}
