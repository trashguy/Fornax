const std = @import("std");
const time = @import("time");

const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

// ── fromEpoch: Known dates ──────────────────────────────────────────

test "epoch 0 is 1970-01-01 00:00:00 Thursday" {
    const dt = time.fromEpoch(0);
    try expectEqual(@as(u32, 1970), dt.year);
    try expectEqual(@as(u8, 1), dt.month);
    try expectEqual(@as(u8, 1), dt.day);
    try expectEqual(@as(u8, 0), dt.hour);
    try expectEqual(@as(u8, 0), dt.minute);
    try expectEqual(@as(u8, 0), dt.second);
    try expectEqual(@as(u8, 4), dt.dow); // Thursday
    try expectEqual(@as(u16, 0), dt.yday);
}

test "epoch 86399 is 1970-01-01 23:59:59" {
    const dt = time.fromEpoch(86399);
    try expectEqual(@as(u32, 1970), dt.year);
    try expectEqual(@as(u8, 1), dt.month);
    try expectEqual(@as(u8, 1), dt.day);
    try expectEqual(@as(u8, 23), dt.hour);
    try expectEqual(@as(u8, 59), dt.minute);
    try expectEqual(@as(u8, 59), dt.second);
}

test "epoch 86400 is 1970-01-02 Friday" {
    const dt = time.fromEpoch(86400);
    try expectEqual(@as(u32, 1970), dt.year);
    try expectEqual(@as(u8, 1), dt.month);
    try expectEqual(@as(u8, 2), dt.day);
    try expectEqual(@as(u8, 5), dt.dow); // Friday
    try expectEqual(@as(u16, 1), dt.yday);
}

test "2000-01-01 00:00:00 Saturday (Y2K)" {
    // 2000-01-01 = 10957 days from epoch
    const epoch: u64 = 946684800;
    const dt = time.fromEpoch(epoch);
    try expectEqual(@as(u32, 2000), dt.year);
    try expectEqual(@as(u8, 1), dt.month);
    try expectEqual(@as(u8, 1), dt.day);
    try expectEqual(@as(u8, 0), dt.hour);
    try expectEqual(@as(u8, 6), dt.dow); // Saturday
}

test "2024-02-29 leap day" {
    // 2024-02-29 00:00:00 UTC
    const epoch: u64 = 1709164800;
    const dt = time.fromEpoch(epoch);
    try expectEqual(@as(u32, 2024), dt.year);
    try expectEqual(@as(u8, 2), dt.month);
    try expectEqual(@as(u8, 29), dt.day);
    try expectEqual(@as(u8, 4), dt.dow); // Thursday
}

test "2026-02-22 current date" {
    // 2026-02-22 14:30:05 UTC
    const epoch: u64 = 1771770605;
    const dt = time.fromEpoch(epoch);
    try expectEqual(@as(u32, 2026), dt.year);
    try expectEqual(@as(u8, 2), dt.month);
    try expectEqual(@as(u8, 22), dt.day);
    try expectEqual(@as(u8, 14), dt.hour);
    try expectEqual(@as(u8, 30), dt.minute);
    try expectEqual(@as(u8, 5), dt.second);
    try expectEqual(@as(u8, 0), dt.dow); // Sunday
}

test "2038-01-19 03:14:07 (32-bit overflow boundary)" {
    const epoch: u64 = 2147483647; // max i32
    const dt = time.fromEpoch(epoch);
    try expectEqual(@as(u32, 2038), dt.year);
    try expectEqual(@as(u8, 1), dt.month);
    try expectEqual(@as(u8, 19), dt.day);
    try expectEqual(@as(u8, 3), dt.hour);
    try expectEqual(@as(u8, 14), dt.minute);
    try expectEqual(@as(u8, 7), dt.second);
    try expectEqual(@as(u8, 2), dt.dow); // Tuesday
}

test "2100-03-01 not a leap year (divisible by 100)" {
    // 2100-03-01 00:00:00 UTC
    const epoch: u64 = 4107542400;
    const dt = time.fromEpoch(epoch);
    try expectEqual(@as(u32, 2100), dt.year);
    try expectEqual(@as(u8, 3), dt.month);
    try expectEqual(@as(u8, 1), dt.day);
}

test "1970-12-31 23:59:59 end of first year" {
    const epoch: u64 = 365 * 86400 - 1;
    const dt = time.fromEpoch(epoch);
    try expectEqual(@as(u32, 1970), dt.year);
    try expectEqual(@as(u8, 12), dt.month);
    try expectEqual(@as(u8, 31), dt.day);
    try expectEqual(@as(u8, 23), dt.hour);
    try expectEqual(@as(u8, 59), dt.minute);
    try expectEqual(@as(u8, 59), dt.second);
    try expectEqual(@as(u16, 364), dt.yday);
}

// ── toEpoch: Known dates ────────────────────────────────────────────

