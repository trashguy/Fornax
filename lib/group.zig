/// Fornax /etc/group parser.
///
/// Format: groupname:password:gid:members
/// One entry per line. Fields separated by ':'.

const syscall = @import("syscall.zig");

pub const GroupEntry = struct {
    groupname: [32]u8 = .{0} ** 32,
    groupname_len: u8 = 0,
    members: [128]u8 = .{0} ** 128,
    members_len: u8 = 0,
    gid: u16 = 0,

    pub fn groupnameSlice(self: *const GroupEntry) []const u8 {
        return self.groupname[0..self.groupname_len];
    }

    pub fn membersSlice(self: *const GroupEntry) []const u8 {
        return self.members[0..self.members_len];
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

/// Parse a single group line into a GroupEntry.
pub fn parseLine(line: []const u8) ?GroupEntry {
    var entry: GroupEntry = .{};
    var field: u8 = 0;
    var start: usize = 0;

    for (line, 0..) |c, i| {
        if (c == ':') {
            const val = line[start..i];
            switch (field) {
                0 => entry.groupname_len = copyField(&entry.groupname, val),
                1 => {}, // password field (ignored)
                2 => entry.gid = parseU16(val) orelse return null,
                else => {},
            }
            field += 1;
            start = i + 1;
        }
    }

    // Last field (members)
    if (field == 3) {
        const val = line[start..];
        entry.members_len = copyField(&entry.members, val);
    } else {
        return null;
    }

    if (entry.groupname_len == 0) return null;
    return entry;
}

var file_buf: [4096]u8 linksection(".bss") = undefined;

/// Look up a group entry by name.
pub fn lookupByName(name: []const u8) ?GroupEntry {
    const fd = syscall.open("/etc/group");
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
                if (eqlSlice(entry.groupnameSlice(), name)) return entry;
            }
            start = i + 1;
        }
    }
    if (start < data.len) {
        if (parseLine(data[start..])) |entry| {
            if (eqlSlice(entry.groupnameSlice(), name)) return entry;
        }
    }
    return null;
}

/// Look up a group entry by gid.
pub fn lookupByGid(gid: u16) ?GroupEntry {
    const fd = syscall.open("/etc/group");
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
                if (entry.gid == gid) return entry;
            }
            start = i + 1;
        }
    }
    if (start < data.len) {
        if (parseLine(data[start..])) |entry| {
            if (entry.gid == gid) return entry;
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
