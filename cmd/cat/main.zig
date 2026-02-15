/// cat — concatenate and print files.
///
/// No args: read stdin → stdout (for use in pipes).
/// With args: for each filename, open → read → stdout → close.
const fx = @import("fornax");

const out = fx.io.Writer.stdout;
const err = fx.io.Writer.stderr;

export fn _start() noreturn {
    const args = fx.getArgs();

    if (args.len <= 1) {
        // No file args — copy stdin to stdout
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = fx.read(0, &buf);
            if (n <= 0) break;
            _ = fx.write(1, buf[0..@intCast(n)]);
        }
    } else {
        for (args[1..]) |arg| {
            var len: usize = 0;
            while (arg[len] != 0) : (len += 1) {}
            const name = arg[0..len];

            const fd = fx.open(name);
            if (fd < 0) {
                err.print("cat: {s}: not found\n", .{name});
                continue;
            }

            var buf: [4096]u8 = undefined;
            while (true) {
                const n = fx.read(fd, &buf);
                if (n <= 0) break;
                _ = fx.write(1, buf[0..@intCast(n)]);
            }
            _ = fx.close(fd);
        }
    }

    fx.exit(0);
}
