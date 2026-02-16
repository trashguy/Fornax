const fx = @import("fornax");

const err = fx.io.Writer.stderr;

export fn _start() noreturn {
    const args = fx.getArgs();

    if (args.len <= 1) {
        err.puts("usage: touch file...\n");
        fx.exit(1);
    }

    for (args[1..]) |arg| {
        var len: usize = 0;
        while (arg[len] != 0) : (len += 1) {}
        const name = arg[0..len];

        const fd = fx.open(name);
        if (fd >= 0) {
            // File exists, just close it
            _ = fx.close(fd);
        } else {
            // Create it
            const cfd = fx.create(name, 0);
            if (cfd < 0) {
                err.print("touch: {s}: cannot create\n", .{name});
                continue;
            }
            _ = fx.close(cfd);
        }
    }

    fx.exit(0);
}
