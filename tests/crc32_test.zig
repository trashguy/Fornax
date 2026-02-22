const std = @import("std");
const crc32 = @import("crc32");

const expectEqual = std.testing.expectEqual;

fn makeCrc32() crc32.Crc32 {
    var c: crc32.Crc32 = undefined;
    c.init();
    return c;
}

// ── Known test vectors ──────────────────────────────────────────────

test "CRC32 of '123456789'" {
    const c = makeCrc32();
    try expectEqual(@as(u32, 0xCBF43926), c.compute("123456789"));
}

test "CRC32 of empty input" {
    const c = makeCrc32();
    try expectEqual(@as(u32, 0x00000000), c.compute(""));
}

test "CRC32 of single byte" {
    const c = makeCrc32();
    // CRC32('a') = 0xE8B7BE43
    try expectEqual(@as(u32, 0xE8B7BE43), c.compute("a"));
}

// ── Incremental update ──────────────────────────────────────────────

test "CRC32 incremental matches single-shot" {
    const c = makeCrc32();
    const data = "123456789";
    const single = c.compute(data);

    // Split into two updates
    const partial = c.update(0, data[0..5]);
    const full = c.update(partial, data[5..]);
    try expectEqual(single, full);
}

test "CRC32 incremental byte-by-byte" {
    const c = makeCrc32();
    const data = "Hello, world!";
    const single = c.compute(data);

    var running: u32 = 0;
    for (data) |byte| {
        running = c.update(running, &[_]u8{byte});
    }
    try expectEqual(single, running);
}
