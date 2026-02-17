/// Fornax password hashing — FNV-1a 64-bit, salted, iterated.
///
/// Hash format: $fx$SSSSSSSS$HHHHHHHHHHHHHHHH
///   salt = 8 hex chars (32-bit), hash = 16 hex chars (64-bit)
/// Special value "x" means no password required.

const syscall = @import("syscall.zig");

const hex_chars = "0123456789abcdef";

/// FNV-1a 64-bit hash.
fn fnv1a(data: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (data) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

/// Hash password with a given 32-bit salt, iterated 100 times.
fn hashWithSalt(password: []const u8, salt: u32) u64 {
    // Initial: hash salt bytes + password
    var salt_bytes: [4]u8 = undefined;
    salt_bytes[0] = @truncate(salt);
    salt_bytes[1] = @truncate(salt >> 8);
    salt_bytes[2] = @truncate(salt >> 16);
    salt_bytes[3] = @truncate(salt >> 24);

    // Combine salt + password into a temp buffer
    var combined: [256]u8 = undefined;
    if (4 + password.len > combined.len) return 0;
    @memcpy(combined[0..4], &salt_bytes);
    @memcpy(combined[4..][0..password.len], password);
    var h = fnv1a(combined[0 .. 4 + password.len]);

    // Iterate 99 more times, feeding hash bytes back
    for (0..99) |_| {
        var hash_bytes: [8]u8 = undefined;
        hash_bytes[0] = @truncate(h);
        hash_bytes[1] = @truncate(h >> 8);
        hash_bytes[2] = @truncate(h >> 16);
        hash_bytes[3] = @truncate(h >> 24);
        hash_bytes[4] = @truncate(h >> 32);
        hash_bytes[5] = @truncate(h >> 40);
        hash_bytes[6] = @truncate(h >> 48);
        hash_bytes[7] = @truncate(h >> 56);
        h = fnv1a(&hash_bytes);
    }
    return h;
}

/// Encode a u64 as 16 hex chars.
fn hexEncode64(buf: *[16]u8, val: u64) void {
    var v = val;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        buf[i] = hex_chars[@as(usize, @truncate(v & 0xF))];
        v >>= 4;
    }
}

/// Encode a u32 as 8 hex chars.
fn hexEncode32(buf: *[8]u8, val: u32) void {
    var v = val;
    var i: usize = 8;
    while (i > 0) {
        i -= 1;
        buf[i] = hex_chars[@as(usize, @intCast(v & 0xF))];
        v >>= 4;
    }
}

/// Decode a hex char to its 4-bit value.
fn hexVal(c: u8) ?u4 {
    if (c >= '0' and c <= '9') return @truncate(c - '0');
    if (c >= 'a' and c <= 'f') return @truncate(c - 'a' + 10);
    if (c >= 'A' and c <= 'F') return @truncate(c - 'A' + 10);
    return null;
}

/// Decode 8 hex chars to u32.
fn hexDecode32(s: []const u8) ?u32 {
    if (s.len != 8) return null;
    var val: u32 = 0;
    for (s) |c| {
        val = (val << 4) | @as(u32, hexVal(c) orelse return null);
    }
    return val;
}

/// Decode 16 hex chars to u64.
fn hexDecode64(s: []const u8) ?u64 {
    if (s.len != 16) return null;
    var val: u64 = 0;
    for (s) |c| {
        val = (val << 4) | @as(u64, hexVal(c) orelse return null);
    }
    return val;
}

/// Hash a password, generating a random salt from sysinfo uptime + getpid.
/// Returns the formatted hash string in buf: "$fx$SSSSSSSS$HHHHHHHHHHHHHHHH"
pub fn hashPassword(buf: *[39]u8, password: []const u8) []const u8 {
    // Generate salt from uptime + pid
    const info = syscall.sysinfo();
    const pid = syscall.getpid();
    const salt: u32 = if (info) |si|
        @truncate(si.uptime_secs *% 1000003 +% pid)
    else
        pid *% 2654435761;

    const h = hashWithSalt(password, salt);

    // Format: $fx$SSSSSSSS$HHHHHHHHHHHHHHHH
    buf[0] = '$';
    buf[1] = 'f';
    buf[2] = 'x';
    buf[3] = '$';
    hexEncode32(buf[4..12], salt);
    buf[12] = '$';
    hexEncode64(buf[13..29], h);
    // The full hash is 29 chars
    return buf[0..29];
}

/// Verify a password against a stored hash.
/// Returns true if the password matches.
/// If stored_hash is "x", always returns true (no password).
pub fn verifyPassword(stored_hash: []const u8, password: []const u8) bool {
    // "x" means no password required
    if (stored_hash.len == 1 and stored_hash[0] == 'x') return true;

    // Must be "$fx$SSSSSSSS$HHHHHHHHHHHHHHHH" = 29 chars
    if (stored_hash.len != 29) return false;
    if (stored_hash[0] != '$' or stored_hash[1] != 'f' or stored_hash[2] != 'x' or stored_hash[3] != '$') return false;
    if (stored_hash[12] != '$') return false;

    const salt = hexDecode32(stored_hash[4..12]) orelse return false;
    const expected = hexDecode64(stored_hash[13..29]) orelse return false;

    const actual = hashWithSalt(password, salt);
    return actual == expected;
}
