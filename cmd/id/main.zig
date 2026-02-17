/// id — print user and group identity.
const fx = @import("fornax");

const out = fx.io.Writer.stdout;

fn argSlice(arg: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (arg[len] != 0) : (len += 1) {}
    return arg[0..len];
}

export fn _start() noreturn {
    const uid = fx.getuid();
    const gid = fx.getgid();

    var uid_buf: [8]u8 = undefined;
    var gid_buf: [8]u8 = undefined;
    const uid_str = fx.fmt.formatDec(&uid_buf, uid);
    const gid_str = fx.fmt.formatDec(&gid_buf, gid);

    out.print("uid={s}", .{uid_str});
    if (fx.passwd.lookupByUid(uid)) |entry| {
        out.print("({s})", .{entry.usernameSlice()});
    }
    out.print(" gid={s}", .{gid_str});
    if (fx.group.lookupByGid(gid)) |entry| {
        out.print("({s})", .{entry.groupnameSlice()});
    }
    out.puts("\n");

    fx.exit(0);
}
