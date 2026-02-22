const fx = @import("fornax");

const out = fx.io.Writer.stdout;
const err = fx.io.Writer.stderr;

// ── BSS Buffers ──────────────────────────────────────────────────────
var sliding_window: [32768]u8 linksection(".bss") = undefined;
var io_buf: [8192]u8 linksection(".bss") = undefined;
var file_buf: [8192]u8 linksection(".bss") = undefined;
var dir_buf: [4096]u8 linksection(".bss") = undefined;
var path_scratch: [512]u8 linksection(".bss") = undefined;
var crc_table_storage: fx.crc32.Crc32 linksection(".bss") = undefined;
var inflate_out_buf: [tar.HEADER_SIZE]u8 = undefined;

const tar = fx.tar;
const deflate = fx.deflate;

// ── BitReader adapter: sequential fd read ────────────────────────────
const FdReaderCtx = struct {
    fd: i32,
};

var fd_reader_ctx: FdReaderCtx = .{ .fd = -1 };

fn fdReadFn(ctx_ptr: *anyopaque, buf: []u8) isize {
    const ctx: *FdReaderCtx = @ptrCast(@alignCast(ctx_ptr));
    return fx.read(ctx.fd, buf);
}

// ── Archive I/O buffering ────────────────────────────────────────────
var archive_fd: i32 = -1;
var io_pos: usize = 0;
var archive_crc: u32 = 0;
var archive_size: u32 = 0;
var gz_mode = false;

fn archiveWrite(data: []const u8) void {
    if (gz_mode) {
        gzipWriteStored(data);
    } else {
        archiveWriteRaw(data);
    }
}

fn archiveWriteRaw(data: []const u8) void {
    var offset: usize = 0;
    while (offset < data.len) {
        const space = io_buf.len - io_pos;
        const chunk = @min(data.len - offset, space);
        @memcpy(io_buf[io_pos..][0..chunk], data[offset..][0..chunk]);
        io_pos += chunk;
        offset += chunk;
        if (io_pos >= io_buf.len) {
            _ = fx.syscall.write(archive_fd, &io_buf);
            io_pos = 0;
        }
    }
}

fn archiveFlush() void {
    if (io_pos > 0) {
        _ = fx.syscall.write(archive_fd, io_buf[0..io_pos]);
        io_pos = 0;
    }
}

// ── Gzip support ─────────────────────────────────────────────────────
fn gzipWriteHeader() void {
    const hdr = [10]u8{ 0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xFF };
    archiveWriteRaw(&hdr);
    archive_crc = 0;
    archive_size = 0;
}

fn gzipWriteStored(data: []const u8) void {
    archive_crc = crc_table_storage.update(archive_crc, data);
    archive_size +%= @intCast(data.len);

    var offset: usize = 0;
    while (offset < data.len) {
        const remaining = data.len - offset;
        const chunk_len: u16 = @intCast(@min(remaining, 65535));
        const nlen = ~chunk_len;
        const block_hdr = [5]u8{
            0, // bfinal=0
            @intCast(chunk_len & 0xFF),
            @intCast(chunk_len >> 8),
            @intCast(nlen & 0xFF),
            @intCast(nlen >> 8),
        };
        archiveWriteRaw(&block_hdr);
        archiveWriteRaw(data[offset..][0..chunk_len]);
        offset += chunk_len;
    }
}

fn gzipWriteTrailer() void {
    const final_block = [5]u8{ 1, 0, 0, 0xFF, 0xFF };
    archiveWriteRaw(&final_block);

    var trailer: [8]u8 = undefined;
    trailer[0] = @intCast(archive_crc & 0xFF);
    trailer[1] = @intCast((archive_crc >> 8) & 0xFF);
    trailer[2] = @intCast((archive_crc >> 16) & 0xFF);
    trailer[3] = @intCast((archive_crc >> 24) & 0xFF);
    trailer[4] = @intCast(archive_size & 0xFF);
    trailer[5] = @intCast((archive_size >> 8) & 0xFF);
    trailer[6] = @intCast((archive_size >> 16) & 0xFF);
    trailer[7] = @intCast((archive_size >> 24) & 0xFF);
    archiveWriteRaw(&trailer);
}

// ── GzipReader: decompresses gzip stream via library Inflater ────────
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
};

// ── Path helpers ─────────────────────────────────────────────────────
fn ensureParentDirs(name: []const u8) void {
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        if (name[i] == '/' and i > 0) {
            if (i < path_scratch.len) {
                @memcpy(path_scratch[0..i], name[0..i]);
                _ = fx.mkdir(path_scratch[0..i]);
            }
        }
    }
}

