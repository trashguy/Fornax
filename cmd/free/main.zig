const fx = @import("fornax");
const out = fx.io.Writer.stdout;

const Unit = enum { kb, mb, gb };

export fn _start() noreturn {
    const args = fx.getArgs();

    var unit: Unit = .kb;
    for (args[1..]) |arg| {
        var len: usize = 0;
        while (arg[len] != 0) : (len += 1) {}
        const s = arg[0..len];
        if (fx.str.eql(s, "-m")) {
            unit = .mb;
        } else if (fx.str.eql(s, "-g")) {
            unit = .gb;
        } else if (fx.str.eql(s, "-k")) {
            unit = .kb;
        }
    }

    const info = fx.sysinfo() orelse {
        _ = fx.write(2, "free: sysinfo failed\n");
        fx.exit(1);
    };

    const page_size = info.page_size;
    const total_bytes = info.total_pages * page_size;
    const free_bytes = info.free_pages * page_size;
    const used_bytes = total_bytes - free_bytes;

    const label = switch (unit) {
        .kb => "kB",
        .mb => "MB",
        .gb => "GB",
    };

    const total = convert(total_bytes, unit);
    const used = convert(used_bytes, unit);
    const free = convert(free_bytes, unit);

    out.puts("         total    used    free\n");
    out.puts("Mem: ");
    padRight(fmtSize(total, label), 9);
    padRight(fmtSize(used, label), 8);
    padRight(fmtSize(free, label), 8);
    out.putc('\n');

    fx.exit(0);
}

fn padRight(s: []const u8, width: usize) void {
    out.puts(s);
    var i: usize = s.len;
    while (i < width) : (i += 1) {
        out.putc(' ');
    }
}

var fmt_bufs: [3][32]u8 = undefined;
var fmt_idx: usize = 0;

fn fmtSize(value: u64, label: []const u8) []const u8 {
    const idx = fmt_idx;
    fmt_idx += 1;
    var buf = &fmt_bufs[idx];
    var pos: usize = 0;

    // Write number
    if (value == 0) {
        buf[pos] = '0';
        pos += 1;
    } else {
        var tmp: [20]u8 = undefined;
        var tmp_len: usize = 0;
        var v = value;
        while (v > 0) : (v /= 10) {
            tmp[tmp_len] = @intCast('0' + (v % 10));
            tmp_len += 1;
        }
        var i: usize = 0;
        while (i < tmp_len) : (i += 1) {
            buf[pos] = tmp[tmp_len - 1 - i];
            pos += 1;
        }
    }

    // Write label
    for (label) |c| {
        buf[pos] = c;
        pos += 1;
    }

    return buf[0..pos];
}

fn convert(bytes: u64, unit: Unit) u64 {
    return switch (unit) {
        .kb => bytes / 1024,
        .mb => bytes / (1024 * 1024),
        .gb => bytes / (1024 * 1024 * 1024),
    };
}
