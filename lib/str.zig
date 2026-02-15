/// String utilities for Fornax userspace.

/// Check if two slices are equal.
pub fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (ac != bc) return false;
    }
    return true;
}

/// Check if a starts with prefix.
pub fn startsWith(a: []const u8, prefix: []const u8) bool {
    if (a.len < prefix.len) return false;
    return eql(a[0..prefix.len], prefix);
}

/// Check if a ends with suffix.
pub fn endsWith(a: []const u8, suffix: []const u8) bool {
    if (a.len < suffix.len) return false;
    return eql(a[a.len - suffix.len ..], suffix);
}

/// Find the first occurrence of needle in haystack.
pub fn indexOf(haystack: []const u8, needle: u8) ?usize {
    for (haystack, 0..) |c, i| {
        if (c == needle) return i;
    }
    return null;
}

/// Find the first occurrence of a substring in a string.
pub fn indexOfSlice(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (haystack.len < needle.len) return null;
    for (0..haystack.len - needle.len + 1) |i| {
        if (eql(haystack[i..][0..needle.len], needle)) return i;
    }
    return null;
}

/// Copy src into dest, returning the number of bytes copied.
pub fn copy(dest: []u8, src: []const u8) usize {
    const len = @min(dest.len, src.len);
    @memcpy(dest[0..len], src[0..len]);
    return len;
}

/// Tokenize a line on whitespace. Returns number of tokens stored.
pub fn tokenize(line: []const u8, tokens: [][]const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < line.len and count < tokens.len) {
        // Skip whitespace
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
        if (i >= line.len) break;
        const start = i;
        // Find end of token
        while (i < line.len and line[i] != ' ' and line[i] != '\t') : (i += 1) {}
        tokens[count] = line[start..i];
        count += 1;
    }
    return count;
}

/// Parse an unsigned decimal integer from a string.
pub fn parseUint(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    var result: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        const old = result;
        result = result *% 10 +% (c - '0');
        if (result < old) return null; // overflow
    }
    return result;
}

/// Trim leading and trailing whitespace.
pub fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t' or s[start] == '\n' or s[start] == '\r')) : (start += 1) {}
    if (start == s.len) return s[0..0];
    var end: usize = s.len;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\n' or s[end - 1] == '\r')) : (end -= 1) {}
    return s[start..end];
}

/// Trim trailing whitespace.
pub fn trimRight(s: []const u8) []const u8 {
    var end: usize = s.len;
    while (end > 0 and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\n' or s[end - 1] == '\r')) : (end -= 1) {}
    return s[0..end];
}
