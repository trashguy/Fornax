/// Fornax init — PID 1.
///
/// Spawns fsh on each virtual terminal (VT 0-3).
const fx = @import("fornax");

/// 4 MB buffer for loading ELF binaries (matches spawn syscall limit).
/// linksection forces this into .bss so it doesn't bloat the ELF file.
var elf_buf: [4 * 1024 * 1024]u8 linksection(".bss") = undefined;

const out = fx.io.Writer.stdout;

const NUM_VTS = 4;

/// Load an ELF from /bin/<name> into elf_buf. Returns the slice, or null on failure.
fn loadBin(name: []const u8) ?[]const u8 {
    out.print("init: opening /bin/{s}\n", .{name});

    var p = fx.path.PathBuf.from("/bin/");
    _ = p.appendRaw(name);

    const fd = fx.open(p.slice());
    out.print("init: open returned {d}\n", .{@as(u64, @bitCast(@as(i64, fd)))});
    if (fd < 0) return null;

    out.puts("init: reading into elf_buf...\n");
    var total: usize = 0;
    while (total < elf_buf.len) {
        const n = fx.read(fd, elf_buf[total..]);
        if (n <= 0) break;
        total += @intCast(n);
    }
    _ = fx.close(fd);

    out.print("init: read {d} bytes\n", .{@as(u64, total)});

    if (total == 0) return null;
    return elf_buf[0..total];
}

export fn _start() noreturn {
    out.puts("init: started\n");

    // Ensure standard directories exist (dev/proc/net/tmp baked into rootfs image)
    _ = fx.mkdir("/var");
    _ = fx.mkdir("/var/log");

    // Load fsh once
    const elf_data = loadBin("fsh") orelse {
        out.puts("init: failed to load /bin/fsh\n");
        fx.exit(1);
    };

    // Spawn fsh on each VT
    var num_shells: u8 = 0;
    for (0..NUM_VTS) |i| {
        // Set current process's VT (child inherits it)
        var vt_cmd = [_]u8{ 'v', 't', ' ', '0' + @as(u8, @intCast(i)) };
        _ = fx.write(0, &vt_cmd);

        const pid = fx.spawn(elf_data, &.{}, null);
        if (pid >= 0) {
            num_shells += 1;
            out.print("init: fsh on VT {d}, pid={d}\n", .{ i, @as(u64, @bitCast(@as(i64, pid))) });
        } else {
            out.print("init: failed to spawn fsh on VT {d}\n", .{i});
        }
    }

    // Wait for all shells to exit
    var exited: u8 = 0;
    while (exited < num_shells) {
        _ = fx.wait(0);
        exited += 1;
    }

    out.puts("init: all shells exited\n");
    fx.exit(0);
}
