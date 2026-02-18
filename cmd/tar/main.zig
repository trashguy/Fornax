const fx = @import("fornax");

const out = fx.io.Writer.stdout;
const err = fx.io.Writer.stderr;

// ── BSS Buffers ──────────────────────────────────────────────────────
var sliding_window: [32768]u8 linksection(".bss") = undefined;
var io_buf: [8192]u8 linksection(".bss") = undefined;
var file_buf: [8192]u8 linksection(".bss") = undefined;
var dir_buf: [4096]u8 linksection(".bss") = undefined;
var crc_table: [256]u32 linksection(".bss") = undefined;
var path_scratch: [512]u8 linksection(".bss") = undefined;

// ── CRC32 ────────────────────────────────────────────────────────────
var crc_initialized = false;

fn initCrcTable() void {
    if (crc_initialized) return;
    for (0..256) |i| {
        var c: u32 = @intCast(i);
        for (0..8) |_| {
            if (c & 1 != 0) {
                c = 0xEDB88320 ^ (c >> 1);
            } else {
                c = c >> 1;
            }
        }
        crc_table[i] = c;
    }
    crc_initialized = true;
}

fn crc32update(crc: u32, data: []const u8) u32 {
    var c = crc ^ 0xFFFFFFFF;
    for (data) |b| {
        c = crc_table[(c ^ b) & 0xFF] ^ (c >> 8);
    }
    return c ^ 0xFFFFFFFF;
}

// ── USTAR header ─────────────────────────────────────────────────────
const HEADER_SIZE = 512;

fn writeOctal(buf: []u8, val: u64) void {
    var v = val;
    var i: usize = buf.len;
    // Null terminator
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

fn parseOctal(buf: []const u8) u64 {
    var val: u64 = 0;
    for (buf) |c| {
        if (c == 0 or c == ' ') continue;
        if (c < '0' or c > '7') break;
        val = (val << 3) + (c - '0');
    }
    return val;
}

fn computeChecksum(header: *[HEADER_SIZE]u8) u32 {
    var sum: u32 = 0;
    for (0..HEADER_SIZE) |i| {
        if (i >= 148 and i < 156) {
            sum += ' '; // checksum field treated as spaces
        } else {
            sum += header[i];
        }
    }
    return sum;
}

fn fillHeader(header: *[HEADER_SIZE]u8, name: []const u8, size: u64, mode: u32, uid: u16, gid: u16, typeflag: u8) void {
    @memset(header, 0);

    // Handle long paths: split into prefix + name
    if (name.len > 100) {
        // Find a '/' to split at, within first 155 chars
        var split: usize = 0;
        var i: usize = @min(name.len - 1, 155);
        while (i > 0) : (i -= 1) {
            if (name[i] == '/') {
                split = i;
                break;
            }
        }
        if (split > 0 and name.len - split - 1 <= 100) {
            // prefix = name[0..split], name = name[split+1..]
            const prefix_len = @min(split, 155);
            @memcpy(header[345..][0..prefix_len], name[0..prefix_len]);
            const rest = name[split + 1 ..];
            const rest_len = @min(rest.len, 100);
            @memcpy(header[0..rest_len], rest[0..rest_len]);
        } else {
            // Can't split nicely, truncate
            @memcpy(header[0..100], name[0..100]);
        }
    } else {
        const len = @min(name.len, 100);
        @memcpy(header[0..len], name[0..len]);
    }

    // mode (octal, 8 bytes)
    writeOctal(header[100..108], mode);
    // uid (octal, 8 bytes)
    writeOctal(header[108..116], uid);
    // gid (octal, 8 bytes)
    writeOctal(header[116..124], gid);
    // size (octal, 12 bytes)
    writeOctal(header[124..136], size);
    // mtime (octal, 12 bytes) - 0 for now
    writeOctal(header[136..148], 0);
    // typeflag
    header[156] = typeflag;
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

    // Compute and write checksum
    const cksum = computeChecksum(header);
    writeOctal(header[148..155], cksum);
    header[155] = ' ';
}

fn isZeroBlock(block: *const [HEADER_SIZE]u8) bool {
    for (block) |b| {
        if (b != 0) return false;
    }
    return true;
}

// ── Archive I/O buffering ────────────────────────────────────────────
var archive_fd: i32 = -1;
var io_pos: usize = 0; // write position in io_buf
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
    // 10-byte gzip header: magic(2), method(1), flags(1), mtime(4), xfl(1), os(1)
    const hdr = [10]u8{ 0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xFF };
    archiveWriteRaw(&hdr);
    archive_crc = 0;
    archive_size = 0;
}

