/// date — print or set system date and time.
///
/// Usage:
///   date            — "Sat Feb 22 14:30:05 UTC 2026"
///   date -u         — same (always UTC)
///   date -R         — RFC 2822: "Sat, 22 Feb 2026 14:30:05 +0000"
///   date -I         — ISO 8601: "2026-02-22"
///   date +%s        — epoch seconds only
///   date -s EPOCH   — set system clock (root only)
const fx = @import("fornax");
const out = fx.io.Writer.stdout;

export fn _start() noreturn {
    const args = fx.getArgs();

    if (args.len >= 2) {
        const arg = span(args[1]);

        // date +%s
        if (eql(arg, "+%s")) {
            printEpoch();
            fx.exit(0);
        }

        // date -s EPOCH
        if (eql(arg, "-s")) {
            if (args.len < 3) {
                _ = fx.write(2, "date: -s requires epoch value\n");
                fx.exit(1);
            }
            setTime(span(args[2]));
            fx.exit(0);
        }

        // date -R (RFC 2822)
        if (eql(arg, "-R")) {
            printRfc2822();
            fx.exit(0);
        }

        // date -I (ISO 8601 date only)
        if (eql(arg, "-I")) {
            printIso8601();
            fx.exit(0);
        }

        // date -u (same as default, always UTC)
        if (!eql(arg, "-u")) {
            _ = fx.write(2, "date: unknown option\n");
            fx.exit(1);
        }
    }

    // Default: Unix-standard format
    printDefault();
    fx.exit(0);
}

fn printDefault() void {
    const epoch = fx.time();
    if (epoch == 0) {
        out.puts("date: no clock available\n");
        return;
    }
    const dt = fx.time_lib.fromEpoch(epoch);

    // "Sat Feb 22 14:30:05 UTC 2026"
    out.puts(fx.time_lib.dowName(dt.dow));
    out.puts(" ");
    out.puts(fx.time_lib.monthName(dt.month));
    out.puts(" ");
    var day_buf: [4]u8 = undefined;
    out.puts(fmtPad2(dt.day, &day_buf));
    out.puts(" ");
    var time_buf: [8]u8 = undefined;
    out.puts(fx.time_lib.fmtTime(dt, &time_buf));
    out.puts(" UTC ");
    var year_buf: [8]u8 = undefined;
    out.puts(fx.fmt.formatDec(&year_buf, dt.year));
    out.puts("\n");
}

fn printRfc2822() void {
    const epoch = fx.time();
    if (epoch == 0) {
        out.puts("date: no clock available\n");
        return;
    }
    const dt = fx.time_lib.fromEpoch(epoch);

    // "Sat, 22 Feb 2026 14:30:05 +0000"
    out.puts(fx.time_lib.dowName(dt.dow));
    out.puts(", ");
    var day_buf: [4]u8 = undefined;
    out.puts(fmtPad2(dt.day, &day_buf));
    out.puts(" ");
    out.puts(fx.time_lib.monthName(dt.month));
    out.puts(" ");
    var year_buf: [8]u8 = undefined;
    out.puts(fx.fmt.formatDec(&year_buf, dt.year));
    out.puts(" ");
    var time_buf: [8]u8 = undefined;
    out.puts(fx.time_lib.fmtTime(dt, &time_buf));
    out.puts(" +0000\n");
}

fn printIso8601() void {
    const epoch = fx.time();
    if (epoch == 0) {
        out.puts("date: no clock available\n");
        return;
    }
    const dt = fx.time_lib.fromEpoch(epoch);
    var buf: [10]u8 = undefined;
    out.puts(fx.time_lib.fmtDate(dt, &buf));
    out.puts("\n");
}

fn printEpoch() void {
    const epoch = fx.time();
    var buf: [20]u8 = undefined;
    out.puts(fx.fmt.formatDec(&buf, epoch));
    out.puts("\n");
}

fn setTime(val_str: []const u8) void {
    const fd = fx.open("/dev/time");
    if (fd < 0) {
        _ = fx.write(2, "date: cannot open /dev/time\n");
        fx.exit(1);
    }
    const written = fx.write(fd, val_str);
    _ = fx.close(fd);
    if (written < 0) {
        _ = fx.write(2, "date: permission denied\n");
        fx.exit(1);
    }
}

/// Format a number with leading zero if < 10 (for day display).
fn fmtPad2(val: u8, buf: *[4]u8) []const u8 {
    if (val < 10) {
        buf[0] = '0';
        buf[1] = '0' + val;
        return buf[0..2];
    }
    buf[0] = '0' + (val / 10);
    buf[1] = '0' + (val % 10);
    return buf[0..2];
}

fn eql(a: []const u8, b: []const u8) bool {
    return fx.str.eql(a, b);
}

fn span(ptr: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (ptr[len] != 0) len += 1;
    return ptr[0..len];
}
