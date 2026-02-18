/// lscpu — display CPU information.
///
/// Reads /dev/cpu and displays CPU details.
const fx = @import("fornax");

const out = fx.io.Writer.stdout;

fn getValue(data: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < data.len) {
        // Find end of line
        var eol = i;
        while (eol < data.len and data[eol] != '\n') : (eol += 1) {}
        const line = data[i..eol];
        i = eol + 1;

        // Match "key value"
        if (line.len > key.len and fx.str.startsWith(line, key) and line[key.len] == ' ') {
            return line[key.len + 1 ..];
        }
    }
    return null;
}

export fn _start() noreturn {
    var buf: [512]u8 = undefined;

    const fd = fx.open("/dev/cpu");
    if (fd < 0) {
        out.puts("lscpu: cannot open /dev/cpu\n");
        fx.exit(1);
    }

    const n = fx.read(fd, &buf);
    _ = fx.close(fd);

    if (n <= 0) {
        out.puts("No CPU information available.\n");
        fx.exit(0);
    }

    const data = buf[0..@intCast(n)];

    if (getValue(data, "arch")) |v| {
        out.puts("Architecture:    ");
        out.puts(v);
        out.putc('\n');
    }
    if (getValue(data, "vendor")) |v| {
        out.puts("Vendor:          ");
        out.puts(v);
        out.putc('\n');
    }
    if (getValue(data, "model")) |v| {
        out.puts("Model:           ");
        out.puts(v);
        out.putc('\n');
    }
    if (getValue(data, "family")) |v| {
        out.puts("CPU family:      ");
        out.puts(v);
        out.putc('\n');
    }
    if (getValue(data, "model_id")) |v| {
        out.puts("Model ID:        ");
        out.puts(v);
        out.putc('\n');
    }
    if (getValue(data, "stepping")) |v| {
        out.puts("Stepping:        ");
        out.puts(v);
        out.putc('\n');
    }
    if (getValue(data, "cores")) |v| {
        out.puts("CPU(s):          ");
        out.puts(v);
        out.putc('\n');
    }
    if (getValue(data, "threads_per_pkg")) |v| {
        out.puts("Thread(s)/pkg:   ");
        out.puts(v);
        out.putc('\n');
    }
    if (getValue(data, "isa")) |v| {
        out.puts("ISA:             ");
        out.puts(v);
        out.putc('\n');
    }
    if (getValue(data, "mvendorid")) |v| {
        out.puts("Vendor ID:       ");
        out.puts(v);
        out.putc('\n');
    }
    if (getValue(data, "marchid")) |v| {
        out.puts("Arch ID:         ");
        out.puts(v);
        out.putc('\n');
    }
    if (getValue(data, "mimpid")) |v| {
        out.puts("Impl ID:         ");
        out.puts(v);
        out.putc('\n');
    }

    fx.exit(0);
}