fn gzipWriteStored(data: []const u8) void {
    // Update CRC and size tracking
    archive_crc = crc32update(archive_crc, data);
    archive_size +%= @intCast(data.len);

    // Write as stored DEFLATE blocks (type 0)
    var offset: usize = 0;
    while (offset < data.len) {
        const remaining = data.len - offset;
        const chunk_len: u16 = @intCast(@min(remaining, 65535));
        const is_last: u8 = if (offset + chunk_len >= data.len) 0 else 0; // not final yet
        _ = is_last;
        // 5-byte stored block header: bfinal=0, len_lo, len_hi, ~len_lo, ~len_hi
        const nlen = ~chunk_len;
        const block_hdr = [5]u8{
            0, // bfinal=0 (we'll finalize in trailer)
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
    // Write final empty stored block with bfinal=1
    const final_block = [5]u8{ 1, 0, 0, 0xFF, 0xFF };
    archiveWriteRaw(&final_block);

    // 8-byte trailer: CRC32 + original size mod 2^32
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

// ── BitReader (for gzip inflate) ─────────────────────────────────────
const BitReader = struct {
    fd: i32,
    buf_pos: usize,
    buf_len: usize,
    bit_buf: u32,
    bit_count: u5,

    fn init(fd: i32) BitReader {
        return .{
            .fd = fd,
            .buf_pos = 0,
            .buf_len = 0,
            .bit_buf = 0,
            .bit_count = 0,
        };
    }

    fn readByte(self: *BitReader) ?u8 {
        if (self.buf_pos >= self.buf_len) {
            const n = fx.read(self.fd, &io_buf);
            if (n <= 0) return null;
            self.buf_len = @intCast(n);
            self.buf_pos = 0;
        }
        const b = io_buf[self.buf_pos];
        self.buf_pos += 1;
        return b;
    }

    fn readBits(self: *BitReader, count: u5) ?u32 {
        while (self.bit_count < count) {
            const b = self.readByte() orelse return null;
            self.bit_buf |= @as(u32, b) << self.bit_count;
            self.bit_count += 8;
        }
        const mask = (@as(u32, 1) << count) - 1;
        const val = self.bit_buf & mask;
        self.bit_buf >>= count;
        self.bit_count -= count;
        return val;
    }

    fn readBitsWide(self: *BitReader, count: u8) ?u32 {
        if (count == 0) return 0;
        if (count > 25) {
            const lo = self.readBitsWide(16) orelse return null;
            const hi = self.readBitsWide(count - 16) orelse return null;
            return lo | (hi << 16);
        }
        while (self.bit_count < @as(u5, @intCast(count))) {
            const b = self.readByte() orelse return null;
            self.bit_buf |= @as(u32, b) << self.bit_count;
            self.bit_count += 8;
        }
        const mask = (@as(u32, 1) << @intCast(count)) - 1;
        const val = self.bit_buf & mask;
        self.bit_buf >>= @intCast(count);
        self.bit_count -= @intCast(count);
        return val;
    }

    fn alignToByte(self: *BitReader) void {
        self.bit_buf = 0;
        self.bit_count = 0;
    }
};

// ── Huffman Table ────────────────────────────────────────────────────
const MAX_SYMBOLS = 288;
const MAX_BITS = 15;

const HuffmanTable = struct {
    counts: [MAX_BITS + 1]u16,
    symbols: [MAX_SYMBOLS]u16,
    num_symbols: u16,

    fn build(self: *HuffmanTable, lengths: []const u8, n: usize) void {
        self.num_symbols = @intCast(n);
        for (&self.counts) |*c| c.* = 0;
        for (0..n) |i| {
            if (lengths[i] > 0 and lengths[i] <= MAX_BITS) {
                self.counts[lengths[i]] += 1;
            }
        }
        var offsets: [MAX_BITS + 1]u16 = undefined;
        offsets[0] = 0;
        var total: u16 = 0;
        for (1..MAX_BITS + 1) |bits| {
            offsets[bits] = total;
            total += self.counts[bits];
        }
        for (0..n) |i| {
            const len = lengths[i];
            if (len > 0 and len <= MAX_BITS) {
                self.symbols[offsets[len]] = @intCast(i);
                offsets[len] += 1;
            }
        }
    }

    fn decode(self: *const HuffmanTable, reader: *BitReader) ?u16 {
        var code: u32 = 0;
        var first: u32 = 0;
        var index: u32 = 0;
        for (1..MAX_BITS + 1) |bit_len| {
            const b = reader.readBits(1) orelse return null;
            code = (code << 1) | b;
            const count: u32 = self.counts[bit_len];
            if (code -% first < count) {
                return self.symbols[index + code - first];
            }
            index += count;
            first = (first + count) << 1;
        }
        return null;
    }
};

// ── DEFLATE tables ───────────────────────────────────────────────────
const len_base = [_]u16{
    3,   4,   5,   6,   7,   8,   9,   10,  11,  13,
    15,  17,  19,  23,  27,  31,  35,  43,  51,  59,
    67,  83,  99,  115, 131, 163, 195, 227, 258,
};
const len_extra = [_]u8{
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1,
    1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
    4, 4, 4, 4, 5, 5, 5, 5, 0,
};
const dist_base = [_]u16{
    1,    2,    3,    4,    5,    7,    9,    13,    17,    25,
    33,   49,   65,   97,   129,  193,  257,  385,   513,   769,
    1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
};
const dist_extra = [_]u8{
    0,  0,  0,  0,  1,  1,  2,  2,  3,  3,
    4,  4,  5,  5,  6,  6,  7,  7,  8,  8,
    9,  9,  10, 10, 11, 11, 12, 12, 13, 13,
};
const cl_order = [_]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

var fixed_lit_table: HuffmanTable = undefined;
var fixed_dist_table: HuffmanTable = undefined;
var fixed_tables_built = false;

fn buildFixedTables() void {
    if (fixed_tables_built) return;
    var lit_lengths: [288]u8 = undefined;
    for (0..144) |i| lit_lengths[i] = 8;
    for (144..256) |i| lit_lengths[i] = 9;
    for (256..280) |i| lit_lengths[i] = 7;
    for (280..288) |i| lit_lengths[i] = 8;
    fixed_lit_table.build(&lit_lengths, 288);
    var dist_lengths: [32]u8 = undefined;
    for (&dist_lengths) |*d| d.* = 5;
    fixed_dist_table.build(&dist_lengths, 32);
    fixed_tables_built = true;
}

// ── Inflate output to buffer ─────────────────────────────────────────
var inflate_out_buf: [HEADER_SIZE]u8 = undefined;
var inflate_out_pos: usize = 0;
var inflate_out_ready: usize = 0;
var win_pos: usize = 0;

fn inflateWriteByte(b: u8) void {
    sliding_window[win_pos] = b;
    win_pos = (win_pos + 1) & 0x7FFF;
    inflate_out_buf[inflate_out_ready] = b;
    inflate_out_ready += 1;
}

fn inflateCopyFromWindow(dist: u16, length: u16) void {
    var src = (win_pos -% @as(usize, dist)) & 0x7FFF;
    for (0..length) |_| {
        const b = sliding_window[src];
        src = (src + 1) & 0x7FFF;
        inflateWriteByte(b);
    }
}

// ── DEFLATE inflater ─────────────────────────────────────────────────
fn inflateBlock(reader: *BitReader, lit_table: *const HuffmanTable, dist_table: *const HuffmanTable) bool {
    while (true) {
        // If output buffer is full enough, return to let caller consume
        if (inflate_out_ready >= inflate_out_buf.len) return true;

        const sym = lit_table.decode(reader) orelse return false;
        if (sym < 256) {
            inflateWriteByte(@intCast(sym));
        } else if (sym == 256) {
            return true;
        } else {
            const len_idx = sym - 257;
            if (len_idx >= len_base.len) return false;
            const extra_len = len_extra[len_idx];
            var length: u16 = len_base[len_idx];
            if (extra_len > 0) {
                const extra = reader.readBitsWide(extra_len) orelse return false;
                length += @intCast(extra);
            }
            const dist_sym = dist_table.decode(reader) orelse return false;
            if (dist_sym >= dist_base.len) return false;
            const extra_dist = dist_extra[dist_sym];
            var distance: u16 = dist_base[dist_sym];
            if (extra_dist > 0) {
                const extra = reader.readBitsWide(extra_dist) orelse return false;
                distance += @intCast(extra);
            }
            inflateCopyFromWindow(distance, length);
        }
    }
}

// ── GzipReader: decompresses gzip stream, serves 512-byte tar blocks ─
const GzipReader = struct {
    reader: BitReader,
    done: bool,
    // Current DEFLATE block state
    in_block: bool,
    bfinal: bool,
    btype: u2,
    stored_remaining: u16,
    lit_table_ptr: ?*const HuffmanTable,
    dist_table_ptr: ?*const HuffmanTable,
    dyn_lit_table: HuffmanTable,
    dyn_dist_table: HuffmanTable,

    fn init(fd: i32) GzipReader {
        return .{
            .reader = BitReader.init(fd),
            .done = false,
            .in_block = false,
            .bfinal = false,
            .btype = 0,
            .stored_remaining = 0,
            .lit_table_ptr = null,
            .dist_table_ptr = null,
            .dyn_lit_table = undefined,
            .dyn_dist_table = undefined,
        };
    }

    fn skipGzipHeader(self: *GzipReader) bool {
        // Read 10-byte header
        const magic1 = self.reader.readByte() orelse return false;
        const magic2 = self.reader.readByte() orelse return false;
        if (magic1 != 0x1f or magic2 != 0x8b) return false;
        const method = self.reader.readByte() orelse return false;
        if (method != 8) return false;
        const flags = self.reader.readByte() orelse return false;
        // Skip mtime(4), xfl(1), os(1)
        for (0..6) |_| _ = self.reader.readByte() orelse return false;

        // Skip optional fields
        if (flags & 0x04 != 0) { // FEXTRA
            const lo = self.reader.readByte() orelse return false;
            const hi = self.reader.readByte() orelse return false;
            const xlen = @as(u16, lo) | (@as(u16, hi) << 8);
            for (0..xlen) |_| _ = self.reader.readByte() orelse return false;
        }
        if (flags & 0x08 != 0) { // FNAME
            while (true) {
                const b = self.reader.readByte() orelse return false;
                if (b == 0) break;
            }
        }
        if (flags & 0x10 != 0) { // FCOMMENT
            while (true) {
                const b = self.reader.readByte() orelse return false;
                if (b == 0) break;
            }
        }
        if (flags & 0x02 != 0) { // FHCRC
            _ = self.reader.readByte() orelse return false;
            _ = self.reader.readByte() orelse return false;
        }
        return true;
    }

    /// Read exactly 512 bytes of decompressed tar data into dest.
    /// Returns true on success, false on EOF/error.
    fn readBlock(self: *GzipReader, dest: *[HEADER_SIZE]u8) bool {
        if (self.done) return false;

        inflate_out_pos = 0;
        inflate_out_ready = 0;

        while (inflate_out_ready < HEADER_SIZE) {
            if (!self.in_block) {
                // Start new DEFLATE block
                const bf = self.reader.readBits(1) orelse return false;
                const bt = self.reader.readBits(2) orelse return false;
                self.bfinal = bf == 1;
                self.btype = @intCast(bt);
                self.in_block = true;

                switch (self.btype) {
                    0 => {
                        self.reader.alignToByte();
                        const len_lo = self.reader.readBitsWide(16) orelse return false;
                        _ = self.reader.readBitsWide(16) orelse return false;
                        self.stored_remaining = @intCast(len_lo);
                    },
                    1 => {
                        buildFixedTables();
                        self.lit_table_ptr = &fixed_lit_table;
                        self.dist_table_ptr = &fixed_dist_table;
                    },
                    2 => {
                        if (!self.decodeDynamicTables()) return false;
                        self.lit_table_ptr = &self.dyn_lit_table;
                        self.dist_table_ptr = &self.dyn_dist_table;
                    },
                    else => return false,
                }
            }

            // Decode data from current block
            if (self.btype == 0) {
                // Stored block
                while (self.stored_remaining > 0 and inflate_out_ready < HEADER_SIZE) {
                    const b = self.reader.readByte() orelse return false;
                    inflateWriteByte(b);
                    self.stored_remaining -= 1;
                }
                if (self.stored_remaining == 0) {
                    self.in_block = false;
                    if (self.bfinal) {
                        self.done = true;
                        break;
                    }
                }
            } else {
                // Huffman block
                const lt = self.lit_table_ptr orelse return false;
                const dt = self.dist_table_ptr orelse return false;
                while (inflate_out_ready < HEADER_SIZE) {
                    const sym = lt.decode(&self.reader) orelse return false;
                    if (sym < 256) {
                        inflateWriteByte(@intCast(sym));
                    } else if (sym == 256) {
                        self.in_block = false;
                        if (self.bfinal) self.done = true;
                        break;
                    } else {
                        const len_idx = sym - 257;
                        if (len_idx >= len_base.len) return false;
                        const el = len_extra[len_idx];
                        var length: u16 = len_base[len_idx];
                        if (el > 0) {
                            const extra = self.reader.readBitsWide(el) orelse return false;
                            length += @intCast(extra);
                        }
                        const dist_sym = dt.decode(&self.reader) orelse return false;
                        if (dist_sym >= dist_base.len) return false;
                        const ed = dist_extra[dist_sym];
                        var distance: u16 = dist_base[dist_sym];
                        if (ed > 0) {
                            const extra = self.reader.readBitsWide(ed) orelse return false;
                            distance += @intCast(extra);
                        }
                        inflateCopyFromWindow(distance, length);
                    }
                }
            }
        }

        if (inflate_out_ready >= HEADER_SIZE) {
            @memcpy(dest, inflate_out_buf[0..HEADER_SIZE]);
            return true;
        }
        // Partial final block — pad with zeros
        @memcpy(dest[0..inflate_out_ready], inflate_out_buf[0..inflate_out_ready]);
        @memset(dest[inflate_out_ready..], 0);
        return true;
    }

    fn decodeDynamicTables(self: *GzipReader) bool {
        const hlit = (self.reader.readBits(5) orelse return false) + 257;
        const hdist = (self.reader.readBits(5) orelse return false) + 1;
        const hclen = (self.reader.readBits(4) orelse return false) + 4;

        var cl_lengths: [19]u8 = .{0} ** 19;
        for (0..hclen) |i| {
            cl_lengths[cl_order[i]] = @intCast(self.reader.readBits(3) orelse return false);
        }

        var cl_table: HuffmanTable = undefined;
        cl_table.build(&cl_lengths, 19);

        var all_lengths: [288 + 32]u8 = .{0} ** (288 + 32);
        const total_codes = hlit + hdist;
        var i: u32 = 0;
        while (i < total_codes) {
            const sym = cl_table.decode(&self.reader) orelse return false;
            if (sym < 16) {
                all_lengths[i] = @intCast(sym);
                i += 1;
            } else if (sym == 16) {
                const rep = (self.reader.readBits(2) orelse return false) + 3;
                if (i == 0) return false;
                const prev = all_lengths[i - 1];
                for (0..rep) |_| {
                    if (i >= total_codes) break;
                    all_lengths[i] = prev;
                    i += 1;
                }
            } else if (sym == 17) {
                const rep = (self.reader.readBits(3) orelse return false) + 3;
                for (0..rep) |_| {
                    if (i >= total_codes) break;
                    all_lengths[i] = 0;
                    i += 1;
                }
            } else if (sym == 18) {
                const rep = (self.reader.readBitsWide(7) orelse return false) + 11;
                for (0..rep) |_| {
                    if (i >= total_codes) break;
                    all_lengths[i] = 0;
                    i += 1;
                }
            } else {
                return false;
            }
        }

        self.dyn_lit_table.build(all_lengths[0..hlit], hlit);
        self.dyn_dist_table.build(all_lengths[hlit .. hlit + hdist], hdist);
        return true;
    }
};

// ── Path helpers ─────────────────────────────────────────────────────
fn isSafePath(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] == '/') return false;
    var i: usize = 0;
    while (i + 2 < name.len) : (i += 1) {
        if (name[i] == '.' and name[i + 1] == '.' and name[i + 2] == '/') return false;
    }
    if (name.len >= 2 and name[name.len - 2] == '.' and name[name.len - 1] == '.') return false;
    return true;
}

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

fn headerName(header: *const [HEADER_SIZE]u8) []const u8 {
    // Check for prefix
    var prefix_len: usize = 0;
    if (header[345] != 0) {
        while (prefix_len < 155 and header[345 + prefix_len] != 0) : (prefix_len += 1) {}
    }

    var name_len: usize = 0;
    while (name_len < 100 and header[name_len] != 0) : (name_len += 1) {}

    if (prefix_len > 0) {
        const total = prefix_len + 1 + name_len;
        if (total <= path_scratch.len) {
            @memcpy(path_scratch[0..prefix_len], header[345..][0..prefix_len]);
            path_scratch[prefix_len] = '/';
            @memcpy(path_scratch[prefix_len + 1 ..][0..name_len], header[0..name_len]);
            return path_scratch[0..total];
        }
    }

    return header[0..name_len];
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
        // Directory
        var header: [HEADER_SIZE]u8 = undefined;
        // Ensure trailing slash for directory name
        var dir_name: [256]u8 = undefined;
        const dlen = @min(clean.len, 254);
        @memcpy(dir_name[0..dlen], clean[0..dlen]);
        var final_len = dlen;
        if (dlen > 0 and clean[dlen - 1] != '/') {
            dir_name[dlen] = '/';
            final_len = dlen + 1;
        }
        fillHeader(&header, dir_name[0..final_len], 0, st.mode & 0o7777, st.uid, st.gid, '5');
        archiveWrite(&header);
        if (verbose) {
            out.puts(dir_name[0..final_len]);
            out.putc('\n');
        }

        // Read directory entries and recurse
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
            // Need to copy because child_path may be clobbered by recursion
            var cp_copy: [512]u8 = undefined;
            @memcpy(cp_copy[0..cp.len], cp);
            addEntry(cp_copy[0..cp.len], verbose);
        }
    } else {
        // Regular file
        var header: [HEADER_SIZE]u8 = undefined;
        fillHeader(&header, clean, st.size, st.mode & 0o7777, st.uid, st.gid, '0');
        archiveWrite(&header);
        if (verbose) {
            out.puts(clean);
            out.putc('\n');
        }

        // Copy file data in blocks
        var remaining: u64 = st.size;
        while (remaining > 0) {
            const to_read: usize = @intCast(@min(remaining, file_buf.len));
            const nr = fx.read(fd, file_buf[0..to_read]);
            if (nr <= 0) break;
            const nbytes: usize = @intCast(nr);
            archiveWrite(file_buf[0..nbytes]);
            remaining -= nbytes;
        }

        // Pad to 512-byte boundary
        const tail: usize = @intCast(st.size % HEADER_SIZE);
        if (tail > 0) {
            var padding: [HEADER_SIZE]u8 = undefined;
            @memset(&padding, 0);
            archiveWrite(padding[0 .. HEADER_SIZE - tail]);
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
        var header: [HEADER_SIZE]u8 = undefined;
        while (true) {
            if (!gz.readBlock(&header)) break;
            if (isZeroBlock(&header)) {
                zero_blocks += 1;
                if (zero_blocks >= 2) break;
                continue;
            }
            zero_blocks = 0;
            processEntry(&header, null, &gz, verbose, list_only);
        }
    } else {
        var header: [HEADER_SIZE]u8 = undefined;
        while (true) {
            const n = fx.read(in_fd, &header);
            if (n < HEADER_SIZE) break;
            if (isZeroBlock(&header)) {
                zero_blocks += 1;
                if (zero_blocks >= 2) break;
                continue;
            }
            zero_blocks = 0;
            processEntry(&header, in_fd, null, verbose, list_only);
        }
    }
}

