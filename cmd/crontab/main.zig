/// crontab — manage cron jobs.
///
/// Usage:
///   crontab -l       — list current jobs
///   crontab -e       — edit /etc/crontab, then reload
///   crontab -r       — flush all jobs
const fx = @import("fornax");
const out = fx.io.Writer.stdout;
const err_out = fx.io.Writer.stderr;

var elf_buf: [4 * 1024 * 1024]u8 linksection(".bss") = undefined;

export fn _start() noreturn {
    const args = fx.getArgs();

    if (args.len < 2) {
        err_out.puts("usage: crontab [-l|-e|-r]\n");
        fx.exit(1);
    }

    const flag = span(args[1]);

    if (eql(flag, "-l")) {
        // Read /sched/ctl — list jobs
        const fd = fx.open("/sched/ctl");
        if (fd < 0) {
            err_out.puts("crontab: cannot open /sched/ctl (crond not running?)\n");
            fx.exit(1);
        }
        var buf: [4096]u8 = undefined;
        const n = fx.read(fd, &buf);
        _ = fx.close(fd);
        if (n > 0) {
            _ = fx.write(1, buf[0..@intCast(n)]);
        } else {
            out.puts("no jobs\n");
        }
        fx.exit(0);
    }

    if (eql(flag, "-e")) {
        // Spawn editor on /etc/crontab
        const fe_data = loadBin("fe") orelse {
            err_out.puts("crontab: cannot load /bin/fe\n");
            fx.exit(1);
        };

        // Ensure /etc/crontab exists
        const check_fd = fx.open("/etc/crontab");
        if (check_fd < 0) {
            const cfd = fx.create("/etc/crontab", 0);
            if (cfd >= 0) _ = fx.close(cfd);
        } else {
            _ = fx.close(check_fd);
        }

        var argv_buf: [256]u8 = undefined;
        const argv_args: []const []const u8 = &.{ "fe", "/etc/crontab" };
        const argv_block = fx.buildArgvBlock(&argv_buf, argv_args) orelse {
            err_out.puts("crontab: argv build failed\n");
            fx.exit(1);
        };

        const pid = fx.spawn(fe_data, &.{}, argv_block);
        if (pid < 0) {
            err_out.puts("crontab: cannot spawn editor\n");
            fx.exit(1);
        }
        _ = fx.wait(0);

        // Reload crond
        const ctl_fd = fx.open("/sched/ctl");
        if (ctl_fd >= 0) {
            _ = fx.write(ctl_fd, "reload");
            _ = fx.close(ctl_fd);
            out.puts("crontab: reloaded\n");
        }
        fx.exit(0);
    }

    if (eql(flag, "-r")) {
        // Flush all jobs
        const fd = fx.open("/sched/ctl");
        if (fd < 0) {
            err_out.puts("crontab: cannot open /sched/ctl\n");
            fx.exit(1);
        }
        _ = fx.write(fd, "flush");
        _ = fx.close(fd);
        out.puts("crontab: all jobs removed\n");
        fx.exit(0);
    }

    err_out.puts("usage: crontab [-l|-e|-r]\n");
    fx.exit(1);
}

fn loadBin(name: []const u8) ?[]const u8 {
    var p = fx.path.PathBuf.from("/bin/");
    _ = p.appendRaw(name);

    const fd = fx.open(p.slice());
    if (fd < 0) return null;

    var total: usize = 0;
    while (total < elf_buf.len) {
        const n = fx.read(fd, elf_buf[total..]);
        if (n <= 0) break;
        total += @intCast(n);
    }
    _ = fx.close(fd);
    if (total == 0) return null;
    return elf_buf[0..total];
}

fn eql(a: []const u8, b: []const u8) bool {
    return fx.str.eql(a, b);
}

fn span(ptr: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (ptr[len] != 0) len += 1;
    return ptr[0..len];
}
