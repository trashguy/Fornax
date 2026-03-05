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

/// Parse variable-width hex string to u64.
fn parseHexVar(s: []const u8) ?u64 {
    if (s.len == 0 or s.len > 16) return null;
    var result: u64 = 0;
    for (s) |c| {
        const d = hexDigit(c) orelse return null;
        result = (result << 4) | @as(u64, d);
    }
    return result;
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

/// Format a size in bytes as human-readable (e.g. "256K", "16M", "4G").
fn putSize(size: u64) void {
    if (size == 0) {
        out.putc('-');
        return;
    }
    if (size >= 1024 * 1024 * 1024 and size % (1024 * 1024 * 1024) == 0) {
        putDec(size / (1024 * 1024 * 1024));
        out.putc('G');
    } else if (size >= 1024 * 1024 and size % (1024 * 1024) == 0) {
        putDec(size / (1024 * 1024));
        out.putc('M');
    } else if (size >= 1024 and size % 1024 == 0) {
        putDec(size / 1024);
        out.putc('K');
    } else {
        putDec(size);
    }
}

/// Print a u64 as decimal.
fn putDec(val: u64) void {
    if (val == 0) {
        out.putc('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var n: usize = 0;
    var v = val;
    while (v != 0) : (n += 1) {
        buf[n] = @truncate((v % 10) + '0');
        v /= 10;
    }
    var i: usize = 0;
    while (i < n) : (i += 1) {
        out.putc(buf[n - 1 - i]);
    }
}

fn putHexAddr(val: u64) void {
    out.puts("0x");
    const hex = "0123456789ABCDEF";
    if (val == 0) {
        out.putc('0');
        return;
    }
    var buf: [16]u8 = undefined;
    var n: usize = 0;
    var v = val;
    while (v != 0) : (n += 1) {
        buf[n] = hex[@as(u4, @truncate(v & 0xF))];
        v >>= 4;
    }
    var i: usize = 0;
    while (i < n) : (i += 1) {
        out.putc(buf[n - 1 - i]);
    }
}

/// Find position of next char c in data[start..], or null.
fn indexOf(data: []const u8, start: usize, c: u8) ?usize {
    var p = start;
    while (p < data.len) : (p += 1) {
        if (data[p] == c) return p;
    }
    return null;
}

export fn _start() noreturn {
    var buf: [8192]u8 = undefined;

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

    // Parse lines: "BB:SS.F VVVV:DDDD CC:SS:PP [sz0 sz1 ... sz5] [b0 b1 ... b5] [MSI-X:N]\n"
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

        // Output: "BB:SS.F Class: Description [VVVV:DDDD]"
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
        out.putc(']');

        // Parse BAR sizes if present: " [sz0 sz1 sz2 sz3 sz4 sz5]"
        var bar_sizes: [6]u64 = .{ 0, 0, 0, 0, 0, 0 };
        var bar_bases: [6]u64 = .{ 0, 0, 0, 0, 0, 0 };
        var after_sizes: usize = 26;

        if (line.len > 26 and line[25] == ' ' and line[26] == '[') {
            const bar_end = indexOf(line, 27, ']');
            if (bar_end) |be| {
                // Parse space-separated hex values (sizes)
                var bar_count: usize = 0;
                var bp: usize = 27;
                while (bp < be and bar_count < 6) {
                    while (bp < be and line[bp] == ' ') : (bp += 1) {}
                    const tok_start = bp;
                    while (bp < be and line[bp] != ' ') : (bp += 1) {}
                    if (bp > tok_start) {
                        bar_sizes[bar_count] = parseHexVar(line[tok_start..bp]) orelse 0;
                        bar_count += 1;
                    }
                }
                after_sizes = be + 1;

                // Parse BAR bases if present: " [b0 b1 b2 b3 b4 b5]"
                if (after_sizes + 1 < line.len and line[after_sizes] == ' ' and line[after_sizes + 1] == '[') {
                    const base_end = indexOf(line, after_sizes + 2, ']');
                    if (base_end) |bbe| {
                        var base_count: usize = 0;
                        var bbp: usize = after_sizes + 2;
                        while (bbp < bbe and base_count < 6) {
                            while (bbp < bbe and line[bbp] == ' ') : (bbp += 1) {}
                            const btok_start = bbp;
                            while (bbp < bbe and line[bbp] != ' ') : (bbp += 1) {}
                            if (bbp > btok_start) {
                                bar_bases[base_count] = parseHexVar(line[btok_start..bbp]) orelse 0;
                                base_count += 1;
                            }
                        }
                        after_sizes = bbe + 1;
                    }
                }

                // Display non-zero BARs with base and size
                var has_bar = false;
                for (0..6) |bi| {
                    if (bar_sizes[bi] != 0 or bar_bases[bi] != 0) {
                        has_bar = true;
                        break;
                    }
                }
                if (has_bar) {
                    out.putc('\n');
                    for (0..6) |bi| {
                        if (bar_sizes[bi] != 0 or bar_bases[bi] != 0) {
                            out.puts("  BAR");
                            putDec(bi);
                            out.puts(": ");
                            if (bar_bases[bi] != 0) {
                                putHexAddr(bar_bases[bi]);
                            } else {
                                out.putc('-');
                            }
                            out.puts(" (");
                            putSize(bar_sizes[bi]);
                            out.puts(")\n");
                        }
                    }
                }

                // Check for MSI-X after bracket groups
                if (after_sizes + 8 < line.len) {
                    const msix_prefix = " [MSI-X:";
                    if (after_sizes + msix_prefix.len <= line.len) {
                        var match = true;
                        for (0..msix_prefix.len) |mi| {
                            if (line[after_sizes + mi] != msix_prefix[mi]) {
                                match = false;
                                break;
                            }
                        }
                        if (match) {
                            const num_start = after_sizes + msix_prefix.len;
                            const num_end = indexOf(line, num_start, ']');
                            if (num_end) |ne| {
                                if (!has_bar) out.putc('\n');
                                out.puts("  MSI-X: ");
                                out.puts(line[num_start..ne]);
                                out.puts(" vectors\n");
                            }
                        }
                    }
                }

                // If we printed multi-line output, don't add trailing newline
                if (has_bar) continue;
            }
        }

        out.putc('\n');
    }

    fx.exit(0);
}
