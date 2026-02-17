/// whoami — print effective username.
const fx = @import("fornax");

const out = fx.io.Writer.stdout;

export fn _start() noreturn {
    const uid = fx.getuid();

    if (fx.passwd.lookupByUid(uid)) |entry| {
        out.print("{s}\n", .{entry.usernameSlice()});
    } else {
        var buf: [8]u8 = undefined;
        out.print("{s}\n", .{fx.fmt.formatDec(&buf, uid)});
    }

    fx.exit(0);
}
