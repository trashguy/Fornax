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

    // Build entire output in one buffer, single write — avoids riscv64 codegen
    // issues with repeated slice-returning function calls + syscalls.
    const dow_tbl = [7][3]u8{
        .{ 'S', 'u', 'n' }, .{ 'M', 'o', 'n' }, .{ 'T', 'u', 'e' },
        .{ 'W', 'e', 'd' }, .{ 'T', 'h', 'u' }, .{ 'F', 'r', 'i' },
        .{ 'S', 'a', 't' },
    };
    const mon_tbl = [12][3]u8{
        .{ 'J', 'a', 'n' }, .{ 'F', 'e', 'b' }, .{ 'M', 'a', 'r' },
        .{ 'A', 'p', 'r' }, .{ 'M', 'a', 'y' }, .{ 'J', 'u', 'n' },
        .{ 'J', 'u', 'l' }, .{ 'A', 'u', 'g' }, .{ 'S', 'e', 'p' },
        .{ 'O', 'c', 't' }, .{ 'N', 'o', 'v' }, .{ 'D', 'e', 'c' },
    };

    var buf: [30]u8 = undefined;
    const di = dt.dow % 7;
    buf[0] = dow_tbl[di][0];
    buf[1] = dow_tbl[di][1];
    buf[2] = dow_tbl[di][2];
    buf[3] = ' ';
    const mi = if (dt.month >= 1 and dt.month <= 12) dt.month - 1 else 0;
    buf[4] = mon_tbl[mi][0];
    buf[5] = mon_tbl[mi][1];
    buf[6] = mon_tbl[mi][2];
    buf[7] = ' ';
    buf[8] = if (dt.day < 10) ' ' else '0' + dt.day / 10;
    buf[9] = '0' + dt.day % 10;
    buf[10] = ' ';
    buf[11] = '0' + dt.hour / 10;
    buf[12] = '0' + dt.hour % 10;
    buf[13] = ':';
    buf[14] = '0' + dt.minute / 10;
    buf[15] = '0' + dt.minute % 10;
    buf[16] = ':';
    buf[17] = '0' + dt.second / 10;
    buf[18] = '0' + dt.second % 10;
    buf[19] = ' ';
    buf[20] = 'U';
    buf[21] = 'T';
    buf[22] = 'C';
    buf[23] = ' ';
    const y = dt.year;
    buf[24] = '0' + @as(u8, @intCast(y / 1000));
    buf[25] = '0' + @as(u8, @intCast((y / 100) % 10));
    buf[26] = '0' + @as(u8, @intCast((y / 10) % 10));
    buf[27] = '0' + @as(u8, @intCast(y % 10));
    buf[28] = '\n';
    _ = fx.write(1, buf[0..29]);
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
