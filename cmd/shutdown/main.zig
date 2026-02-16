const fx = @import("fornax");
const out = fx.io.Writer.stdout;
const err_out = fx.io.Writer.stderr;

export fn _start() noreturn {
    const args = fx.getArgs();

    var do_reboot = false;
    var delay_minutes: u64 = 0;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = argStr(args[i]);

        if (fx.str.eql(arg, "-h")) {
            // poweroff (default), just consume
        } else if (fx.str.eql(arg, "-r")) {
            do_reboot = true;
        } else if (fx.str.eql(arg, "--help")) {
            out.puts("Usage: shutdown [-h|-r] [now|+N]\n");
            out.puts("  -h      Halt/poweroff (default)\n");
            out.puts("  -r      Reboot\n");
            out.puts("  now     Immediate (default)\n");
            out.puts("  +N      Delay N minutes\n");
            fx.exit(0);
        } else if (fx.str.eql(arg, "now")) {
            delay_minutes = 0;
        } else if (arg.len > 1 and arg[0] == '+') {
            delay_minutes = parseNum(arg[1..]) orelse {
                err_out.puts("shutdown: invalid time: ");
                err_out.puts(arg);
                err_out.putc('\n');
                fx.exit(1);
            };
        } else if (arg.len >= 3 and hasColon(arg)) {
            err_out.puts("shutdown: HH:MM format not supported, use +N\n");
            fx.exit(1);
        } else {
            err_out.puts("shutdown: unknown argument: ");
            err_out.puts(arg);
            err_out.putc('\n');
            fx.exit(1);
        }
    }

    const action = if (do_reboot) "reboot" else "poweroff";

    if (delay_minutes > 0) {
        out.puts("System going down for ");
        out.puts(action);
        out.puts(" in ");
        printNum(delay_minutes);
        out.puts(" minute(s)\n");
        fx.sleep(delay_minutes * 60 * 1000);
    }

    out.puts("System going down for ");
    out.puts(action);
    out.puts(" NOW\n");

    if (do_reboot) {
        fx.reboot();
    } else {
        fx.shutdown();
    }
}

fn argStr(ptr: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (ptr[len] != 0) : (len += 1) {}
    return ptr[0..len];
}

fn parseNum(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    var val: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        val = val * 10 + (c - '0');
    }
    return val;
}

fn hasColon(s: []const u8) bool {
    for (s) |c| {
        if (c == ':') return true;
    }
    return false;
}

fn printNum(n: u64) void {
    if (n == 0) {
        out.putc('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var len: usize = 0;
    var v = n;
    while (v > 0) : (v /= 10) {
        buf[len] = @intCast('0' + (v % 10));
        len += 1;
    }
    var j: usize = 0;
    while (j < len) : (j += 1) {
        out.putc(buf[len - 1 - j]);
    }
}
