/// Path building utilities for Fornax userspace.

pub const MAX_PATH = 256;

/// Fixed-size path buffer for building paths without allocations.
pub const PathBuf = struct {
    buf: [MAX_PATH]u8 = undefined,
    len: usize = 0,

    /// Create a PathBuf from an initial string.
    pub fn from(s: []const u8) PathBuf {
        var p = PathBuf{};
        const n = @min(s.len, MAX_PATH);
        @memcpy(p.buf[0..n], s[0..n]);
        p.len = n;
        return p;
    }

    /// Append a path component with a '/' separator.
    pub fn append(self: *PathBuf, component: []const u8) *PathBuf {
        // Add separator if needed
        if (self.len > 0 and self.len < MAX_PATH and self.buf[self.len - 1] != '/') {
            self.buf[self.len] = '/';
            self.len += 1;
        }
        const n = @min(component.len, MAX_PATH - self.len);
        @memcpy(self.buf[self.len..][0..n], component[0..n]);
        self.len += n;
        return self;
    }

    /// Append raw string without separator.
    pub fn appendRaw(self: *PathBuf, s: []const u8) *PathBuf {
        const n = @min(s.len, MAX_PATH - self.len);
        @memcpy(self.buf[self.len..][0..n], s[0..n]);
        self.len += n;
        return self;
    }

    /// Get the current path as a slice.
    pub fn slice(self: *const PathBuf) []const u8 {
        return self.buf[0..self.len];
    }

    /// Reset to empty.
    pub fn reset(self: *PathBuf) void {
        self.len = 0;
    }

    /// Normalize the path: resolve `.` and `..` components, collapse slashes.
    pub fn normalize(self: *PathBuf) *PathBuf {
        var result: [MAX_PATH]u8 = undefined;
        var rlen: usize = 0;
        // Track component start positions for handling ..
        var comp_starts: [64]usize = undefined;
        var n_comps: usize = 0;
        const src = self.buf[0..self.len];
        var i: usize = 0;

        // Preserve leading slash
        if (src.len > 0 and src[0] == '/') {
            result[0] = '/';
            rlen = 1;
            i = 1;
        }

        while (i < src.len) {
            // Skip separators
            while (i < src.len and src[i] == '/') : (i += 1) {}
            if (i >= src.len) break;

            const cs = i;
            while (i < src.len and src[i] != '/') : (i += 1) {}
            const comp = src[cs..i];

            if (comp.len == 1 and comp[0] == '.') {
                continue;
            } else if (comp.len == 2 and comp[0] == '.' and comp[1] == '.') {
                if (n_comps > 0) {
                    n_comps -= 1;
                    rlen = comp_starts[n_comps];
                }
            } else {
                if (n_comps < 64) {
                    comp_starts[n_comps] = rlen;
                    n_comps += 1;
                }
                if (rlen > 0 and result[rlen - 1] != '/') {
                    result[rlen] = '/';
                    rlen += 1;
                }
                const n = @min(comp.len, MAX_PATH - rlen);
                @memcpy(result[rlen..][0..n], comp[0..n]);
                rlen += n;
            }
        }

        if (rlen == 0) {
            result[0] = '/';
            rlen = 1;
        }

        @memcpy(self.buf[0..rlen], result[0..rlen]);
        self.len = rlen;
        return self;
    }
};

/// Join two path components.
pub fn join(base: []const u8, component: []const u8) PathBuf {
    var p = PathBuf.from(base);
    _ = p.append(component);
    return p;
}

/// Return the last component of a path.
pub fn basename(p: []const u8) []const u8 {
    if (p.len == 0) return p;
    var i: usize = p.len;
    while (i > 0) {
        i -= 1;
        if (p[i] == '/') return p[i + 1 ..];
    }
    return p;
}

/// Return everything before the last '/' in a path.
pub fn dirname(p: []const u8) []const u8 {
    if (p.len == 0) return ".";
    var i: usize = p.len;
    while (i > 0) {
        i -= 1;
        if (p[i] == '/') {
            if (i == 0) return "/";
            return p[0..i];
        }
    }
    return ".";
}
