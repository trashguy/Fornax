// CRC32 (ISO 3309 / ITU-T V.42) with 1 KB lookup table.
// Caller owns the table buffer (place in BSS).

pub const Crc32 = struct {
    table: [256]u32,

    pub fn init(self: *Crc32) void {
        for (0..256) |i| {
            var c: u32 = @intCast(i);
            for (0..8) |_| {
                if (c & 1 != 0) {
                    c = 0xEDB88320 ^ (c >> 1);
                } else {
                    c = c >> 1;
                }
            }
            self.table[i] = c;
        }
    }

    pub fn update(self: *const Crc32, crc: u32, data: []const u8) u32 {
        var c = crc ^ 0xFFFFFFFF;
        for (data) |b| {
            c = self.table[(c ^ b) & 0xFF] ^ (c >> 8);
        }
        return c ^ 0xFFFFFFFF;
    }

    pub fn compute(self: *const Crc32, data: []const u8) u32 {
        return self.update(0, data);
    }
};