test "toEpoch of 1970-01-01 is 0" {
    const dt = time.DateTime{
        .year = 1970,
        .month = 1,
        .day = 1,
        .hour = 0,
        .minute = 0,
        .second = 0,
        .dow = 4,
        .yday = 0,
    };
    try expectEqual(@as(u64, 0), time.toEpoch(dt));
}

test "toEpoch of Y2K" {
    const dt = time.DateTime{
        .year = 2000,
        .month = 1,
        .day = 1,
        .hour = 0,
        .minute = 0,
        .second = 0,
        .dow = 6,
        .yday = 0,
    };
    try expectEqual(@as(u64, 946684800), time.toEpoch(dt));
}

test "toEpoch of 2038 boundary" {
    const dt = time.DateTime{
        .year = 2038,
        .month = 1,
        .day = 19,
        .hour = 3,
        .minute = 14,
        .second = 7,
        .dow = 2,
        .yday = 18,
    };
    try expectEqual(@as(u64, 2147483647), time.toEpoch(dt));
}

// ── Roundtrip: fromEpoch → toEpoch ─────────────────────────────────

test "roundtrip epoch 0" {
    try expectEqual(@as(u64, 0), time.toEpoch(time.fromEpoch(0)));
}

test "roundtrip Y2K" {
    const e: u64 = 946684800;
    try expectEqual(e, time.toEpoch(time.fromEpoch(e)));
}

test "roundtrip 2038 boundary" {
    const e: u64 = 2147483647;
    try expectEqual(e, time.toEpoch(time.fromEpoch(e)));
}

test "roundtrip 2024 leap day" {
    const e: u64 = 1709164800;
    try expectEqual(e, time.toEpoch(time.fromEpoch(e)));
}

test "roundtrip various epochs" {
    // Test a spread of values across decades
    const epochs = [_]u64{
        1,
        60,
        3600,
        86400,
        31536000, // 1971-01-01
        315532800, // 1980-01-01
        631152000, // 1990-01-01
        1000000000, // 2001-09-09
        1234567890, // 2009-02-13
        1500000000, // 2017-07-14
        1700000000, // 2023-11-14
        1771770605, // 2026-02-22 14:30:05
        2000000000, // 2033-05-18
        3000000000, // 2065-01-24
        4000000000, // 2096-10-02
        4107542400, // 2100-03-01
    };
    for (epochs) |e| {
        try expectEqual(e, time.toEpoch(time.fromEpoch(e)));
    }
}

// ── Day of week ─────────────────────────────────────────────────────

test "DOW sequence across a week" {
    // 2026-02-16 is Monday (dow=1), check through Sunday
    const monday: u64 = 1771200000; // 2026-02-16 00:00:00
    const dow_names = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
    const expected_dow = [_]u8{ 1, 2, 3, 4, 5, 6, 0 };
    for (0..7) |i| {
        const dt = time.fromEpoch(monday + i * 86400);
        try expectEqual(expected_dow[i], dt.dow);
        try expectEqualStrings(dow_names[i], time.dowName(dt.dow));
    }
}

test "dowName out of range returns ???" {
    try expectEqualStrings("???", time.dowName(7));
    try expectEqualStrings("???", time.dowName(255));
}

// ── Month names ─────────────────────────────────────────────────────

test "monthName for all months" {
    const expected = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    for (expected, 1..) |name, i| {
        try expectEqualStrings(name, time.monthName(@intCast(i)));
    }
}

test "monthName out of range returns ???" {
    try expectEqualStrings("???", time.monthName(0));
    try expectEqualStrings("???", time.monthName(13));
}

// ── Formatting ──────────────────────────────────────────────────────

test "fmtDateTime produces YYYY-MM-DD HH:MM:SS" {
    const dt = time.fromEpoch(1771770605); // 2026-02-22 14:30:05
    var buf: [19]u8 = undefined;
    try expectEqualStrings("2026-02-22 14:30:05", time.fmtDateTime(dt, &buf));
}

test "fmtDateTime zero-pads single digits" {
    const dt = time.fromEpoch(0); // 1970-01-01 00:00:00
    var buf: [19]u8 = undefined;
    try expectEqualStrings("1970-01-01 00:00:00", time.fmtDateTime(dt, &buf));
}

test "fmtDate produces YYYY-MM-DD" {
    const dt = time.fromEpoch(1771770605);
    var buf: [10]u8 = undefined;
    try expectEqualStrings("2026-02-22", time.fmtDate(dt, &buf));
}

test "fmtTime produces HH:MM:SS" {
    const dt = time.fromEpoch(1771770605);
    var buf: [8]u8 = undefined;
    try expectEqualStrings("14:30:05", time.fmtTime(dt, &buf));
}

test "fmtTime midnight" {
    const dt = time.fromEpoch(946684800); // Y2K midnight
    var buf: [8]u8 = undefined;
    try expectEqualStrings("00:00:00", time.fmtTime(dt, &buf));
}

test "fmtDateTime buffer too small returns empty" {
    const dt = time.fromEpoch(0);
    var buf: [10]u8 = undefined;
    try expectEqualStrings("", time.fmtDateTime(dt, &buf));
}

