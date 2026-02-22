/// DateTime decomposition and formatting for userspace.
///
/// Converts Unix epoch seconds to/from human-readable date/time,
/// with formatting helpers for common output formats.

pub const DateTime = struct {
    year: u32,
    month: u8, // 1-12
    day: u8, // 1-31
    hour: u8, // 0-23
    minute: u8, // 0-59
    second: u8, // 0-59
    dow: u8, // 0=Sun, 1=Mon, ..., 6=Sat
    yday: u16, // 0-365
};

const days_in_month = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
const days_before_month = [_]u16{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };

fn isLeap(y: u32) bool {
    return (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0);
}

fn daysInYear(y: u32) u16 {
    return if (isLeap(y)) 366 else 365;
}

/// Convert Unix epoch seconds to DateTime.
pub fn fromEpoch(epoch: u64) DateTime {
    var remaining = epoch;
    const day_secs: u64 = 86400;

    var total_days = remaining / day_secs;
    remaining %= day_secs;

    const hour: u8 = @intCast(remaining / 3600);
    remaining %= 3600;
    const minute: u8 = @intCast(remaining / 60);
    const second: u8 = @intCast(remaining % 60);

    // Day of week: Jan 1 1970 was Thursday (dow=4)
    const dow: u8 = @intCast((total_days + 4) % 7);

    // Find year
    var year: u32 = 1970;
    while (true) {
        const dy = daysInYear(year);
        if (total_days < dy) break;
        total_days -= dy;
        year += 1;
    }

    const yday: u16 = @intCast(total_days);

    // Find month
    var month: u8 = 0;
    while (month < 11) {
        var md: u16 = days_in_month[month];
        if (month == 1 and isLeap(year)) md += 1;
        if (total_days < md) break;
        total_days -= md;
        month += 1;
    }

    return .{
        .year = year,
        .month = month + 1,
        .day = @as(u8, @intCast(total_days)) + 1,
        .hour = hour,
        .minute = minute,
        .second = second,
        .dow = dow,
        .yday = yday,
    };
}

/// Convert DateTime back to Unix epoch seconds.
pub fn toEpoch(dt: DateTime) u64 {
    var days: u64 = 0;

    // Days from 1970 to start of year
    var y: u32 = 1970;
    while (y < dt.year) : (y += 1) {
        days += daysInYear(y);
    }

    // Days within year
    const m = dt.month -| 1;
    if (m < 12) {
        days += days_before_month[m];
        if (m >= 2 and isLeap(dt.year)) days += 1;
    }
    days += @as(u64, dt.day) -| 1;

    return days * 86400 + @as(u64, dt.hour) * 3600 + @as(u64, dt.minute) * 60 + @as(u64, dt.second);
}

/// Format as "YYYY-MM-DD HH:MM:SS".
pub fn fmtDateTime(dt: DateTime, buf: []u8) []const u8 {
    if (buf.len < 19) return buf[0..0];
    fmtU32(buf[0..4], dt.year, 4);
    buf[4] = '-';
    fmtU32(buf[5..7], dt.month, 2);
    buf[7] = '-';
    fmtU32(buf[8..10], dt.day, 2);
    buf[10] = ' ';
    fmtU32(buf[11..13], dt.hour, 2);
    buf[13] = ':';
    fmtU32(buf[14..16], dt.minute, 2);
    buf[16] = ':';
    fmtU32(buf[17..19], dt.second, 2);
    return buf[0..19];
}

/// Format as "YYYY-MM-DD".
pub fn fmtDate(dt: DateTime, buf: []u8) []const u8 {
    if (buf.len < 10) return buf[0..0];
    fmtU32(buf[0..4], dt.year, 4);
    buf[4] = '-';
    fmtU32(buf[5..7], dt.month, 2);
    buf[7] = '-';
    fmtU32(buf[8..10], dt.day, 2);
    return buf[0..10];
}

/// Format as "HH:MM:SS".
pub fn fmtTime(dt: DateTime, buf: []u8) []const u8 {
    if (buf.len < 8) return buf[0..0];
    fmtU32(buf[0..2], dt.hour, 2);
    buf[2] = ':';
    fmtU32(buf[3..5], dt.minute, 2);
    buf[5] = ':';
    fmtU32(buf[6..8], dt.second, 2);
    return buf[0..8];
}

/// Format uptime seconds as "Xd Xh Xm Xs".
pub fn fmtUptime(secs: u64, buf: []u8) []const u8 {
    var s = secs;
    const days: u64 = s / 86400;
    s %= 86400;
    const hours: u64 = s / 3600;
    s %= 3600;
    const mins: u64 = s / 60;
    s %= 60;

    var pos: usize = 0;
    if (days > 0) {
        pos += writeDec(buf[pos..], days);
        if (pos < buf.len) {
            buf[pos] = 'd';
            pos += 1;
        }
        if (pos < buf.len) {
            buf[pos] = ' ';
            pos += 1;
        }
    }
    pos += writeDec(buf[pos..], hours);
    if (pos < buf.len) {
        buf[pos] = 'h';
        pos += 1;
    }
    if (pos < buf.len) {
        buf[pos] = ' ';
        pos += 1;
    }
    pos += writeDec(buf[pos..], mins);
    if (pos < buf.len) {
        buf[pos] = 'm';
        pos += 1;
    }
    if (pos < buf.len) {
        buf[pos] = ' ';
        pos += 1;
    }
    pos += writeDec(buf[pos..], s);
    if (pos < buf.len) {
        buf[pos] = 's';
        pos += 1;
    }
    return buf[0..pos];
}

/// Day-of-week abbreviation.
pub fn dowName(dow: u8) []const u8 {
    const names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    if (dow < 7) return names[dow];
    return "???";
}

/// Month abbreviation (1-12).
pub fn monthName(m: u8) []const u8 {
    const names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    if (m >= 1 and m <= 12) return names[m - 1];
    return "???";
}

// ── Internal helpers ──────────────────────────────────────────────

/// Write zero-padded decimal into fixed-width slice.
fn fmtU32(dest: []u8, val: anytype, width: usize) void {
    var v: u32 = @intCast(val);
    var i: usize = width;
    while (i > 0) {
        i -= 1;
        dest[i] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
    }
}

/// Write decimal number, return bytes written.
fn writeDec(buf: []u8, val: u64) usize {
    if (buf.len == 0) return 0;
    if (val == 0) {
        buf[0] = '0';
        return 1;
    }
    var tmp: [20]u8 = undefined;
    var v = val;
    var i: usize = 0;
    while (v > 0 and i < 20) {
        tmp[i] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
        i += 1;
    }
    const len = @min(i, buf.len);
    for (0..len) |j| {
        buf[j] = tmp[i - 1 - j];
    }
    return len;
}
