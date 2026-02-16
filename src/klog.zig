const console = @import("console.zig");
const serial = @import("serial.zig");

pub const Level = enum(u2) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
};

pub var console_level: Level = .warn;

const BUF_SIZE = 64 * 1024;

var ring: [BUF_SIZE]u8 linksection(".bss") = undefined;
var write_pos: usize = 0;
var total_written: usize = 0;

fn writeToRing(s: []const u8) void {
    for (s) |c| {
        ring[write_pos] = c;
        write_pos = (write_pos + 1) % BUF_SIZE;
    }
    total_written += s.len;
}

fn emit(level: Level, s: []const u8) void {
    writeToRing(s);
    if (@intFromEnum(level) >= @intFromEnum(console_level)) {
        console.puts(s);
    } else {
        serial.puts(s);
    }
}

fn emitDec(level: Level, val: u64) void {
    var buf: [20]u8 = undefined;
    const s = fmtDec(val, &buf);
    writeToRing(s);
    if (@intFromEnum(level) >= @intFromEnum(console_level)) {
        console.puts(s);
    } else {
        serial.puts(s);
    }
}

fn emitHex(level: Level, val: u64) void {
    var buf: [18]u8 = undefined;
    const s = fmtHex(val, &buf);
    writeToRing(s);
    if (@intFromEnum(level) >= @intFromEnum(console_level)) {
        console.puts(s);
    } else {
        serial.puts(s);
    }
}

fn fmtDec(val: u64, buf: *[20]u8) []const u8 {
    if (val == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var n = val;
    var i: usize = 0;
    while (n > 0) : (i += 1) {
        buf[i] = @intCast(n % 10 + '0');
        n /= 10;
    }
    // reverse in place
    var lo: usize = 0;
    var hi = i - 1;
    while (lo < hi) {
        const tmp = buf[lo];
        buf[lo] = buf[hi];
        buf[hi] = tmp;
        lo += 1;
        hi -= 1;
    }
    return buf[0..i];
}

fn fmtHex(val: u64, buf: *[18]u8) []const u8 {
    const hex = "0123456789ABCDEF";
    buf[0] = '0';
    buf[1] = 'x';
    var started = false;
    var pos: usize = 2;
    var shift: u6 = 60;
    while (true) {
        const nibble: u4 = @intCast((val >> shift) & 0xF);
        if (nibble != 0) started = true;
        if (started) {
            buf[pos] = hex[nibble];
            pos += 1;
        }
        if (shift == 0) break;
        shift -= 4;
    }
    if (!started) {
        buf[pos] = '0';
        pos += 1;
    }
    return buf[0..pos];
}

// ── Public API: level-specific string output ──

pub fn debug(s: []const u8) void {
    emit(.debug, s);
}
pub fn info(s: []const u8) void {
    emit(.info, s);
}
pub fn warn(s: []const u8) void {
    emit(.warn, s);
}
pub fn err(s: []const u8) void {
    emit(.err, s);
}

// ── Public API: level-specific decimal output ──

pub fn debugDec(val: u64) void {
    emitDec(.debug, val);
}
pub fn infoDec(val: u64) void {
    emitDec(.info, val);
}
pub fn warnDec(val: u64) void {
    emitDec(.warn, val);
}
pub fn errDec(val: u64) void {
    emitDec(.err, val);
}

// ── Public API: level-specific hex output ──

pub fn debugHex(val: u64) void {
    emitHex(.debug, val);
}
pub fn infoHex(val: u64) void {
    emitHex(.info, val);
}
pub fn warnHex(val: u64) void {
    emitHex(.warn, val);
}
pub fn errHex(val: u64) void {
    emitHex(.err, val);
}

// ── Ring buffer read (for sysKlog) ──

/// Read from the ring buffer starting at `offset` into `dst`.
/// Returns the number of bytes copied (0 = no new data).
pub fn read(dst: []u8, offset: usize) usize {
    if (offset >= total_written) return 0;

    // If offset is too old (data overwritten), snap to earliest available
    var start = offset;
    if (total_written > BUF_SIZE and start < total_written - BUF_SIZE) {
        start = total_written - BUF_SIZE;
    }

    const available = total_written - start;
    const to_copy = @min(available, dst.len);

    var i: usize = 0;
    while (i < to_copy) : (i += 1) {
        dst[i] = ring[(start + i) % BUF_SIZE];
    }

    return to_copy;
}
