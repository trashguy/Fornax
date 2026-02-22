const std = @import("std");
const str = @import("str");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

// ── eql ─────────────────────────────────────────────────────────────

test "eql: equal strings" {
    try expect(str.eql("hello", "hello"));
}

test "eql: not equal" {
    try expect(!str.eql("hello", "world"));
}

test "eql: different lengths" {
    try expect(!str.eql("hi", "hello"));
}

test "eql: empty strings" {
    try expect(str.eql("", ""));
}

// ── startsWith / endsWith ───────────────────────────────────────────

test "startsWith: match" {
    try expect(str.startsWith("hello world", "hello"));
}

test "startsWith: no match" {
    try expect(!str.startsWith("hello", "world"));
}

test "startsWith: empty prefix" {
    try expect(str.startsWith("hello", ""));
}

test "startsWith: prefix longer than string" {
    try expect(!str.startsWith("hi", "hello"));
}

test "endsWith: match" {
    try expect(str.endsWith("hello world", "world"));
}

test "endsWith: no match" {
    try expect(!str.endsWith("hello", "world"));
}

test "endsWith: empty suffix" {
    try expect(str.endsWith("hello", ""));
}

// ── indexOf / indexOfSlice ──────────────────────────────────────────

test "indexOf: found" {
    try expectEqual(@as(?usize, 5), str.indexOf("hello world", ' '));
}

test "indexOf: not found" {
    try expectEqual(@as(?usize, null), str.indexOf("hello", 'z'));
}

test "indexOf: first char" {
    try expectEqual(@as(?usize, 0), str.indexOf("abc", 'a'));
}

test "indexOfSlice: found" {
    try expectEqual(@as(?usize, 6), str.indexOfSlice("hello world", "world"));
}

test "indexOfSlice: not found" {
    try expectEqual(@as(?usize, null), str.indexOfSlice("hello", "xyz"));
}

test "indexOfSlice: empty needle" {
    try expectEqual(@as(?usize, 0), str.indexOfSlice("hello", ""));
}

test "indexOfSlice: needle longer than haystack" {
    try expectEqual(@as(?usize, null), str.indexOfSlice("hi", "hello"));
}

// ── tokenize ────────────────────────────────────────────────────────

test "tokenize: simple" {
    var tokens: [10][]const u8 = undefined;
    const count = str.tokenize("hello world foo", &tokens);
    try expectEqual(@as(usize, 3), count);
    try expectEqualStrings("hello", tokens[0]);
    try expectEqualStrings("world", tokens[1]);
    try expectEqualStrings("foo", tokens[2]);
}

test "tokenize: leading/trailing whitespace" {
    var tokens: [10][]const u8 = undefined;
    const count = str.tokenize("  hello  world  ", &tokens);
    try expectEqual(@as(usize, 2), count);
    try expectEqualStrings("hello", tokens[0]);
    try expectEqualStrings("world", tokens[1]);
}

test "tokenize: tabs" {
    var tokens: [10][]const u8 = undefined;
    const count = str.tokenize("a\tb\tc", &tokens);
    try expectEqual(@as(usize, 3), count);
    try expectEqualStrings("a", tokens[0]);
    try expectEqualStrings("b", tokens[1]);
    try expectEqualStrings("c", tokens[2]);
}

test "tokenize: empty string" {
    var tokens: [10][]const u8 = undefined;
    const count = str.tokenize("", &tokens);
    try expectEqual(@as(usize, 0), count);
}

// ── parseUint ───────────────────────────────────────────────────────

test "parseUint: valid" {
    try expectEqual(@as(?u64, 12345), str.parseUint("12345"));
}

test "parseUint: zero" {
    try expectEqual(@as(?u64, 0), str.parseUint("0"));
}

test "parseUint: invalid chars" {
    try expectEqual(@as(?u64, null), str.parseUint("12a34"));
}

test "parseUint: empty" {
    try expectEqual(@as(?u64, null), str.parseUint(""));
}

// ── trim / trimRight ────────────────────────────────────────────────

test "trim: whitespace" {
    try expectEqualStrings("hello", str.trim("  hello  "));
}

test "trim: newlines" {
    try expectEqualStrings("hello", str.trim("\n\thello\r\n"));
}

test "trim: no whitespace" {
    try expectEqualStrings("hello", str.trim("hello"));
}

test "trim: all whitespace" {
    try expectEqualStrings("", str.trim("   "));
}

test "trimRight: trailing whitespace" {
    try expectEqualStrings("  hello", str.trimRight("  hello  "));
}

test "trimRight: no trailing whitespace" {
    try expectEqualStrings("hello", str.trimRight("hello"));
}
