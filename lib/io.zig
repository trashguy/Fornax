/// I/O helpers for Fornax userspace.
const syscall = @import("syscall.zig");
const fmt = @import("fmt.zig");

/// Writer parameterized by file descriptor.
pub const Writer = struct {
    fd: i32,

    pub const stdout = Writer{ .fd = 1 };
    pub const stderr = Writer{ .fd = 2 };

    pub fn puts(self: Writer, s: []const u8) void {
        _ = syscall.write(self.fd, s);
    }

    pub fn putc(self: Writer, c: u8) void {
        _ = syscall.write(self.fd, @as(*const [1]u8, &c));
    }

    pub fn putDec(self: Writer, val: u64) void {
        var buf: [20]u8 = undefined;
        self.puts(fmt.formatDec(&buf, val));
    }

    pub fn putDecSigned(self: Writer, val: i64) void {
        var buf: [21]u8 = undefined;
        self.puts(fmt.formatDecSigned(&buf, val));
    }

    pub fn putHex(self: Writer, val: u64) void {
        var buf: [16]u8 = undefined;
        self.puts(fmt.formatHex(&buf, val));
    }

    /// Comptime format string printer.
    /// Supported verbs: {s} string, {d} decimal, {x} hex, {c} char, {{ literal brace.
    pub fn print(self: Writer, comptime format: []const u8, args: anytype) void {
        comptime var i: usize = 0;
        comptime var arg_idx: usize = 0;
        comptime var last: usize = 0;

        inline while (i < format.len) {
            if (format[i] == '{') {
                if (i + 1 < format.len and format[i + 1] == '{') {
                    // Literal brace
                    if (i > last) self.puts(format[last..i]);
                    self.putc('{');
                    i += 2;
                    last = i;
                } else if (i + 2 < format.len and format[i + 2] == '}') {
                    // Format verb
                    if (i > last) self.puts(format[last..i]);
                    const verb = format[i + 1];
                    switch (verb) {
                        's' => self.puts(args[arg_idx]),
                        'd' => self.putDec(args[arg_idx]),
                        'x' => self.putHex(args[arg_idx]),
                        'c' => self.putc(args[arg_idx]),
                        else => @compileError("unknown format verb: " ++ &[_]u8{verb}),
                    }
                    arg_idx += 1;
                    i += 3;
                    last = i;
                } else {
                    i += 1;
                }
            } else if (format[i] == '}' and i + 1 < format.len and format[i + 1] == '}') {
                if (i > last) self.puts(format[last..i]);
                self.putc('}');
                i += 2;
                last = i;
            } else {
                i += 1;
            }
        }
        if (last < format.len) self.puts(format[last..]);
    }
};

/// Read a full line from fd into buf. Returns the slice up to (not including)
/// the trailing newline, or null on read error.
pub fn readLine(fd: i32, buf: []u8) ?[]const u8 {
    const n = syscall.read(fd, buf);
    if (n <= 0) return null;
    const len: usize = @intCast(n);
    if (len > 0 and buf[len - 1] == '\n') return buf[0 .. len - 1];
    return buf[0..len];
}

/// Read all available data from fd into buf. Returns total bytes read.
pub fn readAll(fd: i32, buf: []u8) usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = syscall.read(fd, buf[total..]);
        if (n <= 0) break;
        total += @intCast(n);
    }
    return total;
}

/// Write all data to fd. Returns true if all bytes were written.
pub fn writeAll(fd: i32, data: []const u8) bool {
    var written: usize = 0;
    while (written < data.len) {
        const n = syscall.write(fd, data[written..]);
        if (n == 0) return false;
        written += n;
    }
    return true;
}
