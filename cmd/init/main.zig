/// Fornax init — PID 1 (well, PID 2 now — ramfs is PID 1).
///
/// Interactive console test: reads lines from stdin and echoes them back.
const fx = @import("fornax");

fn putDec(val: u32) void {
    if (val >= 10) putDec(val / 10);
    const digit: [1]u8 = .{'0' + @as(u8, @truncate(val % 10))};
    _ = fx.write(1, &digit);
}

fn putI32(val: i32) void {
    if (val < 0) {
        _ = fx.write(1, "-");
        putDec(@intCast(-val));
    } else {
        putDec(@intCast(val));
    }
}

export fn _start() noreturn {
    _ = fx.write(1, "init: started\n");
    _ = fx.write(1, "Type something and press Enter:\n");

    // Read-echo loop: read from stdin, echo to stdout
    while (true) {
        _ = fx.write(1, "> ");
        var buf: [256]u8 = undefined;
        const n = fx.read(0, &buf);
        if (n <= 0) {
            _ = fx.write(1, "init: read returned ");
            putI32(@intCast(n));
            _ = fx.write(1, "\n");
            break;
        }
        _ = fx.write(1, "You typed: ");
        _ = fx.write(1, buf[0..@intCast(n)]);
    }

    _ = fx.write(1, "init: done\n");
    fx.exit(0);
}
