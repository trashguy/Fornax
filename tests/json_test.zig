const std = @import("std");
const json = @import("json");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

// ── Empty structures ────────────────────────────────────────────────

test "parse empty object" {
    var p = json.Parser.init("{}");
    try expectEqual(json.TokenKind.object_begin, p.next().kind);
    try expectEqual(json.TokenKind.object_end, p.next().kind);
    try expectEqual(json.TokenKind.eof, p.next().kind);
}

test "parse empty array" {
    var p = json.Parser.init("[]");
    try expectEqual(json.TokenKind.array_begin, p.next().kind);
    try expectEqual(json.TokenKind.array_end, p.next().kind);
    try expectEqual(json.TokenKind.eof, p.next().kind);
}

// ── Key-value pair ──────────────────────────────────────────────────

test "parse key-value pair" {
    var p = json.Parser.init("{\"key\": \"value\"}");

    try expectEqual(json.TokenKind.object_begin, p.next().kind);

    const key = p.next();
    try expectEqual(json.TokenKind.string, key.kind);
    try expectEqualStrings("key", key.str_value);

    try expectEqual(json.TokenKind.colon, p.next().kind);

    const val = p.next();
    try expectEqual(json.TokenKind.string, val.kind);
    try expectEqualStrings("value", val.str_value);

    try expectEqual(json.TokenKind.object_end, p.next().kind);
}

// ── Numbers ─────────────────────────────────────────────────────────

test "parse positive number" {
    var p = json.Parser.init("42");
    const tok = p.next();
    try expectEqual(json.TokenKind.number, tok.kind);
    try expectEqual(@as(i64, 42), tok.int_value);
}

test "parse negative number" {
    var p = json.Parser.init("-7");
    const tok = p.next();
    try expectEqual(json.TokenKind.number, tok.kind);
    try expectEqual(@as(i64, -7), tok.int_value);
}

test "parse zero" {
    var p = json.Parser.init("0");
    const tok = p.next();
    try expectEqual(json.TokenKind.number, tok.kind);
    try expectEqual(@as(i64, 0), tok.int_value);
}

// ── Booleans and null ───────────────────────────────────────────────

test "parse true" {
    var p = json.Parser.init("true");
    try expectEqual(json.TokenKind.true_val, p.next().kind);
}

test "parse false" {
    var p = json.Parser.init("false");
    try expectEqual(json.TokenKind.false_val, p.next().kind);
}

test "parse null" {
    var p = json.Parser.init("null");
    try expectEqual(json.TokenKind.null_val, p.next().kind);
}

// ── Nested structure ────────────────────────────────────────────────

test "parse nested object" {
    var p = json.Parser.init("{\"a\": {\"b\": 1}}");

    try expectEqual(json.TokenKind.object_begin, p.next().kind);

    const key_a = p.next();
    try expectEqual(json.TokenKind.string, key_a.kind);
    try expectEqualStrings("a", key_a.str_value);

    try expectEqual(json.TokenKind.colon, p.next().kind);
    try expectEqual(json.TokenKind.object_begin, p.next().kind);

    const key_b = p.next();
    try expectEqual(json.TokenKind.string, key_b.kind);
    try expectEqualStrings("b", key_b.str_value);

    try expectEqual(json.TokenKind.colon, p.next().kind);

    const val = p.next();
    try expectEqual(json.TokenKind.number, val.kind);
    try expectEqual(@as(i64, 1), val.int_value);

    try expectEqual(json.TokenKind.object_end, p.next().kind);
    try expectEqual(json.TokenKind.object_end, p.next().kind);
}

test "parse array with values" {
    var p = json.Parser.init("[1, \"two\", true, null]");

    try expectEqual(json.TokenKind.array_begin, p.next().kind);

    const n = p.next();
    try expectEqual(json.TokenKind.number, n.kind);
    try expectEqual(@as(i64, 1), n.int_value);

    try expectEqual(json.TokenKind.comma, p.next().kind);

    const s = p.next();
    try expectEqual(json.TokenKind.string, s.kind);
    try expectEqualStrings("two", s.str_value);

    try expectEqual(json.TokenKind.comma, p.next().kind);
    try expectEqual(json.TokenKind.true_val, p.next().kind);
    try expectEqual(json.TokenKind.comma, p.next().kind);
    try expectEqual(json.TokenKind.null_val, p.next().kind);
    try expectEqual(json.TokenKind.array_end, p.next().kind);
}

// ── skipValue ───────────────────────────────────────────────────────

test "skipValue: skip nested object" {
    var p = json.Parser.init("{\"a\": {\"b\": [1, 2]}, \"c\": 3}");

    try expectEqual(json.TokenKind.object_begin, p.next().kind);
    const key_a = p.next();
    try expectEqualStrings("a", key_a.str_value);
    try expectEqual(json.TokenKind.colon, p.next().kind);
    try expect(p.skipValue()); // skip {"b": [1, 2]}

    try expectEqual(json.TokenKind.comma, p.next().kind);
    const key_c = p.next();
    try expectEqualStrings("c", key_c.str_value);
    try expectEqual(json.TokenKind.colon, p.next().kind);
    const val = p.next();
    try expectEqual(@as(i64, 3), val.int_value);
}

// ── findKey ─────────────────────────────────────────────────────────

test "findKey: locate key in object" {
    var p = json.Parser.init("{\"name\": \"fornax\", \"version\": 1}");
    try expectEqual(json.TokenKind.object_begin, p.next().kind);

    try expect(p.findKey("version"));
    const val = p.next();
    try expectEqual(json.TokenKind.number, val.kind);
    try expectEqual(@as(i64, 1), val.int_value);
}

test "findKey: key not found" {
    var p = json.Parser.init("{\"name\": \"fornax\"}");
    try expectEqual(json.TokenKind.object_begin, p.next().kind);
    try expect(!p.findKey("missing"));
}

// ── Error handling ──────────────────────────────────────────────────

test "parse invalid character produces error" {
    var p = json.Parser.init("@");
    try expectEqual(json.TokenKind.err, p.next().kind);
}

test "parse unterminated string produces error" {
    var p = json.Parser.init("\"hello");
    try expectEqual(json.TokenKind.err, p.next().kind);
}

// ── Convenience methods ─────────────────────────────────────────────

test "expectString" {
    var p = json.Parser.init("\"hello\"");
    const val = p.expectString();
    try expect(val != null);
    try expectEqualStrings("hello", val.?);
}

test "expectInt" {
    var p = json.Parser.init("42");
    const val = p.expectInt();
    try expect(val != null);
    try expectEqual(@as(i64, 42), val.?);
}

// ── Whitespace handling ─────────────────────────────────────────────

test "parse with varied whitespace" {
    var p = json.Parser.init("  {\n\t\"key\" : \r\n 42 \n} ");
    try expectEqual(json.TokenKind.object_begin, p.next().kind);
    try expectEqual(json.TokenKind.string, p.next().kind);
    try expectEqual(json.TokenKind.colon, p.next().kind);
    const val = p.next();
    try expectEqual(@as(i64, 42), val.int_value);
    try expectEqual(json.TokenKind.object_end, p.next().kind);
}
