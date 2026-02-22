/// uptime — show system uptime.
///
/// Usage:
///   uptime      — print uptime in "Xd Xh Xm Xs" format
///   uptime -s   — print uptime in seconds only
const fx = @import("fornax");
const out = fx.io.Writer.stdout;

export fn _start() noreturn {
    const args = fx.getArgs();
    const up = fx.getUptime();

    // uptime -s — seconds only
    if (args.len >= 2) {
        const arg = span(args[1]);
        if (fx.str.eql(arg, "-s")) {
            var buf: [20]u8 = undefined;
            out.puts(fx.fmt.formatDec(&buf, up));
            out.puts("\n");
            fx.exit(0);
        }
    }

    // Default: formatted uptime
    out.puts("up ");
    var buf: [64]u8 = undefined;
    out.puts(fx.time_lib.fmtUptime(up, &buf));
    out.puts("\n");
    fx.exit(0);
}

fn span(ptr: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (ptr[len] != 0) len += 1;
    return ptr[0..len];
}