fn processEntry(header: *[HEADER_SIZE]u8, raw_fd: ?i32, gz: ?*GzipReader, verbose: bool, list_only: bool) void {
    // Validate checksum
    const stored_cksum = parseOctal(header[148..156]);
    const actual_cksum = computeChecksum(header);
    if (stored_cksum != actual_cksum) {
        err.puts("tar: checksum error, skipping entry\n");
        return;
    }

    const name = headerName(header);
    const size = parseOctal(header[124..136]);
    const mode_val = parseOctal(header[100..108]);
    const uid_val = parseOctal(header[108..116]);
    const gid_val = parseOctal(header[116..124]);
    const typeflag = header[156];

    if (list_only) {
        if (verbose) {
            // Print permissions
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

        // Skip data blocks
        if (typeflag == '0' or typeflag == 0) {
            skipDataBlocks(raw_fd, gz, size);
        }
        return;
    }

    // Extract
    if (typeflag == '5') {
        // Directory
        if (!isSafePath(name)) {
            err.print("tar: skipping unsafe path: {s}\n", .{name});
            return;
        }
        ensureParentDirs(name);
        // Strip trailing slash for mkdir
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
        // Regular file
        if (!isSafePath(name)) {
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

        // Read data blocks
        var remaining: u64 = size;
        const blocks = (size + HEADER_SIZE - 1) / HEADER_SIZE;
        var block_i: u64 = 0;
        while (block_i < blocks) : (block_i += 1) {
            var block: [HEADER_SIZE]u8 = undefined;
            const got = readArchiveBlock(raw_fd, gz, &block);
            if (!got) break;
            const to_write: usize = @intCast(@min(remaining, HEADER_SIZE));
            _ = fx.syscall.write(out_fd, block[0..to_write]);
            remaining -= to_write;
        }

        // Restore permissions
        _ = fx.wstat(out_fd, @intCast(mode_val & 0o7777), @intCast(uid_val), @intCast(gid_val), fx.WSTAT_MODE | fx.WSTAT_UID | fx.WSTAT_GID);

        _ = fx.close(out_fd);
        if (verbose) {
            out.puts(name);
            out.putc('\n');
        }
    } else {
        // Unknown type — skip data
        if (size > 0) {
            skipDataBlocks(raw_fd, gz, size);
        }
    }
}

fn readArchiveBlock(raw_fd: ?i32, gz: ?*GzipReader, dest: *[HEADER_SIZE]u8) bool {
    if (gz) |g| {
        return g.readBlock(dest);
    } else if (raw_fd) |fd| {
        const n = fx.read(fd, dest);
        return n >= HEADER_SIZE;
    }
    return false;
}

fn skipDataBlocks(raw_fd: ?i32, gz: ?*GzipReader, size: u64) void {
    const blocks = (size + HEADER_SIZE - 1) / HEADER_SIZE;
    var block: [HEADER_SIZE]u8 = undefined;
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
    // Type
    if (m & 0o40000 != 0) {
        out.putc('d');
    } else {
        out.putc('-');
    }
    // Owner
    out.putc(if (m & 0o400 != 0) 'r' else '-');
    out.putc(if (m & 0o200 != 0) 'w' else '-');
    out.putc(if (m & 0o100 != 0) 'x' else '-');
    // Group
    out.putc(if (m & 0o040 != 0) 'r' else '-');
    out.putc(if (m & 0o020 != 0) 'w' else '-');
    out.putc(if (m & 0o010 != 0) 'x' else '-');
    // Other
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

fn startsWith(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    for (prefix, 0..) |c, i| {
        if (s[i] != c) return false;
    }
    return true;
}

// ── Main ─────────────────────────────────────────────────────────────
export fn _start() noreturn {
    const args = fx.getArgs();

    if (args.len < 2) {
        err.puts("Usage: tar [cxtv][z]f archive [files...]\n");
        fx.exit(1);
    }

    // Parse flags from first arg
    const flags_str = argSlice(args[1]);
    var mode_create = false;
    var mode_extract = false;
    var mode_list = false;
    var verbose = false;
    var gzip = false;
    var f_flag = false;

    for (flags_str) |c| {
        switch (c) {
            '-' => {}, // allow leading dash
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

    // Validate: exactly one mode
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

        initCrcTable();

        // Open archive for writing
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

        // Add each file/dir argument
        for (args[3..]) |arg| {
            const path = argSlice(arg);
            addEntry(path, verbose);
        }

        // Write two zero blocks (end of archive)
        var zero_block: [HEADER_SIZE]u8 = undefined;
        @memset(&zero_block, 0);
        archiveWrite(&zero_block);
        archiveWrite(&zero_block);

        if (gzip) {
            gzipWriteTrailer();
        }

        archiveFlush();
        _ = fx.close(archive_fd);
    } else {
        // Extract or list
        const in_fd = fx.open(archive_path);
        if (in_fd < 0) {
            err.print("tar: cannot open {s}\n", .{archive_path});
            fx.exit(1);
        }

        // Auto-detect gzip if z flag set, or check magic
        var is_gz = gzip;
        if (!is_gz) {
            // Peek at first two bytes
            var magic: [2]u8 = undefined;
            const pn = fx.pread(in_fd, &magic, 0);
            if (pn >= 2 and magic[0] == 0x1f and magic[1] == 0x8b) {
                is_gz = true;
            }
            // Rewind not needed — extractArchive opens fresh reader
        }

        // For gzip, we need to re-open or use the same fd (read position is at start for gz reader)
        if (is_gz and !gzip) {
            // We read 2 bytes for detection. Close and reopen to reset position.
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
