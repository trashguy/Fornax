// SHA-256 (FIPS 180-4) — streaming init/update/final API.
// Struct is 112 bytes, stack-allocatable. No allocation.

pub const Sha256 = struct {
    state: [8]u32,
    buf: [64]u8,
    buf_len: usize,
    total_len: u64,

    const K = [64]u32{
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    };

    const H0 = [8]u32{
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    };

    pub fn init() Sha256 {
        return .{
            .state = H0,
            .buf = undefined,
            .buf_len = 0,
            .total_len = 0,
        };
    }

    pub fn update(self: *Sha256, data: []const u8) void {
        var off: usize = 0;
        self.total_len += data.len;

        // Fill partial buffer
        if (self.buf_len > 0) {
            const need = 64 - self.buf_len;
            const take = @min(need, data.len);
            @memcpy(self.buf[self.buf_len..][0..take], data[0..take]);
            self.buf_len += take;
            off = take;
            if (self.buf_len == 64) {
                compress(&self.state, &self.buf);
                self.buf_len = 0;
            }
        }

        // Process full blocks
        while (off + 64 <= data.len) {
            compress(&self.state, data[off..][0..64]);
            off += 64;
        }

        // Buffer remainder
        const rem = data.len - off;
        if (rem > 0) {
            @memcpy(self.buf[0..rem], data[off..][0..rem]);
            self.buf_len = rem;
        }
    }

    pub fn final(self: *Sha256) [32]u8 {
        const bit_len = self.total_len * 8;

        // Pad with 0x80
        self.buf[self.buf_len] = 0x80;
        self.buf_len += 1;

        // If not enough room for 8-byte length, pad this block and compress
        if (self.buf_len > 56) {
            @memset(self.buf[self.buf_len..], 0);
            compress(&self.state, &self.buf);
            self.buf_len = 0;
        }

        // Zero-pad to byte 56
        @memset(self.buf[self.buf_len..56], 0);

        // Append 64-bit big-endian length
        self.buf[56] = @intCast((bit_len >> 56) & 0xFF);
        self.buf[57] = @intCast((bit_len >> 48) & 0xFF);
        self.buf[58] = @intCast((bit_len >> 40) & 0xFF);
        self.buf[59] = @intCast((bit_len >> 32) & 0xFF);
        self.buf[60] = @intCast((bit_len >> 24) & 0xFF);
        self.buf[61] = @intCast((bit_len >> 16) & 0xFF);
        self.buf[62] = @intCast((bit_len >> 8) & 0xFF);
        self.buf[63] = @intCast(bit_len & 0xFF);

        compress(&self.state, &self.buf);

        // Produce big-endian digest
        var digest: [32]u8 = undefined;
        for (0..8) |i| {
            digest[i * 4 + 0] = @intCast((self.state[i] >> 24) & 0xFF);
            digest[i * 4 + 1] = @intCast((self.state[i] >> 16) & 0xFF);
            digest[i * 4 + 2] = @intCast((self.state[i] >> 8) & 0xFF);
            digest[i * 4 + 3] = @intCast(self.state[i] & 0xFF);
        }
        return digest;
    }

    /// One-shot convenience.
    pub fn hash(data: []const u8) [32]u8 {
        var ctx = Sha256.init();
        ctx.update(data);
        return ctx.final();
    }
};

/// Format a 32-byte digest as 64-char lowercase hex.
pub fn hexDigest(digest: *const [32]u8, out: *[64]u8) void {
    const hex = "0123456789abcdef";
    for (0..32) |i| {
        out[i * 2] = hex[digest[i] >> 4];
        out[i * 2 + 1] = hex[digest[i] & 0x0F];
    }
}

fn rotr(x: u32, comptime n: u5) u32 {
    return (x >> n) | (x << (32 - n));
}

fn compress(state: *[8]u32, block: *const [64]u8) void {
    // Prepare message schedule
    var w: [64]u32 = undefined;
    for (0..16) |i| {
        w[i] = @as(u32, block[i * 4]) << 24 |
            @as(u32, block[i * 4 + 1]) << 16 |
            @as(u32, block[i * 4 + 2]) << 8 |
            @as(u32, block[i * 4 + 3]);
    }
    for (16..64) |i| {
        const s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
        const s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] +% s0 +% w[i - 7] +% s1;
    }

    var a = state[0];
    var b = state[1];
    var c = state[2];
    var d = state[3];
    var e = state[4];
    var f = state[5];
    var g = state[6];
    var h = state[7];

    for (0..64) |i| {
        const S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
        const ch = (e & f) ^ (~e & g);
        const temp1 = h +% S1 +% ch +% Sha256.K[i] +% w[i];
        const S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
        const maj = (a & b) ^ (a & c) ^ (b & c);
        const temp2 = S0 +% maj;

        h = g;
        g = f;
        f = e;
        e = d +% temp1;
        d = c;
        c = b;
        b = a;
        a = temp1 +% temp2;
    }

    state[0] +%= a;
    state[1] +%= b;
    state[2] +%= c;
    state[3] +%= d;
    state[4] +%= e;
    state[5] +%= f;
    state[6] +%= g;
    state[7] +%= h;
}
