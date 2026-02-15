/// Fornax init — PID 1 (well, PID 2 now — ramfs is PID 1).
///
/// Loads fsh from /boot/fsh and respawns it in a loop.
const fx = @import("fornax");

/// 4 MB buffer for loading ELF binaries (matches spawn syscall limit).
/// linksection forces this into .bss so it doesn't bloat the ELF file.
var elf_buf: [4 * 1024 * 1024]u8 linksection(".bss") = undefined;

const out = fx.io.Writer.stdout;

/// Load an ELF from /boot/<name> into elf_buf. Returns the slice, or null on failure.
fn loadBoot(name: []const u8) ?[]const u8 {
    out.print("init: opening /boot/{s}\n", .{name});

    var p = fx.path.PathBuf.from("/boot/");
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

    while (true) {
        const elf_data = loadBoot("fsh") orelse {
            out.puts("init: failed to load /boot/fsh\n");
            fx.exit(1);
        };

        out.puts("init: spawning fsh...\n");
        const pid = fx.spawn(elf_data, &.{}, null);
        out.print("init: spawn returned {d}\n", .{@as(u64, @bitCast(@as(i64, pid)))});
        if (pid < 0) {
            out.puts("init: failed to spawn fsh\n");
            fx.exit(1);
        }

        _ = fx.wait(@intCast(pid));
        out.puts("init: fsh exited, respawning\n");
    }
}