fn joinPath(buf: []u8, dir: []const u8, name: []const u8) ?[]const u8 {
    const needs_slash = dir.len > 0 and dir[dir.len - 1] != '/';
    const total = dir.len + (if (needs_slash) @as(usize, 1) else 0) + name.len;
    if (total > buf.len) return null;
    @memcpy(buf[0..dir.len], dir);
    var pos = dir.len;
    if (needs_slash) {
        buf[pos] = '/';
        pos += 1;
    }
    @memcpy(buf[pos..][0..name.len], name);
    return buf[0..total];
}

fn stripLeadingSlash(path: []const u8) []const u8 {
    var s = path;
    while (s.len > 0 and s[0] == '/') s = s[1..];
    return s;
}

// ── Create mode ──────────────────────────────────────────────────────
fn addEntry(path: []const u8, verbose: bool) void {
    const clean = stripLeadingSlash(path);
    if (clean.len == 0) return;

    const fd = fx.open(path);
    if (fd < 0) {
        err.print("tar: cannot open {s}\n", .{path});
        return;
    }

    var st: fx.Stat = undefined;
    _ = fx.stat(fd, &st);

    if (st.file_type == 1) {
        var header: [tar.HEADER_SIZE]u8 = undefined;
        var dir_name: [256]u8 = undefined;
        const dlen = @min(clean.len, 254);
        @memcpy(dir_name[0..dlen], clean[0..dlen]);
        var final_len = dlen;
        if (dlen > 0 and clean[dlen - 1] != '/') {
            dir_name[dlen] = '/';
            final_len = dlen + 1;
        }
        tar.fillHeader(&header, dir_name[0..final_len], 0, st.mode & 0o7777, st.uid, st.gid, '5');
        archiveWrite(&header);
        if (verbose) {
            out.puts(dir_name[0..final_len]);
            out.putc('\n');
        }

        const n = fx.read(fd, &dir_buf);
        _ = fx.close(fd);
        if (n <= 0) return;

        const entry_size: usize = 72;
        var off: usize = 0;
        const bytes: usize = @intCast(n);

        while (off + entry_size <= bytes) : (off += entry_size) {
            const name_bytes = dir_buf[off..][0..64];
            var name_len: usize = 0;
            while (name_len < 64 and name_bytes[name_len] != 0) : (name_len += 1) {}
            if (name_len == 0) continue;
            const name = name_bytes[0..name_len];
            if (fx.str.eql(name, ".") or fx.str.eql(name, "..")) continue;

            var child_path: [512]u8 = undefined;
            const cp = joinPath(&child_path, path, name) orelse continue;
            var cp_copy: [512]u8 = undefined;
            @memcpy(cp_copy[0..cp.len], cp);
            addEntry(cp_copy[0..cp.len], verbose);
        }
    } else {
        var header: [tar.HEADER_SIZE]u8 = undefined;
        tar.fillHeader(&header, clean, st.size, st.mode & 0o7777, st.uid, st.gid, '0');
        archiveWrite(&header);
        if (verbose) {
            out.puts(clean);
            out.putc('\n');
        }

        var remaining: u64 = st.size;
        while (remaining > 0) {
            const to_read: usize = @intCast(@min(remaining, file_buf.len));
            const nr = fx.read(fd, file_buf[0..to_read]);
            if (nr <= 0) break;
            const nbytes: usize = @intCast(nr);
            archiveWrite(file_buf[0..nbytes]);
            remaining -= nbytes;
        }

        const tail: usize = @intCast(st.size % tar.HEADER_SIZE);
        if (tail > 0) {
            var padding: [tar.HEADER_SIZE]u8 = undefined;
            @memset(&padding, 0);
            archiveWrite(padding[0 .. tar.HEADER_SIZE - tail]);
        }

        _ = fx.close(fd);
    }
}

// ── Extract mode ─────────────────────────────────────────────────────
fn extractArchive(in_fd: i32, verbose: bool, list_only: bool, is_gz: bool) void {
    var zero_blocks: u32 = 0;

    if (is_gz) {
        var gz = GzipReader.init(in_fd);
        if (!gz.skipGzipHeader()) {
            err.puts("tar: invalid gzip header\n");
            return;
        }
        var header: [tar.HEADER_SIZE]u8 = undefined;
        while (true) {
            if (!gz.readBlock(&header)) break;
            if (tar.isZeroBlock(&header)) {
                zero_blocks += 1;
                if (zero_blocks >= 2) break;
                continue;
            }
            zero_blocks = 0;
            processEntry(&header, null, &gz, verbose, list_only);
        }
    } else {
        var header: [tar.HEADER_SIZE]u8 = undefined;
        while (true) {
            const n = fx.read(in_fd, &header);
            if (n < tar.HEADER_SIZE) break;
            if (tar.isZeroBlock(&header)) {
                zero_blocks += 1;
                if (zero_blocks >= 2) break;
                continue;
            }
            zero_blocks = 0;
            processEntry(&header, in_fd, null, verbose, list_only);
        }
    }
}

