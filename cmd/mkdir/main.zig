/// mkdir — create directories.
const fx = @import("fornax");

const err = fx.io.Writer.stderr;

export fn _start() noreturn {
    const args = fx.getArgs();

    if (args.len <= 1) {
        err.puts("usage: mkdir dir...\n");
        fx.exit(1);
    }

    for (args[1..]) |arg| {
        var len: usize = 0;
        while (arg[len] != 0) : (len += 1) {}
        const name = arg[0..len];

        const result = fx.mkdir(name);
        if (result < 0) {
            err.print("mkdir: {s}: failed\n", .{name});
        }
    }

    fx.exit(0);
}
