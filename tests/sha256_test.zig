const std = @import("std");
const sha256 = @import("sha256");

const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;

fn hexToBytes(comptime hex: []const u8) [hex.len / 2]u8 {
    var result: [hex.len / 2]u8 = undefined;
    for (0..hex.len / 2) |i| {
        result[i] = @as(u8, hexChar(hex[i * 2])) << 4 | hexChar(hex[i * 2 + 1]);
    }
    return result;
}

fn hexChar(c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        else => 0,
    };
}

// ── NIST test vectors ───────────────────────────────────────────────

test "SHA-256 of empty string" {
    const expected = hexToBytes("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    const digest = sha256.Sha256.hash("");
    try expectEqualSlices(u8, &expected, &digest);
}

test "SHA-256 of 'abc'" {
    const expected = hexToBytes("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    const digest = sha256.Sha256.hash("abc");
    try expectEqualSlices(u8, &expected, &digest);
}

test "SHA-256 two-block message" {
    // NIST: "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
    const expected = hexToBytes("248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
    const digest = sha256.Sha256.hash("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq");
    try expectEqualSlices(u8, &expected, &digest);
}

// ── Streaming matches single-shot ───────────────────────────────────

test "SHA-256 streaming matches hash" {
    const data = "The quick brown fox jumps over the lazy dog";
    const single = sha256.Sha256.hash(data);

    var ctx = sha256.Sha256.init();
    ctx.update(data[0..10]);
    ctx.update(data[10..30]);
    ctx.update(data[30..]);
    const streamed = ctx.final();

    try expectEqualSlices(u8, &single, &streamed);
}

test "SHA-256 streaming byte-by-byte" {
    const data = "abc";
    const single = sha256.Sha256.hash(data);

    var ctx = sha256.Sha256.init();
    for (data) |byte| {
        ctx.update(&[_]u8{byte});
    }
    const streamed = ctx.final();

    try expectEqualSlices(u8, &single, &streamed);
}

// ── hexDigest ───────────────────────────────────────────────────────

test "hexDigest produces correct hex string" {
    const digest = sha256.Sha256.hash("abc");
    var hex: [64]u8 = undefined;
    sha256.hexDigest(&digest, &hex);

    try expectEqualSlices(u8, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", &hex);
}
