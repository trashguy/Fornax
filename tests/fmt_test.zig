const std = @import("std");
const fmt = @import("fmt");

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

// ── formatDec ───────────────────────────────────────────────────────

test "formatDec: zero" {
    var buf: [20]u8 = undefined;
    try expectEqualStrings("0", fmt.formatDec(&buf, 0));
}

test "formatDec: single digit" {
    var buf: [20]u8 = undefined;
    try expectEqualStrings("1", fmt.formatDec(&buf, 1));
}

test "formatDec: 42" {
    var buf: [20]u8 = undefined;
    try expectEqualStrings("42", fmt.formatDec(&buf, 42));
}

test "formatDec: 1000000" {
    var buf: [20]u8 = undefined;
    try expectEqualStrings("1000000", fmt.formatDec(&buf, 1000000));
}

test "formatDec: max u64" {
    var buf: [20]u8 = undefined;
    try expectEqualStrings("18446744073709551615", fmt.formatDec(&buf, std.math.maxInt(u64)));
}

// ── formatDecSigned ─────────────────────────────────────────────────

test "formatDecSigned: positive" {
    var buf: [21]u8 = undefined;
    try expectEqualStrings("42", fmt.formatDecSigned(&buf, 42));
}

test "formatDecSigned: zero" {
    var buf: [21]u8 = undefined;
    try expectEqualStrings("0", fmt.formatDecSigned(&buf, 0));
}

test "formatDecSigned: negative" {
    var buf: [21]u8 = undefined;
    try expectEqualStrings("-1", fmt.formatDecSigned(&buf, -1));
}

test "formatDecSigned: negative large" {
    var buf: [21]u8 = undefined;
    try expectEqualStrings("-12345", fmt.formatDecSigned(&buf, -12345));
}

// ── formatHex ───────────────────────────────────────────────────────

test "formatHex: zero" {
    var buf: [16]u8 = undefined;
    try expectEqualStrings("0", fmt.formatHex(&buf, 0));
}

test "formatHex: 0xFF" {
    var buf: [16]u8 = undefined;
    try expectEqualStrings("ff", fmt.formatHex(&buf, 0xFF));
}

test "formatHex: 0xDEADBEEF" {
    var buf: [16]u8 = undefined;
    try expectEqualStrings("deadbeef", fmt.formatHex(&buf, 0xDEADBEEF));
}

test "formatHex: 1" {
    var buf: [16]u8 = undefined;
    try expectEqualStrings("1", fmt.formatHex(&buf, 1));
}
