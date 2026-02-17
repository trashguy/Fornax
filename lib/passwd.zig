/// Fornax /etc/passwd parser.
///
/// Format: username:password_hash:uid:gid:gecos:home:shell
/// One entry per line. Fields separated by ':'.

const syscall = @import("syscall.zig");
const fmt = @import("fmt.zig");

pub const PasswdEntry = struct {
    username: [32]u8 = .{0} ** 32,
    username_len: u8 = 0,
    hash: [48]u8 = .{0} ** 48,
    hash_len: u8 = 0,
    gecos: [64]u8 = .{0} ** 64,
    gecos_len: u8 = 0,
    home: [64]u8 = .{0} ** 64,
    home_len: u8 = 0,
    shell: [64]u8 = .{0} ** 64,
    shell_len: u8 = 0,
    uid: u16 = 0,
    gid: u16 = 0,

    pub fn usernameSlice(self: *const PasswdEntry) []const u8 {
        return self.username[0..self.username_len];
    }

    pub fn hashSlice(self: *const PasswdEntry) []const u8 {
        return self.hash[0..self.hash_len];
    }

    pub fn gecosSlice(self: *const PasswdEntry) []const u8 {
        return self.gecos[0..self.gecos_len];
    }

    pub fn homeSlice(self: *const PasswdEntry) []const u8 {
        return self.home[0..self.home_len];
    }

    pub fn shellSlice(self: *const PasswdEntry) []const u8 {
        return self.shell[0..self.shell_len];
    }
};

fn copyField(dest: []u8, src: []const u8) u8 {
    const len = @min(src.len, dest.len);
    @memcpy(dest[0..len], src[0..len]);
    return @truncate(len);
}

fn parseU16(s: []const u8) ?u16 {
    if (s.len == 0) return null;
    var val: u16 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        val = val *% 10 +% (c - '0');
    }
    return val;
}

/// Parse a single passwd line into a PasswdEntry.
pub fn parseLine(line: []const u8) ?PasswdEntry {
    var entry: PasswdEntry = .{};
    var field: u8 = 0;
    var start: usize = 0;

    for (line, 0..) |c, i| {
        if (c == ':') {
            const val = line[start..i];
            switch (field) {
                0 => entry.username_len = copyField(&entry.username, val),
                1 => entry.hash_len = copyField(&entry.hash, val),
                2 => entry.uid = parseU16(val) orelse return null,
                3 => entry.gid = parseU16(val) orelse return null,
                4 => entry.gecos_len = copyField(&entry.gecos, val),
                5 => entry.home_len = copyField(&entry.home, val),
                else => {},
            }
            field += 1;
            start = i + 1;
        }
    }

    // Last field (shell)
    if (field == 6) {
        const val = line[start..];
        entry.shell_len = copyField(&entry.shell, val);
    } else {
        return null; // Not enough fields
    }

    if (entry.username_len == 0) return null;
    return entry;
}

/// Format a PasswdEntry back into a passwd line.
pub fn formatLine(buf: []u8, entry: *const PasswdEntry) ?[]const u8 {
    var pos: usize = 0;

    // username
    const uname = entry.usernameSlice();
    if (pos + uname.len + 1 > buf.len) return null;
    @memcpy(buf[pos..][0..uname.len], uname);
    pos += uname.len;
    buf[pos] = ':';
    pos += 1;

    // hash
    const hash = entry.hashSlice();
    if (pos + hash.len + 1 > buf.len) return null;
    @memcpy(buf[pos..][0..hash.len], hash);
    pos += hash.len;
    buf[pos] = ':';
    pos += 1;

    // uid
    var dec_buf: [8]u8 = undefined;
    const uid_str = fmt.formatDec(&dec_buf, entry.uid);
    if (pos + uid_str.len + 1 > buf.len) return null;
    @memcpy(buf[pos..][0..uid_str.len], uid_str);
    pos += uid_str.len;
    buf[pos] = ':';
    pos += 1;

    // gid
    const gid_str = fmt.formatDec(&dec_buf, entry.gid);
    if (pos + gid_str.len + 1 > buf.len) return null;
    @memcpy(buf[pos..][0..gid_str.len], gid_str);
    pos += gid_str.len;
    buf[pos] = ':';
    pos += 1;

    // gecos
    const gecos = entry.gecosSlice();
    if (pos + gecos.len + 1 > buf.len) return null;
    @memcpy(buf[pos..][0..gecos.len], gecos);
    pos += gecos.len;
    buf[pos] = ':';
    pos += 1;

    // home
    const home = entry.homeSlice();
    if (pos + home.len + 1 > buf.len) return null;
    @memcpy(buf[pos..][0..home.len], home);
    pos += home.len;
    buf[pos] = ':';
    pos += 1;

    // shell
    const shell = entry.shellSlice();
    if (pos + shell.len + 1 > buf.len) return null;
    @memcpy(buf[pos..][0..shell.len], shell);
    pos += shell.len;
    buf[pos] = '\n';
    pos += 1;

    return buf[0..pos];
}

var file_buf: [4096]u8 linksection(".bss") = undefined;

/// Look up a passwd entry by username.
pub fn lookupByName(username: []const u8) ?PasswdEntry {
    const fd = syscall.open("/etc/passwd");
    if (fd < 0) return null;
    defer _ = syscall.close(fd);

    const n = syscall.read(fd, &file_buf);
    if (n <= 0) return null;

    const data = file_buf[0..@intCast(n)];
    var start: usize = 0;
    for (data, 0..) |c, i| {
        if (c == '\n') {
            const line = data[start..i];
            if (parseLine(line)) |entry| {
                if (eqlSlice(entry.usernameSlice(), username)) return entry;
            }
            start = i + 1;
        }
    }
    // Handle last line without trailing newline
    if (start < data.len) {
        if (parseLine(data[start..])) |entry| {
            if (eqlSlice(entry.usernameSlice(), username)) return entry;
        }
    }
    return null;
}

/// Look up a passwd entry by uid.
pub fn lookupByUid(uid: u16) ?PasswdEntry {
    const fd = syscall.open("/etc/passwd");
    if (fd < 0) return null;
    defer _ = syscall.close(fd);

    const n = syscall.read(fd, &file_buf);
    if (n <= 0) return null;

    const data = file_buf[0..@intCast(n)];
    var start: usize = 0;
    for (data, 0..) |c, i| {
        if (c == '\n') {
            const line = data[start..i];
            if (parseLine(line)) |entry| {
                if (entry.uid == uid) return entry;
            }
            start = i + 1;
        }
    }
    if (start < data.len) {
        if (parseLine(data[start..])) |entry| {
            if (entry.uid == uid) return entry;
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
