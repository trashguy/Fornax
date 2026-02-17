/// su — switch user (root only).
///
/// Plan 9 philosophy: no privilege escalation. Only root can su.
const fx = @import("fornax");

const out = fx.io.Writer.stdout;
const err = fx.io.Writer.stderr;

var elf_buf: [2 * 1024 * 1024]u8 linksection(".bss") = undefined;

fn argSlice(arg: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (arg[len] != 0) : (len += 1) {}
    return arg[0..len];
}

export fn _start() noreturn {
    if (fx.getuid() != 0) {
        err.puts("su: only root can switch users\n");
        fx.exit(1);
    }

    const args = fx.getArgs();
    if (args.len < 2) {
        err.puts("usage: su <username>\n");
        fx.exit(1);
    }

    const username = argSlice(args[1]);
    const entry = fx.passwd.lookupByName(username) orelse {
        err.print("su: unknown user '{s}'\n", .{username});
        fx.exit(1);
    };

    // Set identity
    _ = fx.setuid(entry.uid, entry.gid);

    // Load target user's shell
    const shell = entry.shellSlice();
    const shell_path = if (shell.len > 0) shell else "/bin/fsh";

    const fd = fx.open(shell_path);
    if (fd < 0) {
        err.puts("su: cannot open shell\n");
        fx.exit(1);
    }

    var total: usize = 0;
    while (total < elf_buf.len) {
        const n = fx.read(fd, elf_buf[total..]);
        if (n <= 0) break;
        total += @intCast(n);
    }
    _ = fx.close(fd);

    if (total == 0) {
        err.puts("su: empty shell binary\n");
        fx.exit(1);
    }

    _ = fx.exec(elf_buf[0..total]);
    err.puts("su: exec failed\n");
    fx.exit(1);
}
