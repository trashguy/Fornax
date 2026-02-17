/// lsusb — list USB devices.
///
/// Reads /dev/usb and displays USB device information.
const fx = @import("fornax");

const out = fx.io.Writer.stdout;

export fn _start() noreturn {
    var buf: [2048]u8 = undefined;

    const fd = fx.open("/dev/usb");
    if (fd < 0) {
        out.puts("lsusb: cannot open /dev/usb\n");
        fx.exit(1);
    }

    const n = fx.read(fd, &buf);
    _ = fx.close(fd);

    if (n <= 0) {
        out.puts("No USB devices found.\n");
        fx.exit(0);
    }

    out.puts(buf[0..@intCast(n)]);
    fx.exit(0);
}