test "fmtDate buffer too small returns empty" {
    const dt = time.fromEpoch(0);
    var buf: [5]u8 = undefined;
    try expectEqualStrings("", time.fmtDate(dt, &buf));
}

// ── fmtUptime ───────────────────────────────────────────────────────

test "fmtUptime zero seconds" {
    var buf: [32]u8 = undefined;
    try expectEqualStrings("0h 0m 0s", time.fmtUptime(0, &buf));
}

test "fmtUptime seconds only" {
    var buf: [32]u8 = undefined;
    try expectEqualStrings("0h 0m 45s", time.fmtUptime(45, &buf));
}

test "fmtUptime minutes and seconds" {
    var buf: [32]u8 = undefined;
    try expectEqualStrings("0h 5m 30s", time.fmtUptime(330, &buf));
}

test "fmtUptime hours" {
    var buf: [32]u8 = undefined;
    try expectEqualStrings("2h 30m 0s", time.fmtUptime(9000, &buf));
}

test "fmtUptime days" {
    var buf: [32]u8 = undefined;
    try expectEqualStrings("3d 4h 5m 6s", time.fmtUptime(3 * 86400 + 4 * 3600 + 5 * 60 + 6, &buf));
}

test "fmtUptime exactly one day" {
    var buf: [32]u8 = undefined;
    try expectEqualStrings("1d 0h 0m 0s", time.fmtUptime(86400, &buf));
}

// ── Leap year edge cases ────────────────────────────────────────────

test "Feb 29 exists in 2000 (leap, div by 400)" {
    // 2000-02-29 00:00:00 = 951782400
    const dt = time.fromEpoch(951782400);
    try expectEqual(@as(u32, 2000), dt.year);
    try expectEqual(@as(u8, 2), dt.month);
    try expectEqual(@as(u8, 29), dt.day);
}

test "Mar 1 after leap day 2000" {
    // 2000-03-01 00:00:00 = 951868800
    const dt = time.fromEpoch(951868800);
    try expectEqual(@as(u32, 2000), dt.year);
    try expectEqual(@as(u8, 3), dt.month);
    try expectEqual(@as(u8, 1), dt.day);
}

test "no Feb 29 in 1900 (not leap, div by 100)" {
    // 1900 is before epoch, test via 2100 instead
    // 2100-02-28 → 2100-03-01 (no Feb 29)
    // 2100-02-28 00:00:00
    const feb28: u64 = 4107456000;
    const dt28 = time.fromEpoch(feb28);
    try expectEqual(@as(u32, 2100), dt28.year);
    try expectEqual(@as(u8, 2), dt28.month);
    try expectEqual(@as(u8, 28), dt28.day);

    // Next day should be Mar 1, not Feb 29
    const dt_next = time.fromEpoch(feb28 + 86400);
    try expectEqual(@as(u32, 2100), dt_next.year);
    try expectEqual(@as(u8, 3), dt_next.month);
    try expectEqual(@as(u8, 1), dt_next.day);
}

test "yday on Dec 31 non-leap" {
    // 2025-12-31 00:00:00 = 1767139200
    const dt = time.fromEpoch(1767139200);
    try expectEqual(@as(u32, 2025), dt.year);
    try expectEqual(@as(u8, 12), dt.month);
    try expectEqual(@as(u8, 31), dt.day);
    try expectEqual(@as(u16, 364), dt.yday); // 0-indexed, 365 days = 0..364
}

test "yday on Dec 31 leap year" {
    // 2024-12-31 00:00:00 = 1735603200
    const dt = time.fromEpoch(1735603200);
    try expectEqual(@as(u32, 2024), dt.year);
    try expectEqual(@as(u8, 12), dt.month);
    try expectEqual(@as(u8, 31), dt.day);
    try expectEqual(@as(u16, 365), dt.yday); // 0-indexed, 366 days = 0..365
}

// ── Year boundary transitions ───────────────────────────────────────

test "Dec 31 to Jan 1 transition" {
    // 2025-12-31 23:59:59 → 2026-01-01 00:00:00
    const dec31: u64 = 1767225599;
    const jan1: u64 = 1767225600;

    const d1 = time.fromEpoch(dec31);
    try expectEqual(@as(u32, 2025), d1.year);
    try expectEqual(@as(u8, 12), d1.month);
    try expectEqual(@as(u8, 31), d1.day);
    try expectEqual(@as(u8, 23), d1.hour);
    try expectEqual(@as(u8, 59), d1.minute);
    try expectEqual(@as(u8, 59), d1.second);

    const d2 = time.fromEpoch(jan1);
    try expectEqual(@as(u32, 2026), d2.year);
    try expectEqual(@as(u8, 1), d2.month);
    try expectEqual(@as(u8, 1), d2.day);
    try expectEqual(@as(u8, 0), d2.hour);
    try expectEqual(@as(u8, 0), d2.minute);
    try expectEqual(@as(u8, 0), d2.second);
}
