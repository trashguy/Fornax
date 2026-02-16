const fx = @import("fornax");
const out = fx.io.Writer.stdout;
const err = fx.io.Writer.stderr;

export fn _start() noreturn {
    const args = fx.getArgs();

    if (args.len < 2) {
        err.puts("Usage: kill <pid>\n");
        fx.exit(1);
    }

    for (args[1..]) |arg| {
        const name = argStr(arg);

        // Build /proc/N/ctl path
        var path_buf: [80]u8 = undefined;
        const path = buildPath(&path_buf, "/proc/", name, "/ctl");

        const fd = fx.open(path);
        if (fd < 0) {
            err.puts("kill: no such process: ");
            err.puts(name);
            err.putc('\n');
            continue;
        }

        _ = fx.write(fd, "kill");
        _ = fx.close(fd);
    }

    fx.exit(0);
}

fn argStr(ptr: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (ptr[len] != 0) : (len += 1) {}
    return ptr[0..len];
}

fn buildPath(buf: []u8, prefix: []const u8, mid: []const u8, suffix: []const u8) []const u8 {
    const total_len = prefix.len + mid.len + suffix.len;
    if (total_len > buf.len) return prefix;
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..mid.len], mid);
    @memcpy(buf[prefix.len + mid.len ..][0..suffix.len], suffix);
    return buf[0..total_len];
}
