/// Fornax init — PID 1 (well, PID 2 now — ramfs is PID 1).
///
/// The first userspace process after ramfs. Demonstrates:
///   1. Creating a file on ramfs
///   2. Writing data
///   3. Reading it back
const fx = @import("fornax");

fn putDec(val: u32) void {
    if (val >= 10) putDec(val / 10);
    const digit: [1]u8 = .{'0' + @as(u8, @truncate(val % 10))};
    _ = fx.write(1, &digit);
}

fn putI32(val: i32) void {
    if (val < 0) {
        _ = fx.write(1, "-");
        putDec(@intCast(-val));
    } else {
        putDec(@intCast(val));
    }
}

export fn _start() noreturn {
    _ = fx.write(1, "init: started\n");

    // Test: create a file on ramfs, write, read back
    const fd = fx.create("/tmp/hello.txt", 0);
    _ = fx.write(1, "init: create /tmp/hello.txt -> fd ");
    putI32(fd);
    _ = fx.write(1, "\n");

    if (fd >= 0) {
        const msg = "hello fornax!\n";
        const written = fx.write(@intCast(fd), msg);
        _ = fx.write(1, "init: wrote ");
        putDec(@intCast(written));
        _ = fx.write(1, " bytes\n");

        // Close and reopen to test open path
        _ = fx.close(fd);

        const fd2 = fx.open("/tmp/hello.txt");
        if (fd2 >= 0) {
            var buf: [64]u8 = undefined;
            const n = fx.read(fd2, &buf);
            _ = fx.write(1, "init: read ");
            putDec(@intCast(n));
            _ = fx.write(1, " bytes: ");
            if (n > 0) {
                _ = fx.write(1, buf[0..@intCast(n)]);
            }
            _ = fx.close(fd2);
        }
    }

    _ = fx.write(1, "init: ramfs test complete, halting\n");
    fx.exit(0);
}