fn processEntry(header: *[tar.HEADER_SIZE]u8, raw_fd: ?i32, gz: ?*GzipReader, verbose: bool, list_only: bool) void {
    const hdr = tar.Header{ .raw = header };

    if (!hdr.validateChecksum()) {
        err.puts("tar: checksum error, skipping entry\n");
        return;
    }

    const name = hdr.name(&path_scratch);
    const size = hdr.size();
    const mode_val = hdr.mode();
    const uid_val = hdr.uid();
    const gid_val = hdr.gid();
    const typeflag = hdr.typeflag();

    if (list_only) {
        if (verbose) {
            printMode(if (typeflag == '5') mode_val | 0o40000 else mode_val);
            out.putc(' ');
            printNum(uid_val);
            out.putc('/');
            printNum(gid_val);
            out.putc(' ');
            printNumPad(size, 8);
            out.putc(' ');
        }
        out.puts(name);
        out.putc('\n');

        if (typeflag == '0' or typeflag == 0) {
            skipDataBlocks(raw_fd, gz, size);
        }
        return;
    }

    if (typeflag == '5') {
        if (!tar.isSafePath(name)) {
            err.print("tar: skipping unsafe path: {s}\n", .{name});
            return;
        }
        ensureParentDirs(name);
        var n_len = name.len;
        while (n_len > 0 and name[n_len - 1] == '/') n_len -= 1;
        if (n_len > 0) {
            _ = fx.mkdir(name[0..n_len]);
        }
        if (verbose) {
            out.puts(name);
            out.putc('\n');
        }
    } else if (typeflag == '0' or typeflag == 0) {
        if (!tar.isSafePath(name)) {
            err.print("tar: skipping unsafe path: {s}\n", .{name});
            skipDataBlocks(raw_fd, gz, size);
            return;
        }
        ensureParentDirs(name);
        const out_fd = fx.create(name, 0);
        if (out_fd < 0) {
            err.print("tar: cannot create {s}\n", .{name});
            skipDataBlocks(raw_fd, gz, size);
            return;
        }

        var remaining: u64 = size;
        const blocks = (size + tar.HEADER_SIZE - 1) / tar.HEADER_SIZE;
        var block_i: u64 = 0;
        while (block_i < blocks) : (block_i += 1) {
            var block: [tar.HEADER_SIZE]u8 = undefined;
            const got = readArchiveBlock(raw_fd, gz, &block);
            if (!got) break;
            const to_write: usize = @intCast(@min(remaining, tar.HEADER_SIZE));
            _ = fx.syscall.write(out_fd, block[0..to_write]);
            remaining -= to_write;
        }

        _ = fx.wstat(out_fd, @intCast(mode_val & 0o7777), @intCast(uid_val), @intCast(gid_val), fx.WSTAT_MODE | fx.WSTAT_UID | fx.WSTAT_GID);

        _ = fx.close(out_fd);
        if (verbose) {
            out.puts(name);
            out.putc('\n');
        }
    } else {
        if (size > 0) {
            skipDataBlocks(raw_fd, gz, size);
        }
    }
}

fn readArchiveBlock(raw_fd: ?i32, gz: ?*GzipReader, dest: *[tar.HEADER_SIZE]u8) bool {
    if (gz) |g| {
        return g.readBlock(dest);
    } else if (raw_fd) |fd| {
        const n = fx.read(fd, dest);
        return n >= tar.HEADER_SIZE;
    }
    return false;
}

fn skipDataBlocks(raw_fd: ?i32, gz: ?*GzipReader, size: u64) void {
    const blocks = (size + tar.HEADER_SIZE - 1) / tar.HEADER_SIZE;
    var block: [tar.HEADER_SIZE]u8 = undefined;
    var i: u64 = 0;
    while (i < blocks) : (i += 1) {
        _ = readArchiveBlock(raw_fd, gz, &block);
    }
}

// ── Output helpers ───────────────────────────────────────────────────
fn printNum(val: u64) void {
    var buf: [20]u8 = undefined;
    var len: usize = 0;
    var v = val;
    if (v == 0) {
        out.putc('0');
        return;
    }
    while (v > 0) : (v /= 10) {
        buf[len] = @intCast('0' + (v % 10));
        len += 1;
    }
    var j: usize = 0;
    while (j < len) : (j += 1) out.putc(buf[len - 1 - j]);
}

