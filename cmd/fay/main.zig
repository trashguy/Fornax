/// fay — Fornax package manager.
///
/// Commands:
///   fay install <pkg|path.tar.gz>   Install a package (local or remote)
///   fay remove <pkg>                Remove an installed package
///   fay list                        List installed packages
///   fay info <pkg>                  Show package details
///   fay sync                        Sync remote repository index
///   fay search <term>               Search packages by name/description
///   fay upgrade                     Upgrade all installed packages
const fx = @import("fornax");
const deflate = fx.deflate;
const tar = fx.tar;
const json = fx.json;
const sha256 = fx.sha256;
const http = fx.http;

const out = fx.io.Writer.stdout;
const err = fx.io.Writer.stderr;

// ── BSS Buffers ──────────────────────────────────────────────────────

var sliding_window: [32768]u8 linksection(".bss") = undefined;
var io_buf: [8192]u8 linksection(".bss") = undefined;
var inflate_out_buf: [512]u8 = undefined;
var download_buf: [8192]u8 linksection(".bss") = undefined;
var header_buf: [4096]u8 linksection(".bss") = undefined;
var file_buf: [8192]u8 linksection(".bss") = undefined;
var json_buf: [32768]u8 linksection(".bss") = undefined;
var pkginfo_buf: [4096]u8 linksection(".bss") = undefined;
var files_list_buf: [16384]u8 linksection(".bss") = undefined;
var path_scratch: [512]u8 linksection(".bss") = undefined;
var path_scratch2: [512]u8 linksection(".bss") = undefined;
var abs_path_buf: [512]u8 linksection(".bss") = undefined;
var dir_buf: [4096]u8 linksection(".bss") = undefined;
var hash_buf: [8192]u8 linksection(".bss") = undefined;

// ── Static Data Structures ───────────────────────────────────────────

const MAX_PKGS = 64;
const MAX_DEPS = 8;
const MAX_INSTALLED = 64;
const MAX_QUEUE = 32;

const PkgInfo = struct {
    name: [64]u8,
    name_len: u8,
    ver: [32]u8,
    ver_len: u8,
    desc: [128]u8,
    desc_len: u8,
    url: [256]u8,
    url_len: u16,
    sha256_hex: [64]u8,
    sha256_valid: bool,
    depends: [MAX_DEPS][64]u8,
    dep_lens: [MAX_DEPS]u8,
    dep_count: u8,

    fn nameSlice(self: *const PkgInfo) []const u8 {
        return self.name[0..self.name_len];
    }
    fn verSlice(self: *const PkgInfo) []const u8 {
        return self.ver[0..self.ver_len];
    }
    fn descSlice(self: *const PkgInfo) []const u8 {
        return self.desc[0..self.desc_len];
    }
    fn urlSlice(self: *const PkgInfo) []const u8 {
        return self.url[0..self.url_len];
    }
};

const InstalledPkg = struct {
    name: [64]u8,
    name_len: u8,
    ver: [32]u8,
    ver_len: u8,

    fn nameSlice(self: *const InstalledPkg) []const u8 {
        return self.name[0..self.name_len];
    }
    fn verSlice(self: *const InstalledPkg) []const u8 {
        return self.ver[0..self.ver_len];
    }
};

var repo_pkgs: [MAX_PKGS]PkgInfo linksection(".bss") = undefined;
var repo_pkg_count: usize = 0;

var installed_pkgs: [MAX_INSTALLED]InstalledPkg linksection(".bss") = undefined;
var installed_pkg_count: usize = 0;

// Server config
var server_host: [128]u8 = undefined;
var server_host_len: usize = 0;
var server_port: u16 = 8000;

// ── GzipReader (fd-based, copied from cmd/tar pattern) ───────────────

const FdReaderCtx = struct {
    fd: i32,
};

var fd_reader_ctx: FdReaderCtx = .{ .fd = -1 };

fn fdReadFn(ctx_ptr: *anyopaque, buf: []u8) isize {
    const ctx: *FdReaderCtx = @ptrCast(@alignCast(ctx_ptr));
    return fx.read(ctx.fd, buf);
}

const GzipReader = struct {
    bit_reader: deflate.BitReader,
    inflater: deflate.Inflater,

    fn init(fd: i32) GzipReader {
        fd_reader_ctx.fd = fd;
        return .{
            .bit_reader = deflate.BitReader.init(&fdReadFn, @ptrCast(&fd_reader_ctx), &io_buf),
            .inflater = deflate.Inflater.init(&sliding_window, &inflate_out_buf),
        };
    }

    fn skipGzipHeader(self: *GzipReader) bool {
        return deflate.skipGzipHeader(&self.bit_reader);
    }

    fn readBlock(self: *GzipReader, dest: *[tar.HEADER_SIZE]u8) bool {
        var pos: usize = 0;
        while (pos < tar.HEADER_SIZE) {
            if (self.inflater.done) break;
            const n = self.inflater.readBytes(&self.bit_reader, dest[pos..]);
            if (n == 0) break;
            pos += n;
        }
        if (pos == 0) return false;
        if (pos < tar.HEADER_SIZE) {
            @memset(dest[pos..], 0);
        }
        return true;
    }

    fn readExact(self: *GzipReader, dest: []u8) usize {
        if (self.inflater.done) return 0;
        return self.inflater.readBytes(&self.bit_reader, dest);
    }
};

// ── Helpers ──────────────────────────────────────────────────────────

fn argSlice(arg: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (arg[len] != 0) : (len += 1) {}
    return arg[0..len];
}

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

