/// ktrace — display kernel trace buffer.
///
/// Reads /dev/trace and prints structured trace events (syscalls, IRQs,
/// context switches, IPC) with RDTSC timestamps, grouped by core.
const fx = @import("fornax");
const out = fx.io.Writer.stdout;

export fn _start() noreturn {
    const fd = fx.open("/dev/trace");
    if (fd < 0) {
        out.puts("ktrace: cannot open /dev/trace\n");
        fx.exit(1);
    }

    out.puts("TIMESTAMP        EVENT      PID  DATA\n");

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = fx.read(fd, &buf);
        if (n <= 0) break;
        const slice: []const u8 = buf[0..@intCast(n)];
        out.puts(slice);
    }

    _ = fx.close(fd);
    fx.exit(0);
}
