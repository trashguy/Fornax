const fx = @import("fornax");

const err = fx.io.Writer.stderr;

export fn _start() noreturn {
    const args = fx.getArgs();

    if (args.len != 3) {
        err.puts("usage: chown user file\n");
        fx.exit(1);
    }

    const owner = argSlice(args[1]);
    const path = argSlice(args[2]);

    // Try numeric first, then username lookup
    const uid: u16 = if (parseDec(owner)) |n|
        @truncate(n)
    else if (fx.passwd.lookupByName(owner)) |entry|
        entry.uid
    else {
        err.print("chown: unknown user '{s}'\n", .{owner});
        fx.exit(1);
    };

    const fd = fx.open(path);
    if (fd < 0) {
        err.print("chown: {s}: cannot open\n", .{path});
        fx.exit(1);
    }

    const result = fx.wstat(fd, 0, uid, 0, fx.WSTAT_UID);
    _ = fx.close(fd);

    if (result < 0) {
        err.print("chown: {s}: failed\n", .{path});
        fx.exit(1);
    }

    fx.exit(0);
}

fn parseDec(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    var n: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        n = n * 10 + (c - '0');
    }
    return n;
}

fn argSlice(arg: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (arg[len] != 0) : (len += 1) {}
    return arg[0..len];
}
