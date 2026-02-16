/// dmesg — print kernel log buffer.
const fx = @import("fornax");

export fn _start() noreturn {
    var buf: [4096]u8 = undefined;
    var offset: u64 = 0;

    while (true) {
        const n = fx.klog(&buf, offset);
        if (n == 0) break;
        _ = fx.write(1, buf[0..n]);
        offset += n;
    }

    fx.exit(0);
}
