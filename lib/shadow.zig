/// Fornax /etc/shadow parser.
///
/// Format: username:hash
/// One entry per line. Fields separated by ':'.
/// File should be mode 0600 (root-only readable).

const syscall = @import("syscall.zig");

pub const ShadowEntry = struct {
    username: [32]u8 = .{0} ** 32,
    username_len: u8 = 0,
    hash: [48]u8 = .{0} ** 48,
    hash_len: u8 = 0,

    pub fn usernameSlice(self: *const ShadowEntry) []const u8 {
        return self.username[0..self.username_len];
    }

    pub fn hashSlice(self: *const ShadowEntry) []const u8 {
        return self.hash[0..self.hash_len];
    }
};

fn copyField(dest: []u8, src: []const u8) u8 {
    const len = @min(src.len, dest.len);
    @memcpy(dest[0..len], src[0..len]);
    return @truncate(len);
}

/// Parse a single shadow line into a ShadowEntry.
pub fn parseLine(line: []const u8) ?ShadowEntry {
    var entry: ShadowEntry = .{};

    // Find the first ':'
    var colon: usize = 0;
    while (colon < line.len and line[colon] != ':') : (colon += 1) {}
    if (colon == 0 or colon >= line.len) return null;

    entry.username_len = copyField(&entry.username, line[0..colon]);
    entry.hash_len = copyField(&entry.hash, line[colon + 1 ..]);

    return entry;
}

/// Format a ShadowEntry as "username:hash\n".
pub fn formatLine(buf: []u8, entry: *const ShadowEntry) ?[]const u8 {
    var pos: usize = 0;
    const uname = entry.usernameSlice();
    if (pos + uname.len + 1 > buf.len) return null;
    @memcpy(buf[pos..][0..uname.len], uname);
    pos += uname.len;
    buf[pos] = ':';
    pos += 1;

    const hash = entry.hashSlice();
    if (pos + hash.len + 1 > buf.len) return null;
    @memcpy(buf[pos..][0..hash.len], hash);
    pos += hash.len;
    buf[pos] = '\n';
    pos += 1;

    return buf[0..pos];
}

var file_buf: [4096]u8 linksection(".bss") = undefined;

/// Look up a shadow entry by username.
pub fn lookupByName(username: []const u8) ?ShadowEntry {
    const fd = syscall.open("/etc/shadow");
    if (fd < 0) return null;
    defer _ = syscall.close(fd);

    const n = syscall.read(fd, &file_buf);
    if (n <= 0) return null;

    const data = file_buf[0..@intCast(n)];
    var start: usize = 0;
    for (data, 0..) |c, i| {
        if (c == '\n') {
            if (parseLine(data[start..i])) |entry| {
                if (eqlSlice(entry.usernameSlice(), username)) return entry;
            }
            start = i + 1;
        }
    }
    if (start < data.len) {
        if (parseLine(data[start..])) |entry| {
            if (eqlSlice(entry.usernameSlice(), username)) return entry;
        }
    }
    return null;
}

fn eqlSlice(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}
