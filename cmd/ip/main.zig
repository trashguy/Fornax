const fx = @import("fornax");

const out = fx.io.Writer.stdout;
const err = fx.io.Writer.stderr;

fn cstr(ptr: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (ptr[len] != 0) : (len += 1) {}
    return ptr[0..len];
}

fn sliceEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

fn writeCtl(data: []const u8) bool {
    const fd = fx.open("/net/ipifc/0/ctl");
    if (fd < 0) {
        err.puts("ip: cannot open /net/ipifc/0/ctl\n");
        return false;
    }
    const n = fx.write(fd, data);
    _ = fx.close(fd);
    return n > 0;
}

fn showStatus() void {
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
}

export fn _start() noreturn {
    const args = fx.getArgs();

    // No args or just "ip" → show status
    if (args.len < 2) {
        showStatus();
        fx.exit(0);
    }

    const subcmd = cstr(args[1]);

    if (sliceEql(subcmd, "dhcp")) {
        // ip dhcp → write "dhcp" to /net/ipifc/0/ctl
        if (writeCtl("dhcp")) {
            out.puts("DHCP started\n");
            fx.exit(0);
        } else {
            err.puts("ip: dhcp request failed\n");
            fx.exit(1);
        }
    } else if (sliceEql(subcmd, "add")) {
        // ip add <addr> <mask> <gw>
        if (args.len < 5) {
            err.puts("Usage: ip add <addr> <mask> <gateway>\n");
            fx.exit(1);
        }
        const addr = cstr(args[2]);
        const mask = cstr(args[3]);
        const gw = cstr(args[4]);

        // Build "add <addr> <mask> <gw>"
        var buf: [128]u8 = undefined;
        const prefix = "add ";
        @memcpy(buf[0..prefix.len], prefix);
        var pos: usize = prefix.len;

        @memcpy(buf[pos..][0..addr.len], addr);
        pos += addr.len;
        buf[pos] = ' ';
        pos += 1;

        @memcpy(buf[pos..][0..mask.len], mask);
        pos += mask.len;
        buf[pos] = ' ';
        pos += 1;

        @memcpy(buf[pos..][0..gw.len], gw);
        pos += gw.len;

        if (writeCtl(buf[0..pos])) {
            out.puts("IP configured\n");
            fx.exit(0);
        } else {
            err.puts("ip: configuration failed\n");
            fx.exit(1);
        }
    } else if (sliceEql(subcmd, "dns")) {
        // ip dns <addr>
        if (args.len < 3) {
            err.puts("Usage: ip dns <addr>\n");
            fx.exit(1);
        }
        const addr = cstr(args[2]);

        var buf: [64]u8 = undefined;
        const prefix = "dns ";
        @memcpy(buf[0..prefix.len], prefix);
        @memcpy(buf[prefix.len..][0..addr.len], addr);

        if (writeCtl(buf[0 .. prefix.len + addr.len])) {
            out.puts("DNS configured\n");
            fx.exit(0);
        } else {
            err.puts("ip: DNS configuration failed\n");
            fx.exit(1);
        }
    } else {
        err.puts("Usage: ip [dhcp | add <addr> <mask> <gw> | dns <addr>]\n");
        fx.exit(1);
    }
}