fn printNumPad(val: u64, width: usize) void {
    var buf: [20]u8 = undefined;
    var len: usize = 0;
    var v = val;
    if (v == 0) {
        buf[0] = '0';
        len = 1;
    } else {
        while (v > 0) : (v /= 10) {
            buf[len] = @intCast('0' + (v % 10));
            len += 1;
        }
    }
    var pad: usize = 0;
    while (pad + len < width) : (pad += 1) out.putc(' ');
    var j: usize = 0;
    while (j < len) : (j += 1) out.putc(buf[len - 1 - j]);
}

fn printMode(mode: u64) void {
    const m: u32 = @intCast(mode);
    if (m & 0o40000 != 0) {
        out.putc('d');
    } else {
        out.putc('-');
    }
    out.putc(if (m & 0o400 != 0) 'r' else '-');
    out.putc(if (m & 0o200 != 0) 'w' else '-');
    out.putc(if (m & 0o100 != 0) 'x' else '-');
    out.putc(if (m & 0o040 != 0) 'r' else '-');
    out.putc(if (m & 0o020 != 0) 'w' else '-');
    out.putc(if (m & 0o010 != 0) 'x' else '-');
    out.putc(if (m & 0o004 != 0) 'r' else '-');
    out.putc(if (m & 0o002 != 0) 'w' else '-');
    out.putc(if (m & 0o001 != 0) 'x' else '-');
}

// ── Argument parsing ─────────────────────────────────────────────────
fn argSlice(arg: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (arg[len] != 0) : (len += 1) {}
    return arg[0..len];
}

// ── Main ─────────────────────────────────────────────────────────────
export fn _start() noreturn {
    const args = fx.getArgs();

    if (args.len < 2) {
        err.puts("Usage: tar [cxtv][z]f archive [files...]\n");
        fx.exit(1);
    }

    const flags_str = argSlice(args[1]);
    var mode_create = false;
    var mode_extract = false;
    var mode_list = false;
    var verbose = false;
    var gzip = false;
    var f_flag = false;

    for (flags_str) |c| {
        switch (c) {
            '-' => {},
            'c' => mode_create = true,
            'x' => mode_extract = true,
            't' => mode_list = true,
            'v' => verbose = true,
            'z' => gzip = true,
            'f' => f_flag = true,
            else => {
                err.print("tar: unknown flag '{c}'\n", .{c});
                fx.exit(1);
            },
        }
    }

    const mode_count = @as(u32, if (mode_create) 1 else 0) +
        @as(u32, if (mode_extract) 1 else 0) +
        @as(u32, if (mode_list) 1 else 0);
    if (mode_count != 1) {
        err.puts("tar: must specify exactly one of c, x, or t\n");
        fx.exit(1);
    }

    if (!f_flag) {
        err.puts("tar: f flag required\n");
        fx.exit(1);
    }

    if (args.len < 3) {
        err.puts("tar: missing archive filename\n");
        fx.exit(1);
    }

    const archive_path = argSlice(args[2]);

    if (mode_create) {
        if (args.len < 4) {
            err.puts("tar: no files specified\n");
            fx.exit(1);
        }

        crc_table_storage.init();

        archive_fd = fx.create(archive_path, 0);
        if (archive_fd < 0) {
            err.print("tar: cannot create {s}\n", .{archive_path});
            fx.exit(1);
        }

        gz_mode = gzip;
        io_pos = 0;

        if (gzip) {
            gzipWriteHeader();
        }

        for (args[3..]) |arg| {
            const path = argSlice(arg);
            addEntry(path, verbose);
        }

        var zero_block: [tar.HEADER_SIZE]u8 = undefined;
        @memset(&zero_block, 0);
        archiveWrite(&zero_block);
        archiveWrite(&zero_block);

        if (gzip) {
            gzipWriteTrailer();
        }

        archiveFlush();
        _ = fx.close(archive_fd);
    } else {
        const in_fd = fx.open(archive_path);
        if (in_fd < 0) {
            err.print("tar: cannot open {s}\n", .{archive_path});
            fx.exit(1);
        }

        var is_gz = gzip;
        if (!is_gz) {
            var magic: [2]u8 = undefined;
            const pn = fx.pread(in_fd, &magic, 0);
            if (pn >= 2 and magic[0] == 0x1f and magic[1] == 0x8b) {
                is_gz = true;
            }
        }

        if (is_gz and !gzip) {
            _ = fx.close(in_fd);
            const in_fd2 = fx.open(archive_path);
            if (in_fd2 < 0) {
                err.print("tar: cannot open {s}\n", .{archive_path});
                fx.exit(1);
            }
            extractArchive(in_fd2, verbose, mode_list, true);
            _ = fx.close(in_fd2);
        } else {
            extractArchive(in_fd, verbose, mode_list, is_gz);
            _ = fx.close(in_fd);
        }
    }

    fx.exit(0);
}
