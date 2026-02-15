/// Fornax init — PID 1 (well, PID 2 now — ramfs is PID 1).
///
/// Loads fsh from /boot/fsh and respawns it in a loop.
const fx = @import("fornax");

/// 4 MB buffer for loading ELF binaries (matches spawn syscall limit).
/// linksection forces this into .bss so it doesn't bloat the ELF file.
var elf_buf: [4 * 1024 * 1024]u8 linksection(".bss") = undefined;

fn puts(s: []const u8) void {
    _ = fx.write(1, s);
}

fn putDec(val: u32) void {
    if (val >= 10) putDec(val / 10);
    const digit: [1]u8 = .{'0' + @as(u8, @truncate(val % 10))};
    _ = fx.write(1, &digit);
}

/// Load an ELF from /boot/<name> into elf_buf. Returns the slice, or null on failure.
fn loadBoot(name: []const u8) ?[]const u8 {
    puts("init: opening /boot/");
    puts(name);
    puts("\n");

    var path_buf: [128]u8 = undefined;
    const prefix = "/boot/";
    @memcpy(path_buf[0..prefix.len], prefix);
    @memcpy(path_buf[prefix.len..][0..name.len], name);
    const path = path_buf[0 .. prefix.len + name.len];

    const fd = fx.open(path);
    puts("init: open returned ");
    putDec(@bitCast(fd));
    puts("\n");
    if (fd < 0) return null;

    puts("init: reading into elf_buf...\n");
    var total: usize = 0;
    while (total < elf_buf.len) {
        const n = fx.read(fd, elf_buf[total..]);
        if (n <= 0) break;
        total += @intCast(n);
    }
    _ = fx.close(fd);

    puts("init: read ");
    putDec(@intCast(total));
    puts(" bytes\n");

    if (total == 0) return null;
    return elf_buf[0..total];
}

export fn _start() noreturn {
    puts("init: started\n");

    while (true) {
        const elf_data = loadBoot("fsh") orelse {
            puts("init: failed to load /boot/fsh\n");
            fx.exit(1);
        };

        puts("init: spawning fsh...\n");
        const pid = fx.spawn(elf_data, &.{});
        puts("init: spawn returned ");
        putDec(@bitCast(pid));
        puts("\n");
        if (pid < 0) {
            puts("init: failed to spawn fsh\n");
            fx.exit(1);
        }

        _ = fx.wait(@intCast(pid));
        puts("init: fsh exited, respawning\n");
    }
}
