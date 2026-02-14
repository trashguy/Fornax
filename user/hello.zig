const fornax = @import("fornax");

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\call _main
        \\ud2
    );
}

export fn _main() callconv(.c) noreturn {
    // Direct write to kernel framebuffer (always works)
    _ = fornax.write(1, "Hello from Fornax userspace!\n");

    // Test IPC: open /dev/console and write through the console server
    const fd = fornax.open("/dev/console");
    if (fd >= 0) {
        _ = fornax.write(1, "Opened /dev/console (fd=");
        putDecFd(fd);
        _ = fornax.write(1, ")\n");

        // Write through IPC to console server
        _ = fornax.write(fd, "Hello from IPC via console server!\n");

        _ = fornax.close(fd);
    } else {
        _ = fornax.write(1, "Failed to open /dev/console\n");
    }

    fornax.exit(0);
}

fn putDecFd(val: i32) void {
    if (val < 0) {
        _ = fornax.write(1, "-");
        return;
    }
    var buf: [10]u8 = undefined;
    var n: u32 = @intCast(val);
    var i: usize = 0;
    if (n == 0) {
        _ = fornax.write(1, "0");
        return;
    }
    while (n > 0) : (i += 1) {
        buf[i] = @intCast(n % 10 + '0');
        n /= 10;
    }
    // Reverse
    var j: usize = 0;
    while (j < i / 2) : (j += 1) {
        const tmp = buf[j];
        buf[j] = buf[i - 1 - j];
        buf[i - 1 - j] = tmp;
    }
    _ = fornax.write(1, buf[0..i]);
}
