/// lspci — list PCI devices.
///
/// Reads /dev/pci and displays PCI device information.
const fx = @import("fornax");

const out = fx.io.Writer.stdout;

/// PCI class code to human-readable name.
fn className(class: u8, subclass: u8) []const u8 {
    return switch (class) {
        0x00 => "Unclassified device",
        0x01 => switch (subclass) {
            0x00 => "SCSI storage controller",
            0x01 => "IDE interface",
            0x05 => "ATA controller",
            0x06 => "SATA controller",
            0x08 => "NVM controller",
            else => "Mass storage controller",
        },
        0x02 => switch (subclass) {
            0x00 => "Ethernet controller",
            0x80 => "Network controller",
            else => "Network controller",
        },
        0x03 => switch (subclass) {
            0x00 => "VGA compatible controller",
            0x02 => "3D controller",
            else => "Display controller",
        },
        0x04 => "Multimedia controller",
        0x05 => "Memory controller",
        0x06 => switch (subclass) {
            0x00 => "Host bridge",
            0x01 => "ISA bridge",
            0x04 => "PCI bridge",
            0x80 => "Bridge",
            else => "Bridge",
        },
        0x07 => "Communication controller",
        0x08 => "System peripheral",
        0x09 => "Input device controller",
        0x0c => switch (subclass) {
            0x03 => "USB controller",
            0x05 => "SMBus controller",
            else => "Serial bus controller",
        },
        0x0d => "Wireless controller",
        0xff => "Unassigned class",
        else => "Unknown device",
    };
}

/// Parse a 2-digit hex string to u8.
fn parseHex2(s: []const u8) ?u8 {
    if (s.len != 2) return null;
    const hi = hexDigit(s[0]) orelse return null;
    const lo = hexDigit(s[1]) orelse return null;
    return (@as(u8, hi) << 4) | @as(u8, lo);
}

/// Parse a 4-digit hex string to u16.
fn parseHex4(s: []const u8) ?u16 {
    if (s.len != 4) return null;
    var result: u16 = 0;
    for (s) |c| {
        const d = hexDigit(c) orelse return null;
        result = (result << 4) | @as(u16, d);
    }
    return result;
}

fn hexDigit(c: u8) ?u4 {
    if (c >= '0' and c <= '9') return @truncate(c - '0');
    if (c >= 'a' and c <= 'f') return @truncate(c - 'a' + 10);
    if (c >= 'A' and c <= 'F') return @truncate(c - 'A' + 10);
    return null;
}

/// Write a u16 as 4 hex digits.
fn putHex4(val: u16) void {
    const hex = "0123456789abcdef";
    var buf: [4]u8 = undefined;
    buf[0] = hex[@as(u4, @truncate(val >> 12))];
    buf[1] = hex[@as(u4, @truncate(val >> 8))];
    buf[2] = hex[@as(u4, @truncate(val >> 4))];
    buf[3] = hex[@as(u4, @truncate(val))];
    out.puts(&buf);
}

/// Write a u8 as 2 hex digits.
fn putHex2(val: u8) void {
    const hex = "0123456789abcdef";
    var buf: [2]u8 = undefined;
    buf[0] = hex[@as(u4, @truncate(val >> 4))];
    buf[1] = hex[@as(u4, @truncate(val))];
    out.puts(&buf);
}

export fn _start() noreturn {
    var buf: [2048]u8 = undefined;

    const fd = fx.open("/dev/pci");
    if (fd < 0) {
        out.puts("lspci: cannot open /dev/pci\n");
        fx.exit(1);
    }

    const n = fx.read(fd, &buf);
    _ = fx.close(fd);

    if (n <= 0) {
        out.puts("No PCI devices found.\n");
        fx.exit(0);
    }

    const data = buf[0..@intCast(n)];

    // Parse lines: "BB:SS.F VVVV:DDDD CC:SS:PP\n"
    var i: usize = 0;
    while (i < data.len) {
        // Find end of line
        var eol = i;
        while (eol < data.len and data[eol] != '\n') : (eol += 1) {}
        const line = data[i..eol];
        i = eol + 1;

        // Need at least "BB:SS.F VVVV:DDDD CC:SS:PP" = 26 chars
        if (line.len < 26) continue;
        if (line[2] != ':' or line[5] != '.' or line[7] != ' ') continue;
        if (line[12] != ':' or line[17] != ' ') continue;
        if (line[20] != ':' or line[23] != ':') continue;

        // Parse fields
        const class = parseHex2(line[18..20]) orelse continue;
        const subclass = parseHex2(line[21..23]) orelse continue;
        const vendor = parseHex4(line[8..12]) orelse continue;
        const device = parseHex4(line[13..17]) orelse continue;

        // Output: "BB:SS.F Class CCSS: Description [VVVV:DDDD]"
        // BDF
        out.puts(line[0..7]);
        out.puts(" ");
        // Class name
        out.puts(className(class, subclass));
        // Vendor:Device
        out.puts(" [");
        putHex4(vendor);
        out.putc(':');
        putHex4(device);
        out.puts("]\n");
    }

    fx.exit(0);
}
