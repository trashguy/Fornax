// USTAR tar header parsing and creation.
// No allocation — all operations work on caller-provided buffers.

pub const HEADER_SIZE = 512;

/// Wraps a raw 512-byte tar header block.
pub const Header = struct {
    raw: *const [HEADER_SIZE]u8,

    /// Extract the filename, joining prefix + name fields.
    /// Uses `scratch` for concatenation when prefix is present.
    pub fn name(self: Header, scratch: []u8) []const u8 {
        var prefix_len: usize = 0;
        if (self.raw[345] != 0) {
            while (prefix_len < 155 and self.raw[345 + prefix_len] != 0) : (prefix_len += 1) {}
        }

        var name_len: usize = 0;
        while (name_len < 100 and self.raw[name_len] != 0) : (name_len += 1) {}

        if (prefix_len > 0) {
            const total = prefix_len + 1 + name_len;
            if (total <= scratch.len) {
                @memcpy(scratch[0..prefix_len], self.raw[345..][0..prefix_len]);
                scratch[prefix_len] = '/';
                @memcpy(scratch[prefix_len + 1 ..][0..name_len], self.raw[0..name_len]);
                return scratch[0..total];
            }
        }

        return self.raw[0..name_len];
    }

    pub fn size(self: Header) u64 {
        return parseOctal(self.raw[124..136]);
    }

    pub fn mode(self: Header) u32 {
        return @intCast(parseOctal(self.raw[100..108]));
    }

    pub fn uid(self: Header) u16 {
        return @intCast(parseOctal(self.raw[108..116]));
    }

    pub fn gid(self: Header) u16 {
        return @intCast(parseOctal(self.raw[116..124]));
    }

    pub fn typeflag(self: Header) u8 {
        return self.raw[156];
    }

    pub fn validateChecksum(self: Header) bool {
        const stored = parseOctal(self.raw[148..156]);
        const actual = computeChecksum(@constCast(self.raw));
        return stored == actual;
    }
};

pub fn parseOctal(buf: []const u8) u64 {
    var val: u64 = 0;
    for (buf) |c| {
        if (c == 0 or c == ' ') continue;
        if (c < '0' or c > '7') break;
        val = (val << 3) + (c - '0');
    }
    return val;
}

pub fn writeOctal(buf: []u8, val: u64) void {
    var v = val;
    var i: usize = buf.len;
    if (i > 0) {
        i -= 1;
        buf[i] = 0;
    }
    while (i > 0) {
        i -= 1;
        buf[i] = @intCast('0' + (v & 7));
        v >>= 3;
    }
}

pub fn computeChecksum(header: *[HEADER_SIZE]u8) u32 {
    var sum: u32 = 0;
    for (0..HEADER_SIZE) |i| {
        if (i >= 148 and i < 156) {
            sum += ' ';
        } else {
            sum += header[i];
        }
    }
    return sum;
}

pub fn fillHeader(header: *[HEADER_SIZE]u8, file_name: []const u8, file_size: u64, file_mode: u32, file_uid: u16, file_gid: u16, type_flag: u8) void {
    @memset(header, 0);

    if (file_name.len > 100) {
        var split: usize = 0;
        var i: usize = @min(file_name.len - 1, 155);
        while (i > 0) : (i -= 1) {
            if (file_name[i] == '/') {
                split = i;
                break;
            }
        }
        if (split > 0 and file_name.len - split - 1 <= 100) {
            const prefix_len = @min(split, 155);
            @memcpy(header[345..][0..prefix_len], file_name[0..prefix_len]);
            const rest = file_name[split + 1 ..];
            const rest_len = @min(rest.len, 100);
            @memcpy(header[0..rest_len], rest[0..rest_len]);
        } else {
            @memcpy(header[0..100], file_name[0..100]);
        }
    } else {
        const len = @min(file_name.len, 100);
        @memcpy(header[0..len], file_name[0..len]);
    }

    writeOctal(header[100..108], file_mode);
    writeOctal(header[108..116], file_uid);
    writeOctal(header[116..124], file_gid);
    writeOctal(header[124..136], file_size);
    writeOctal(header[136..148], 0); // mtime
    header[156] = type_flag;
    // magic "ustar\0"
    header[257] = 'u';
    header[258] = 's';
    header[259] = 't';
    header[260] = 'a';
    header[261] = 'r';
    header[262] = 0;
    // version "00"
    header[263] = '0';
    header[264] = '0';

    const cksum = computeChecksum(header);
    writeOctal(header[148..155], cksum);
    header[155] = ' ';
}

pub fn isZeroBlock(block: *const [HEADER_SIZE]u8) bool {
    for (block) |b| {
        if (b != 0) return false;
    }
    return true;
}

pub fn isSafePath(file_name: []const u8) bool {
    if (file_name.len == 0) return false;
    if (file_name[0] == '/') return false;
    var i: usize = 0;
    while (i + 2 < file_name.len) : (i += 1) {
        if (file_name[i] == '.' and file_name[i + 1] == '.' and file_name[i + 2] == '/') return false;
    }
    if (file_name.len >= 2 and file_name[file_name.len - 2] == '.' and file_name[file_name.len - 1] == '.') return false;
    return true;
}
