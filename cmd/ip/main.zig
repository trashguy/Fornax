const fx = @import("fornax");

const out = fx.io.Writer.stdout;
const err = fx.io.Writer.stderr;

export fn _start() noreturn {
    const fd = fx.open("/net/status");
    if (fd < 0) {
        err.puts("ip: cannot open /net/status\n");
        fx.exit(1);
    }

    var buf: [256]u8 = undefined;
    const n = fx.read(fd, &buf);
    _ = fx.close(fd);

    if (n > 0) {
        _ = fx.write(1, buf[0..@intCast(n)]);
    }

    fx.exit(0);
}