fn strContains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    if (needle.len == 0) return true;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (strEql(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

fn toLowerByte(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

fn strContainsCI(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    if (needle.len == 0) return true;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (0..needle.len) |j| {
            if (toLowerByte(haystack[i + j]) != toLowerByte(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn copyStr(dest: []u8, src: []const u8) u8 {
    const len = @min(src.len, dest.len);
    @memcpy(dest[0..len], src[0..len]);
    return @intCast(len);
}

fn copyStrWide(dest: []u8, src: []const u8) u16 {
    const len = @min(src.len, dest.len);
    @memcpy(dest[0..len], src[0..len]);
    return @intCast(len);
}

fn ensureParentDirs(name: []const u8) void {
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        if (name[i] == '/' and i > 0) {
            if (i < path_scratch2.len) {
                @memcpy(path_scratch2[0..i], name[0..i]);
                _ = fx.mkdir(path_scratch2[0..i]);
            }
        }
    }
}

fn ensureFayDirs() void {
    _ = fx.mkdir("/var");
    _ = fx.mkdir("/var/lib");
    _ = fx.mkdir("/var/lib/fay");
    _ = fx.mkdir("/var/lib/fay/local");
    _ = fx.mkdir("/var/lib/fay/sync");
    _ = fx.mkdir("/var/cache");
    _ = fx.mkdir("/var/cache/fay");
    _ = fx.mkdir("/var/tmp");
    _ = fx.mkdir("/var/tmp/fay");
}

fn joinPath(buf: []u8, parts: []const []const u8) []const u8 {
    var pos: usize = 0;
    for (parts) |part| {
        if (pos + part.len > buf.len) break;
        @memcpy(buf[pos..][0..part.len], part);
        pos += part.len;
    }
    return buf[0..pos];
}

fn buildDbPath(name: []const u8, ver: []const u8) []const u8 {
    return joinPath(&path_scratch, &.{ "/var/lib/fay/local/", name, "-", ver });
}

fn nameFromEntry(entry_name: []const u8) struct { name: []const u8, ver: []const u8 } {
    // Entry name is "name-ver", find last '-'
    var last_dash: ?usize = null;
    for (0..entry_name.len) |i| {
        if (entry_name[i] == '-') {
            // Check if next char is a digit (version starts with digit)
            if (i + 1 < entry_name.len and entry_name[i + 1] >= '0' and entry_name[i + 1] <= '9') {
                last_dash = i;
            }
        }
    }
    if (last_dash) |d| {
        return .{ .name = entry_name[0..d], .ver = entry_name[d + 1 ..] };
    }
    return .{ .name = entry_name, .ver = "" };
}

fn skipWs(parser: *json.Parser) void {
    while (parser.pos < parser.src.len) {
        switch (parser.src[parser.pos]) {
            ' ', '\t', '\n', '\r' => parser.pos += 1,
            else => return,
        }
    }
}

// ── .PKGINFO Parsing (JSON) ─────────────────────────────────────────

fn parsePkginfo(src: []const u8, info: *PkgInfo) bool {
    var parser = json.Parser.init(src);
    const tok = parser.next();
    if (tok.kind != .object_begin) return false;

    info.name_len = 0;
    info.ver_len = 0;
    info.desc_len = 0;
    info.url_len = 0;
    info.sha256_valid = false;
    info.dep_count = 0;

    while (true) {
        skipWs(&parser);
        if (parser.pos >= parser.src.len) break;
        if (parser.src[parser.pos] == '}') break;

        // Skip comma
        if (parser.src[parser.pos] == ',') {
            parser.pos += 1;
            skipWs(&parser);
        }

        const key = parser.next();
        if (key.kind != .string) break;
        const colon = parser.next();
        if (colon.kind != .colon) break;

        if (strEql(key.str_value, "name")) {
            if (parser.expectString()) |v| {
                info.name_len = copyStr(&info.name, v);
            }
        } else if (strEql(key.str_value, "version")) {
            if (parser.expectString()) |v| {
                info.ver_len = copyStr(&info.ver, v);
            }
        } else if (strEql(key.str_value, "description")) {
            if (parser.expectString()) |v| {
                info.desc_len = copyStr(&info.desc, v);
            }
        } else if (strEql(key.str_value, "url")) {
            if (parser.expectString()) |v| {
                info.url_len = copyStrWide(&info.url, v);
            }
        } else if (strEql(key.str_value, "sha256")) {
            if (parser.expectString()) |v| {
                if (v.len == 64) {
                    @memcpy(&info.sha256_hex, v);
                    info.sha256_valid = true;
                }
            }
        } else if (strEql(key.str_value, "depends")) {
            // Array of strings
            const arr = parser.next();
            if (arr.kind == .array_begin) {
                var first = true;
                while (info.dep_count < MAX_DEPS) {
                    skipWs(&parser);
                    if (parser.pos < parser.src.len and parser.src[parser.pos] == ']') {
                        parser.pos += 1;
                        break;
                    }
                    if (!first) {
                        const comma = parser.next();
                        if (comma.kind != .comma) break;
                    }
                    first = false;
                    if (parser.expectString()) |dep| {
                        const idx = info.dep_count;
                        info.dep_lens[idx] = copyStr(&info.depends[idx], dep);
                        info.dep_count += 1;
                    } else break;
                }
            } else {
                // Not an array, skip
            }
        } else {
            _ = parser.skipValue();
        }
    }

    return info.name_len > 0 and info.ver_len > 0;
}

// ── repo.json Parsing ───────────────────────────────────────────────

fn parseRepoJson(src: []const u8) bool {
    repo_pkg_count = 0;
    var parser = json.Parser.init(src);

    const tok = parser.next();
    if (tok.kind != .object_begin) return false;

    // Find "packages" key
    if (!parser.findKey("packages")) return false;

    const obj = parser.next();
    if (obj.kind != .object_begin) return false;

    // Each key = package name, value = {ver, desc, depends, url, sha256}
    while (repo_pkg_count < MAX_PKGS) {
        skipWs(&parser);
        if (parser.pos >= parser.src.len) break;
        if (parser.src[parser.pos] == '}') {
            parser.pos += 1;
            break;
        }
        if (parser.src[parser.pos] == ',') {
            parser.pos += 1;
            skipWs(&parser);
        }

        const name_tok = parser.next();
        if (name_tok.kind != .string) break;
        const colon = parser.next();
        if (colon.kind != .colon) break;

        var info: *PkgInfo = &repo_pkgs[repo_pkg_count];
        info.name_len = copyStr(&info.name, name_tok.str_value);
        info.ver_len = 0;
        info.desc_len = 0;
        info.url_len = 0;
        info.sha256_valid = false;
        info.dep_count = 0;

        // Parse value object
        const val = parser.next();
        if (val.kind != .object_begin) break;

        while (true) {
            skipWs(&parser);
            if (parser.pos >= parser.src.len) break;
            if (parser.src[parser.pos] == '}') {
                parser.pos += 1;
                break;
            }
            if (parser.src[parser.pos] == ',') {
                parser.pos += 1;
                skipWs(&parser);
            }

            const k = parser.next();
            if (k.kind != .string) break;
            const c = parser.next();
            if (c.kind != .colon) break;

            if (strEql(k.str_value, "version")) {
                if (parser.expectString()) |v| {
                    info.ver_len = copyStr(&info.ver, v);
                }
            } else if (strEql(k.str_value, "description")) {
                if (parser.expectString()) |v| {
                    info.desc_len = copyStr(&info.desc, v);
                }
            } else if (strEql(k.str_value, "url")) {
                if (parser.expectString()) |v| {
                    info.url_len = copyStrWide(&info.url, v);
                }
            } else if (strEql(k.str_value, "sha256")) {
                if (parser.expectString()) |v| {
                    if (v.len == 64) {
                        @memcpy(&info.sha256_hex, v);
                        info.sha256_valid = true;
                    }
                }
            } else if (strEql(k.str_value, "depends")) {
                const arr = parser.next();
                if (arr.kind == .array_begin) {
                    var first = true;
                    while (info.dep_count < MAX_DEPS) {
                        skipWs(&parser);
                        if (parser.pos < parser.src.len and parser.src[parser.pos] == ']') {
                            parser.pos += 1;
                            break;
                        }
                        if (!first) {
                            const cm = parser.next();
                            if (cm.kind != .comma) break;
                        }
                        first = false;
                        if (parser.expectString()) |dep| {
                            const idx = info.dep_count;
                            info.dep_lens[idx] = copyStr(&info.depends[idx], dep);
                            info.dep_count += 1;
                        } else break;
                    }
                } else {
                    // skip non-array
                }
            } else {
                _ = parser.skipValue();
            }
        }

        if (info.ver_len > 0) {
            repo_pkg_count += 1;
        }
    }

    return repo_pkg_count > 0;
}

// ── Installed Package Database ──────────────────────────────────────

fn loadInstalled() void {
    installed_pkg_count = 0;
    const fd = fx.open("/var/lib/fay/local");
    if (fd < 0) return;
    defer _ = fx.close(fd);

    const n = fx.read(fd, &dir_buf);
    if (n <= 0) return;

    const bytes: usize = @intCast(n);
    const entry_size = @sizeOf(fx.DirEntry);
    var off: usize = 0;
    while (off + entry_size <= bytes and installed_pkg_count < MAX_INSTALLED) : (off += entry_size) {
        const entry: *const fx.DirEntry = @ptrCast(@alignCast(dir_buf[off..][0..entry_size]));
        if (entry.file_type != 1) continue; // directories only
        var name_len: usize = 0;
        while (name_len < 64 and entry.name[name_len] != 0) : (name_len += 1) {}
        if (name_len == 0) continue;

        const parsed = nameFromEntry(entry.name[0..name_len]);
        if (parsed.ver.len == 0) continue;

        var pkg = &installed_pkgs[installed_pkg_count];
        pkg.name_len = copyStr(&pkg.name, parsed.name);
        pkg.ver_len = copyStr(&pkg.ver, parsed.ver);
        installed_pkg_count += 1;
    }
}

fn isInstalled(name: []const u8) ?usize {
    for (0..installed_pkg_count) |i| {
        if (strEql(installed_pkgs[i].nameSlice(), name)) return i;
    }
    return null;
}

fn findRepoPackage(name: []const u8) ?usize {
    for (0..repo_pkg_count) |i| {
        if (strEql(repo_pkgs[i].nameSlice(), name)) return i;
    }
    return null;
}

// ── Config Parsing ──────────────────────────────────────────────────

fn parseConfig() void {
    // Default server
    const default_host = "10.0.2.2";
    @memcpy(server_host[0..default_host.len], default_host);
    server_host_len = default_host.len;
    server_port = 8000;

    const fd = fx.open("/etc/fay.conf");
    if (fd < 0) return;
    defer _ = fx.close(fd);

    const n = fx.read(fd, &file_buf);
    if (n <= 0) return;

    const data = file_buf[0..@intCast(n)];
    var pos: usize = 0;
    while (pos < data.len) {
        // Find line
        var line_end = pos;
        while (line_end < data.len and data[line_end] != '\n') : (line_end += 1) {}
        const line = data[pos..line_end];
        pos = line_end + 1;

        // Skip comments and empty lines
        if (line.len == 0 or line[0] == '#') continue;

        // Parse "Server = http://host:port"
        const prefix = "Server";
        if (line.len > prefix.len and strEql(line[0..prefix.len], prefix)) {
            // Find value after '='
            var eq: usize = prefix.len;
            while (eq < line.len and (line[eq] == ' ' or line[eq] == '=')) : (eq += 1) {}
            var val = line[eq..];
            // Strip "http://"
            const http_prefix = "http://";
            if (val.len > http_prefix.len and strEql(val[0..http_prefix.len], http_prefix)) {
                val = val[http_prefix.len..];
            }
            // Parse host:port
            var colon: ?usize = null;
            for (0..val.len) |i| {
                if (val[i] == ':') {
                    colon = i;
                    break;
                }
            }
            if (colon) |c| {
                server_host_len = @min(c, server_host.len);
                @memcpy(server_host[0..server_host_len], val[0..server_host_len]);
                // Parse port
                var p: u16 = 0;
                for (val[c + 1 ..]) |ch| {
                    if (ch >= '0' and ch <= '9') {
                        p = p *% 10 +% @as(u16, ch - '0');
                    } else break;
                }
                if (p > 0) server_port = p;
            } else {
                server_host_len = @min(val.len, server_host.len);
                @memcpy(server_host[0..server_host_len], val[0..server_host_len]);
            }
        }
    }
}

fn getServerHost() []const u8 {
    return server_host[0..server_host_len];
}

// ── Version Comparison ──────────────────────────────────────────────
// Format: [epoch:]pkgver[-pkgrel]
// Compare epoch (numeric, default 0), then pkgver segment-by-segment,
// then pkgrel (numeric).

fn parseEpoch(ver: []const u8) struct { epoch: u32, rest: []const u8 } {
    for (0..ver.len) |i| {
        if (ver[i] == ':') {
            var e: u32 = 0;
            for (ver[0..i]) |c| {
                if (c >= '0' and c <= '9') {
                    e = e * 10 + (c - '0');
                }
            }
            return .{ .epoch = e, .rest = ver[i + 1 ..] };
        }
    }
    return .{ .epoch = 0, .rest = ver };
}

fn splitPkgrel(ver: []const u8) struct { pkgver: []const u8, pkgrel: []const u8 } {
    // Find last '-'
    var last: ?usize = null;
    for (0..ver.len) |i| {
        if (ver[i] == '-') last = i;
    }
    if (last) |l| {
        return .{ .pkgver = ver[0..l], .pkgrel = ver[l + 1 ..] };
    }
    return .{ .pkgver = ver, .pkgrel = "" };
}

fn cmpNumStr(a: []const u8, b: []const u8) i8 {
    // Compare two numeric strings
    // Strip leading zeros
    var ai: usize = 0;
    while (ai < a.len and a[ai] == '0') : (ai += 1) {}
    var bi: usize = 0;
    while (bi < b.len and b[bi] == '0') : (bi += 1) {}
    const al = a.len - ai;
    const bl = b.len - bi;
    if (al != bl) return if (al < bl) -1 else 1;
    for (0..al) |i| {
        if (a[ai + i] != b[bi + i]) {
            return if (a[ai + i] < b[bi + i]) -1 else 1;
        }
    }
    return 0;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn cmpSegment(a: []const u8, b: []const u8) i8 {
    // Compare version segments: numeric segments compared numerically,
    // alpha segments compared lexically. Numeric > alpha.
    if (a.len == 0 and b.len == 0) return 0;
    if (a.len == 0) return -1;
    if (b.len == 0) return 1;

    const a_num = isDigit(a[0]);
    const b_num = isDigit(b[0]);
    if (a_num and !b_num) return 1; // numeric > alpha
    if (!a_num and b_num) return -1;
    if (a_num and b_num) return cmpNumStr(a, b);

    // Both alpha
    const min_len = @min(a.len, b.len);
    for (0..min_len) |i| {
        if (a[i] != b[i]) return if (a[i] < b[i]) -1 else 1;
    }
    if (a.len != b.len) return if (a.len < b.len) -1 else 1;
    return 0;
}

fn cmpPkgver(a: []const u8, b: []const u8) i8 {
    // Compare pkgver segment-by-segment (delimited by '.')
    var ai: usize = 0;
    var bi: usize = 0;
    while (ai < a.len or bi < b.len) {
        // Extract next segment
        var ae = ai;
        while (ae < a.len and a[ae] != '.') : (ae += 1) {}
        var be = bi;
        while (be < b.len and b[be] != '.') : (be += 1) {}

        const sa = if (ai < a.len) a[ai..ae] else "";
        const sb = if (bi < b.len) b[bi..be] else "";

        const c = cmpSegment(sa, sb);
        if (c != 0) return c;

        ai = if (ae < a.len) ae + 1 else a.len;
        bi = if (be < b.len) be + 1 else b.len;
    }
    return 0;
}

fn versionCmp(a: []const u8, b: []const u8) i8 {
    const ea = parseEpoch(a);
    const eb = parseEpoch(b);
    if (ea.epoch != eb.epoch) return if (ea.epoch < eb.epoch) -1 else 1;

    const ra = splitPkgrel(ea.rest);
    const rb = splitPkgrel(eb.rest);

    const vc = cmpPkgver(ra.pkgver, rb.pkgver);
    if (vc != 0) return vc;

    if (ra.pkgrel.len > 0 or rb.pkgrel.len > 0) {
        return cmpNumStr(ra.pkgrel, rb.pkgrel);
    }
    return 0;
}

// ── Dependency Resolution (BFS) ─────────────────────────────────────

var install_queue: [MAX_QUEUE]u8 linksection(".bss") = undefined; // indices into repo_pkgs
var queue_count: usize = 0;
var visited: u64 = 0; // bitmask

fn addToQueue(idx: usize) void {
    if (idx >= 64) return;
    const bit: u64 = @as(u64, 1) << @intCast(idx);
    if (visited & bit != 0) return;
    visited |= bit;
    if (queue_count < MAX_QUEUE) {
        install_queue[queue_count] = @intCast(idx);
        queue_count += 1;
    }
}

fn resolveDeps(pkg_idx: usize) void {
    if (pkg_idx >= repo_pkg_count) return;
    const info = &repo_pkgs[pkg_idx];

    for (0..info.dep_count) |i| {
        const dep_name = info.depends[i][0..info.dep_lens[i]];
        // Skip if already installed
        if (isInstalled(dep_name) != null) continue;
        if (findRepoPackage(dep_name)) |dep_idx| {
            resolveDeps(dep_idx); // resolve deps of dep first
            addToQueue(dep_idx);
        } else {
            err.print("warning: dependency '{s}' not found in repo\n", .{dep_name});
        }
    }
}

// ── Package Installation (from .tar.gz) ─────────────────────────────

fn extractPackage(fd: i32, info: *PkgInfo) bool {
    var gz = GzipReader.init(fd);
    if (!gz.skipGzipHeader()) {
        err.puts("fay: invalid gzip header\n");
        return false;
    }

    var files_pos: usize = 0;
    var zero_blocks: u32 = 0;
    var header: [tar.HEADER_SIZE]u8 = undefined;

    while (true) {
        if (!gz.readBlock(&header)) break;
        if (tar.isZeroBlock(&header)) {
            zero_blocks += 1;
            if (zero_blocks >= 2) break;
            continue;
        }
        zero_blocks = 0;

        const hdr = tar.Header{ .raw = &header };
        if (!hdr.validateChecksum()) continue;

        const raw_name = hdr.name(&path_scratch);
        const size = hdr.size();
        const typeflag = hdr.typeflag();

        // Skip metadata files (check before path prefix)
        if (strEql(raw_name, ".PKGINFO") or strEql(raw_name, ".INSTALL")) {
            if (typeflag == '0' or typeflag == 0) {
                const blocks = (size + tar.HEADER_SIZE - 1) / tar.HEADER_SIZE;
                var bi: u64 = 0;
                while (bi < blocks) : (bi += 1) {
                    _ = gz.readBlock(&header);
                }
            }
            continue;
        }

        if (!tar.isSafePath(raw_name)) continue;

        // Ensure absolute path — Fornax namespace requires leading '/'
        const name = if (raw_name.len > 0 and raw_name[0] != '/') blk: {
            if (raw_name.len + 1 >= abs_path_buf.len) break :blk raw_name;
            abs_path_buf[0] = '/';
            @memcpy(abs_path_buf[1..][0..raw_name.len], raw_name);
            break :blk abs_path_buf[0 .. raw_name.len + 1];
        } else raw_name;

        if (typeflag == '5') {
            // Directory
            ensureParentDirs(name);
            var n_len = name.len;
            while (n_len > 0 and name[n_len - 1] == '/') n_len -= 1;
            if (n_len > 0) {
                _ = fx.mkdir(name[0..n_len]);
            }
        } else if (typeflag == '0' or typeflag == 0) {
            // Regular file
            ensureParentDirs(name);
            const out_fd = fx.create(name, 0);
            if (out_fd < 0) {
                // Skip data blocks
                const blocks = (size + tar.HEADER_SIZE - 1) / tar.HEADER_SIZE;
                var bi: u64 = 0;
                while (bi < blocks) : (bi += 1) {
                    _ = gz.readBlock(&header);
                }
                continue;
            }

            var remaining: u64 = size;
            const blocks = (size + tar.HEADER_SIZE - 1) / tar.HEADER_SIZE;
            var bi: u64 = 0;
            while (bi < blocks) : (bi += 1) {
                var block: [tar.HEADER_SIZE]u8 = undefined;
                if (!gz.readBlock(&block)) break;
                const to_write: usize = @intCast(@min(remaining, tar.HEADER_SIZE));
                _ = fx.syscall.write(out_fd, block[0..to_write]);
                remaining -= to_write;
            }

            const mode_val = hdr.mode();
            _ = fx.wstat(out_fd, @intCast(mode_val & 0o7777), 0, 0, fx.WSTAT_MODE);
            _ = fx.close(out_fd);

            // Record file in files list
            if (files_pos + name.len + 1 <= files_list_buf.len) {
                @memcpy(files_list_buf[files_pos..][0..name.len], name);
                files_list_buf[files_pos + name.len] = '\n';
                files_pos += name.len + 1;
            }
        } else {
            // Skip unknown types
            if (size > 0) {
                const blocks = (size + tar.HEADER_SIZE - 1) / tar.HEADER_SIZE;
                var bi: u64 = 0;
                while (bi < blocks) : (bi += 1) {
                    _ = gz.readBlock(&header);
                }
            }
        }
    }

    // Write database entry
    const db_path = buildDbPath(info.nameSlice(), info.verSlice());
    _ = fx.mkdir(db_path);

    // Write desc
    {
        const desc_path = joinPath(&path_scratch2, &.{ db_path, "/desc" });
        const desc_fd = fx.create(desc_path, 0);
        if (desc_fd >= 0) {
            // Write a simple JSON desc
            _ = fx.syscall.write(desc_fd, "{\"name\":\"");
            _ = fx.syscall.write(desc_fd, info.nameSlice());
            _ = fx.syscall.write(desc_fd, "\",\"version\":\"");
            _ = fx.syscall.write(desc_fd, info.verSlice());
            _ = fx.syscall.write(desc_fd, "\",\"description\":\"");
            _ = fx.syscall.write(desc_fd, info.descSlice());
            _ = fx.syscall.write(desc_fd, "\"}");
            _ = fx.close(desc_fd);
        }
    }

    // Write files list
    {
        const files_path = joinPath(&path_scratch2, &.{ db_path, "/files" });
        const files_fd = fx.create(files_path, 0);
        if (files_fd >= 0) {
            if (files_pos > 0) {
                _ = fx.syscall.write(files_fd, files_list_buf[0..files_pos]);
            }
            _ = fx.close(files_fd);
        }
    }

    return true;
}

fn scanPkginfo(fd: i32, info: *PkgInfo) bool {
    var gz = GzipReader.init(fd);
    if (!gz.skipGzipHeader()) return false;

    var zero_blocks: u32 = 0;
    var header: [tar.HEADER_SIZE]u8 = undefined;

    while (true) {
        if (!gz.readBlock(&header)) break;
        if (tar.isZeroBlock(&header)) {
            zero_blocks += 1;
            if (zero_blocks >= 2) break;
            continue;
        }
        zero_blocks = 0;

        const hdr = tar.Header{ .raw = &header };
        if (!hdr.validateChecksum()) continue;

        const name = hdr.name(&path_scratch);
        const size = hdr.size();
        const typeflag = hdr.typeflag();

        if (strEql(name, ".PKGINFO") and (typeflag == '0' or typeflag == 0)) {
            // Read the content
            if (size > pkginfo_buf.len) return false;
            var read_pos: usize = 0;
            const target_size: usize = @intCast(size);
            const blocks = (size + tar.HEADER_SIZE - 1) / tar.HEADER_SIZE;
            var bi: u64 = 0;
            while (bi < blocks) : (bi += 1) {
                var block: [tar.HEADER_SIZE]u8 = undefined;
                if (!gz.readBlock(&block)) break;
                const to_copy = @min(target_size - read_pos, tar.HEADER_SIZE);
                @memcpy(pkginfo_buf[read_pos..][0..to_copy], block[0..to_copy]);
                read_pos += to_copy;
            }
            return parsePkginfo(pkginfo_buf[0..read_pos], info);
        }

        // Skip data blocks for non-matching entries
        if (typeflag == '0' or typeflag == 0) {
            const blocks = (size + tar.HEADER_SIZE - 1) / tar.HEADER_SIZE;
            var bi: u64 = 0;
            while (bi < blocks) : (bi += 1) {
                _ = gz.readBlock(&header);
            }
        }
    }

    return false;
}

fn hashFile(path: []const u8, digest_out: *[64]u8) bool {
    const fd = fx.open(path);
    if (fd < 0) return false;
    defer _ = fx.close(fd);

    var hasher = sha256.Sha256.init();
    while (true) {
        const n = fx.read(fd, &hash_buf);
        if (n <= 0) break;
        hasher.update(hash_buf[0..@intCast(n)]);
    }
    const digest = hasher.final();
    sha256.hexDigest(&digest, digest_out);
    return true;
}

fn verifySha256(path: []const u8, expected_hex: []const u8) bool {
    var actual: [64]u8 = undefined;
    if (!hashFile(path, &actual)) return false;
    return strEql(&actual, expected_hex);
}

// ── Commands ────────────────────────────────────────────────────────

fn cmdInstall(pkg_arg: []const u8) void {
    ensureFayDirs();

    // Determine if this is a local file (contains '/') or remote package
    var is_local = false;
    for (pkg_arg) |c| {
        if (c == '/') {
            is_local = true;
            break;
        }
    }
    if (pkg_arg.len > 7 and strEql(pkg_arg[pkg_arg.len - 7 ..], ".tar.gz")) {
        is_local = true;
    }

    if (is_local) {
        installLocalPackage(pkg_arg);
    } else {
        installRemotePackage(pkg_arg);
    }
}

fn installLocalPackage(path: []const u8) void {
    // Pass 1: Scan for .PKGINFO
    var info: PkgInfo = undefined;
    {
        const fd = fx.open(path);
        if (fd < 0) {
            err.print("fay: cannot open {s}\n", .{path});
            return;
        }
        const ok = scanPkginfo(fd, &info);
        _ = fx.close(fd);
        if (!ok) {
            err.puts("fay: no valid .PKGINFO found in package\n");
            return;
        }
    }

    out.print("Installing {s} {s}...\n", .{ info.nameSlice(), info.verSlice() });

    // SHA-256 verification if expected digest provided
    if (info.sha256_valid) {
        if (!verifySha256(path, &info.sha256_hex)) {
            err.puts("fay: SHA-256 verification failed!\n");
            return;
        }
        out.puts("  SHA-256 OK\n");
    }

    // Pass 2: Extract files
    {
        const fd = fx.open(path);
        if (fd < 0) {
            err.print("fay: cannot reopen {s}\n", .{path});
            return;
        }
        const ok = extractPackage(fd, &info);
        _ = fx.close(fd);
        if (!ok) {
            err.puts("fay: extraction failed\n");
            return;
        }
    }

    out.print("  {s} {s} installed\n", .{ info.nameSlice(), info.verSlice() });
}

fn installRemotePackage(name: []const u8) void {
    // Load repo
    if (!loadRepoJson()) {
        err.puts("fay: no repo index. Run 'fay sync' first.\n");
        return;
    }

    loadInstalled();

    const idx = findRepoPackage(name) orelse {
        err.print("fay: package '{s}' not found in repository\n", .{name});
        return;
    };

    // Resolve dependencies
    queue_count = 0;
    visited = 0;
    resolveDeps(idx);
    addToQueue(idx);

    if (queue_count == 0) {
        out.puts("Nothing to install.\n");
        return;
    }

    // Print plan
    out.puts("Packages to install:\n");
    for (0..queue_count) |i| {
        const pi = install_queue[i];
        const p = &repo_pkgs[pi];
        out.print("  {s} {s}\n", .{ p.nameSlice(), p.verSlice() });
    }

    // Install each package
    parseConfig();
    for (0..queue_count) |i| {
        const pi = install_queue[i];
        const pkg = &repo_pkgs[pi];

        // Check if already installed
        if (isInstalled(pkg.nameSlice()) != null) {
            out.print("  {s} already installed, skipping\n", .{pkg.nameSlice()});
            continue;
        }

        // Download to /var/cache/fay/
        const cache_path = joinPath(&path_scratch, &.{ "/var/cache/fay/", pkg.nameSlice(), "-", pkg.verSlice(), ".tar.gz" });

        if (pkg.url_len > 0) {
            out.print("Downloading {s}...\n", .{pkg.nameSlice()});
            const cache_fd = fx.create(cache_path, 0);
            if (cache_fd < 0) {
                err.print("fay: cannot create cache file for {s}\n", .{pkg.nameSlice()});
                continue;
            }
            const total = http.download(
                getServerHost(),
                pkg.urlSlice(),
                server_port,
                cache_fd,
                &download_buf,
                &header_buf,
            );
            _ = fx.close(cache_fd);
            if (total == null or total.? == 0) {
                err.print("fay: download failed for {s}\n", .{pkg.nameSlice()});
                continue;
            }
        } else {
            // Build URL from package name
            var url_buf: [256]u8 = undefined;
            const url = joinPath(&url_buf, &.{ "/", pkg.nameSlice(), "-", pkg.verSlice(), ".tar.gz" });
            out.print("Downloading {s}...\n", .{pkg.nameSlice()});
            const cache_fd = fx.create(cache_path, 0);
            if (cache_fd < 0) {
                err.print("fay: cannot create cache file for {s}\n", .{pkg.nameSlice()});
                continue;
            }
            const total = http.download(
                getServerHost(),
                url,
                server_port,
                cache_fd,
                &download_buf,
                &header_buf,
            );
            _ = fx.close(cache_fd);
            if (total == null or total.? == 0) {
                err.print("fay: download failed for {s}\n", .{pkg.nameSlice()});
                continue;
            }
        }

        // Verify SHA-256
        if (pkg.sha256_valid) {
            var actual_hash: [64]u8 = undefined;
            if (hashFile(cache_path, &actual_hash)) {
                if (!strEql(&actual_hash, &pkg.sha256_hex)) {
                    err.print("fay: SHA-256 mismatch for {s}\n", .{pkg.nameSlice()});
                    continue;
                }
            } else {
                err.print("fay: cannot hash {s}\n", .{cache_path});
                continue;
            }
        }

        installLocalPackage(cache_path);
    }
}

fn cmdRemove(name: []const u8) void {
    ensureFayDirs();
    loadInstalled();

    const idx = isInstalled(name) orelse {
        err.print("fay: package '{s}' is not installed\n", .{name});
        return;
    };

    const pkg = &installed_pkgs[idx];
    out.print("Removing {s} {s}...\n", .{ pkg.nameSlice(), pkg.verSlice() });

    // Read files list
    const db_path = buildDbPath(pkg.nameSlice(), pkg.verSlice());
    const files_path = joinPath(&path_scratch2, &.{ db_path, "/files" });

    const fd = fx.open(files_path);
    if (fd >= 0) {
        const n = fx.read(fd, &files_list_buf);
        _ = fx.close(fd);
        if (n > 0) {
            const data = files_list_buf[0..@intCast(n)];
            // Remove each file
            var pos: usize = 0;
            while (pos < data.len) {
                var end = pos;
                while (end < data.len and data[end] != '\n') : (end += 1) {}
                if (end > pos) {
                    const file = data[pos..end];
                    _ = fx.remove(file);
                }
                pos = end + 1;
            }
        }
    }

    // Remove database directory contents and directory
    {
        const desc_path = joinPath(&path_scratch2, &.{ db_path, "/desc" });
        _ = fx.remove(desc_path);
    }
    {
        const fp = joinPath(&path_scratch2, &.{ db_path, "/files" });
        _ = fx.remove(fp);
    }
    _ = fx.remove(db_path);

    out.print("  {s} removed\n", .{name});
}

fn cmdList() void {
    ensureFayDirs();
    loadInstalled();

    if (installed_pkg_count == 0) {
        out.puts("No packages installed.\n");
        return;
    }

    for (0..installed_pkg_count) |i| {
        const pkg = &installed_pkgs[i];
        out.print("{s} {s}\n", .{ pkg.nameSlice(), pkg.verSlice() });
    }
}

fn cmdInfo(name: []const u8) void {
    ensureFayDirs();
    loadInstalled();

    // First try local database
    if (isInstalled(name)) |idx| {
        const pkg = &installed_pkgs[idx];
        const db_path = buildDbPath(pkg.nameSlice(), pkg.verSlice());
        const desc_path = joinPath(&path_scratch2, &.{ db_path, "/desc" });

        const fd = fx.open(desc_path);
        if (fd >= 0) {
            const n = fx.read(fd, &pkginfo_buf);
            _ = fx.close(fd);
            if (n > 0) {
                var info: PkgInfo = undefined;
                if (parsePkginfo(pkginfo_buf[0..@intCast(n)], &info)) {
                    printPkgInfo(&info, true);
                    return;
                }
            }
        }
        // Fallback: print basic info
        out.print("Name    : {s}\n", .{pkg.nameSlice()});
        out.print("Version : {s}\n", .{pkg.verSlice()});
        out.puts("Status  : installed\n");
        return;
    }

    // Try repo
    if (loadRepoJson()) {
        if (findRepoPackage(name)) |idx| {
            printPkgInfo(&repo_pkgs[idx], false);
            return;
        }
    }

    err.print("fay: package '{s}' not found\n", .{name});
}

fn printPkgInfo(info: *const PkgInfo, installed: bool) void {
    out.print("Name        : {s}\n", .{info.nameSlice()});
    out.print("Version     : {s}\n", .{info.verSlice()});
    if (info.desc_len > 0) {
        out.print("Description : {s}\n", .{info.descSlice()});
    }
    if (info.dep_count > 0) {
        out.puts("Depends     : ");
        for (0..info.dep_count) |i| {
            if (i > 0) out.puts(", ");
            out.puts(info.depends[i][0..info.dep_lens[i]]);
        }
        out.putc('\n');
    }
    if (installed) {
        out.puts("Status      : installed\n");
    }
}

fn cmdSync() void {
    ensureFayDirs();
    parseConfig();

    out.puts("Syncing package database...\n");

    const fd = fx.create("/var/lib/fay/sync/repo.json", 0);
    if (fd < 0) {
        err.puts("fay: cannot create repo.json\n");
        return;
    }

    const total = http.download(
        getServerHost(),
        "/repo.json",
        server_port,
        fd,
        &download_buf,
        &header_buf,
    );
    _ = fx.close(fd);

    if (total == null or total.? == 0) {
        err.puts("fay: sync failed\n");
        return;
    }

    out.print("  downloaded {d} bytes\n", .{total.?});
}

fn loadRepoJson() bool {
    const fd = fx.open("/var/lib/fay/sync/repo.json");
    if (fd < 0) return false;
    const n = fx.read(fd, &json_buf);
    _ = fx.close(fd);
    if (n <= 0) return false;
    return parseRepoJson(json_buf[0..@intCast(n)]);
}

fn cmdSearch(term: []const u8) void {
    if (!loadRepoJson()) {
        err.puts("fay: no repo index. Run 'fay sync' first.\n");
        return;
    }

    var found: usize = 0;
    for (0..repo_pkg_count) |i| {
        const pkg = &repo_pkgs[i];
        if (strContainsCI(pkg.nameSlice(), term) or strContainsCI(pkg.descSlice(), term)) {
            out.print("{s} {s}", .{ pkg.nameSlice(), pkg.verSlice() });
            if (pkg.desc_len > 0) {
                out.print(" - {s}", .{pkg.descSlice()});
            }
            out.putc('\n');
            found += 1;
        }
    }

    if (found == 0) {
        out.print("No packages matching '{s}'\n", .{term});
    }
}

fn cmdUpgrade() void {
    ensureFayDirs();
    parseConfig();

    out.puts("Syncing...\n");
    // Sync first
    {
        const fd = fx.create("/var/lib/fay/sync/repo.json", 0);
        if (fd >= 0) {
            _ = http.download(
                getServerHost(),
                "/repo.json",
                server_port,
                fd,
                &download_buf,
                &header_buf,
            );
            _ = fx.close(fd);
        }
    }

    if (!loadRepoJson()) {
        err.puts("fay: cannot load repo index\n");
        return;
    }

    loadInstalled();

    // Find upgradable packages
    queue_count = 0;
    visited = 0;
    var upgradable: usize = 0;

    for (0..installed_pkg_count) |i| {
        const inst = &installed_pkgs[i];
        if (findRepoPackage(inst.nameSlice())) |ri| {
            const repo = &repo_pkgs[ri];
            if (versionCmp(repo.verSlice(), inst.verSlice()) > 0) {
                resolveDeps(ri);
                addToQueue(ri);
                upgradable += 1;
            }
        }
    }

    if (upgradable == 0) {
        out.puts("All packages are up to date.\n");
        return;
    }

    out.print("{d} package(s) to upgrade:\n", .{upgradable});
    for (0..queue_count) |i| {
        const pi = install_queue[i];
        const pkg = &repo_pkgs[pi];
        out.print("  {s} -> {s}\n", .{ pkg.nameSlice(), pkg.verSlice() });
    }

    // Install upgrades
    for (0..queue_count) |i| {
        const pi = install_queue[i];
        const pkg = &repo_pkgs[pi];

        // Remove old version first
        if (isInstalled(pkg.nameSlice())) |_| {
            cmdRemove(pkg.nameSlice());
        }

        // Download and install
        const cache_path = joinPath(&path_scratch, &.{ "/var/cache/fay/", pkg.nameSlice(), "-", pkg.verSlice(), ".tar.gz" });

        var url_buf: [256]u8 = undefined;
        const url = if (pkg.url_len > 0)
            pkg.urlSlice()
        else
            joinPath(&url_buf, &.{ "/", pkg.nameSlice(), "-", pkg.verSlice(), ".tar.gz" });

        out.print("Downloading {s}...\n", .{pkg.nameSlice()});
        const cache_fd = fx.create(cache_path, 0);
        if (cache_fd < 0) continue;
        const total = http.download(
            getServerHost(),
            url,
            server_port,
            cache_fd,
            &download_buf,
            &header_buf,
        );
        _ = fx.close(cache_fd);
        if (total == null or total.? == 0) {
            err.print("fay: download failed for {s}\n", .{pkg.nameSlice()});
            continue;
        }

        if (pkg.sha256_valid) {
            if (!verifySha256(cache_path, &pkg.sha256_hex)) {
                err.print("fay: SHA-256 mismatch for {s}!\n", .{pkg.nameSlice()});
                continue;
            }
        }

        installLocalPackage(cache_path);
    }
}

// ── Entry Point ─────────────────────────────────────────────────────

export fn _start() noreturn {
    const args = fx.getArgs();

    if (args.len < 2) {
        printUsage();
        fx.exit(1);
    }

    const cmd = argSlice(args[1]);

    if (strEql(cmd, "install") or strEql(cmd, "add")) {
        if (args.len < 3) {
            err.puts("Usage: fay install <package|file.tar.gz>\n");
            fx.exit(1);
        }
        cmdInstall(argSlice(args[2]));
    } else if (strEql(cmd, "remove") or strEql(cmd, "rm")) {
        if (args.len < 3) {
            err.puts("Usage: fay remove <package>\n");
            fx.exit(1);
        }
        cmdRemove(argSlice(args[2]));
    } else if (strEql(cmd, "list") or strEql(cmd, "ls")) {
        cmdList();
    } else if (strEql(cmd, "info")) {
        if (args.len < 3) {
            err.puts("Usage: fay info <package>\n");
            fx.exit(1);
        }
        cmdInfo(argSlice(args[2]));
    } else if (strEql(cmd, "sync")) {
        cmdSync();
    } else if (strEql(cmd, "search")) {
        if (args.len < 3) {
            err.puts("Usage: fay search <term>\n");
            fx.exit(1);
        }
        cmdSearch(argSlice(args[2]));
    } else if (strEql(cmd, "upgrade") or strEql(cmd, "up")) {
        cmdUpgrade();
    } else if (strEql(cmd, "help") or strEql(cmd, "--help") or strEql(cmd, "-h")) {
        printUsage();
    } else {
        err.print("fay: unknown command '{s}'\n", .{cmd});
        printUsage();
        fx.exit(1);
    }

    fx.exit(0);
}

fn printUsage() void {
    out.puts("fay - Fornax package manager\n\n");
    out.puts("Usage: fay <command> [args]\n\n");
    out.puts("Commands:\n");
    out.puts("  install <pkg|file.tar.gz>  Install a package\n");
    out.puts("  remove <pkg>               Remove a package\n");
    out.puts("  list                       List installed packages\n");
    out.puts("  info <pkg>                 Show package details\n");
    out.puts("  sync                       Sync remote repository\n");
    out.puts("  search <term>              Search packages\n");
    out.puts("  upgrade                    Upgrade all packages\n");
    out.puts("  help                       Show this help\n");
}
