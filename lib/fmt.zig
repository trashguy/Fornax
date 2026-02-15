/// Number formatting into caller-provided buffers. No I/O.

/// Format an unsigned integer as decimal into buf. Returns the formatted slice.
pub fn formatDec(buf: []u8, val: u64) []const u8 {
    if (val == 0) {
        if (buf.len > 0) {
            buf[0] = '0';
            return buf[0..1];
        }
        return buf[0..0];
    }

    // Write digits in reverse
    var v = val;
    var i: usize = buf.len;
    while (v > 0 and i > 0) {
        i -= 1;
        buf[i] = '0' + @as(u8, @truncate(v % 10));
        v /= 10;
    }
    return buf[i..];
}

/// Format a signed integer as decimal into buf. Returns the formatted slice.
pub fn formatDecSigned(buf: []u8, val: i64) []const u8 {
    if (val >= 0) {
        return formatDec(buf, @intCast(val));
    }

    // Negative: write '-' then the absolute value
    if (buf.len < 2) return buf[0..0];

    const abs: u64 = @intCast(-val);
    const digits = formatDec(buf[1..], abs);

    // Shift digits right to make room for '-' if needed
    const start = @intFromPtr(digits.ptr) - @intFromPtr(buf.ptr);
    if (start > 0) {
        buf[start - 1] = '-';
        return buf[start - 1 ..][0 .. digits.len + 1];
    }
    return digits;
}

/// Format an unsigned integer as hexadecimal into buf. Returns the formatted slice.
pub fn formatHex(buf: []u8, val: u64) []const u8 {
    const hex_chars = "0123456789abcdef";

    if (val == 0) {
        if (buf.len > 0) {
            buf[0] = '0';
            return buf[0..1];
        }
        return buf[0..0];
    }

    var v = val;
    var i: usize = buf.len;
    while (v > 0 and i > 0) {
        i -= 1;
        buf[i] = hex_chars[@as(usize, @truncate(v & 0xF))];
        v >>= 4;
    }
    return buf[i..];
}
