const fx = @import("fornax");

const out = fx.io.Writer.stdout;
const err = fx.io.Writer.stderr;

// ── BSS Buffers ──────────────────────────────────────────────────────
var sliding_window: [32768]u8 linksection(".bss") = undefined;
var input_buf: [8192]u8 linksection(".bss") = undefined;
var out_buf: [8192]u8 linksection(".bss") = undefined;
var crc_table: [256]u32 linksection(".bss") = undefined;
var filename_buf: [512]u8 linksection(".bss") = undefined;
var path_buf: [512]u8 linksection(".bss") = undefined;

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

// ── BitReader (LSB-first, pread-backed) ──────────────────────────────
const BitReader = struct {
    zip_fd: i32,
    file_offset: u64, // current read position in ZIP file
    bytes_remaining: u64, // compressed bytes left for this entry
    buf_pos: usize,
    buf_len: usize,
    bit_buf: u32,
    bit_count: u5,

    fn init(zip_fd: i32, offset: u64, comp_size: u64) BitReader {
        return .{
            .zip_fd = zip_fd,
            .file_offset = offset,
            .bytes_remaining = comp_size,
            .buf_pos = 0,
            .buf_len = 0,
            .bit_buf = 0,
            .bit_count = 0,
        };
    }

    fn readByte(self: *BitReader) ?u8 {
        if (self.buf_pos >= self.buf_len) {
            if (self.bytes_remaining == 0) return null;
            const to_read: usize = @intCast(@min(self.bytes_remaining, input_buf.len));
            const n = fx.pread(self.zip_fd, input_buf[0..to_read], self.file_offset);
            if (n <= 0) return null;
            const nbytes: usize = @intCast(n);
            self.buf_len = nbytes;
            self.buf_pos = 0;
            self.file_offset += nbytes;
            self.bytes_remaining -= nbytes;
        }
        const b = input_buf[self.buf_pos];
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
        // For counts > 25, read in two parts
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
        // Count code lengths
        for (&self.counts) |*c| c.* = 0;
        for (0..n) |i| {
            if (lengths[i] > 0 and lengths[i] <= MAX_BITS) {
                self.counts[lengths[i]] += 1;
            }
        }

        // Compute starting codes for each length
        var offsets: [MAX_BITS + 1]u16 = undefined;
        offsets[0] = 0;
        var total: u16 = 0;
        for (1..MAX_BITS + 1) |bits| {
            offsets[bits] = total;
            total += self.counts[bits];
        }

        // Fill symbols table
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
            // In LSB-first reading, we reverse bits for canonical Huffman
            // Actually, for canonical Huffman with LSB-first, we use a different approach:
            // We accumulate bits and check against the canonical code ranges
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

// ── DEFLATE tables (RFC 1951 §3.2.5) ────────────────────────────────
const len_base = [_]u16{
    3,  4,  5,  6,  7,  8,  9,  10,  11,  13,
    15, 17, 19, 23, 27, 31, 35,  43,  51,  59,
    67, 83, 99, 115, 131, 163, 195, 227, 258,
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

// Code length order for dynamic Huffman (RFC 1951 §3.2.7)
const cl_order = [_]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

// ── Output writer with buffering ─────────────────────────────────────
const OutputWriter = struct {
    fd: i32,
    pos: usize,
    crc: u32,
    total: u64,
    win_pos: usize, // sliding window position

    fn init(fd: i32) OutputWriter {
        return .{ .fd = fd, .pos = 0, .crc = 0, .total = 0, .win_pos = 0 };
    }

    fn writeByte(self: *OutputWriter, b: u8) void {
        sliding_window[self.win_pos] = b;
        self.win_pos = (self.win_pos + 1) & 0x7FFF; // mod 32768

        out_buf[self.pos] = b;
        self.pos += 1;
        if (self.pos >= out_buf.len) {
            self.flushBuf();
        }
    }

    fn copyFromWindow(self: *OutputWriter, dist: u16, length: u16) void {
        var src = (self.win_pos -% @as(usize, dist)) & 0x7FFF;
        for (0..length) |_| {
            const b = sliding_window[src];
            src = (src + 1) & 0x7FFF;
            self.writeByte(b);
        }
    }

    fn flushBuf(self: *OutputWriter) void {
        if (self.pos > 0) {
            self.crc = crc32update(self.crc, out_buf[0..self.pos]);
            self.total += self.pos;
            _ = fx.syscall.write(self.fd, out_buf[0..self.pos]);
            self.pos = 0;
        }
    }
};

// ── Fixed Huffman tables (RFC 1951 §3.2.6) ──────────────────────────
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

// ── DEFLATE inflater ─────────────────────────────────────────────────
fn inflateBlock(reader: *BitReader, writer: *OutputWriter, lit_table: *const HuffmanTable, dist_table: *const HuffmanTable) bool {
    while (true) {
        const sym = lit_table.decode(reader) orelse return false;

        if (sym < 256) {
            writer.writeByte(@intCast(sym));
        } else if (sym == 256) {
            return true; // end of block
        } else {
            // Length/distance pair
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

            writer.copyFromWindow(distance, length);
        }
    }
}

fn inflate(reader: *BitReader, writer: *OutputWriter) bool {
    while (true) {
        const bfinal = reader.readBits(1) orelse return false;
        const btype = reader.readBits(2) orelse return false;

        switch (btype) {
            0 => {
                // Stored block
                reader.alignToByte();
                const len_lo = reader.readBitsWide(16) orelse return false;
                _ = reader.readBitsWide(16) orelse return false; // nlen (complement, skip)
                const len: u16 = @intCast(len_lo);
                for (0..len) |_| {
                    const b = reader.readByte() orelse return false;
                    // For stored blocks, we read bytes directly (bit reader was aligned)
                    writer.writeByte(b);
                }
            },
            1 => {
                // Fixed Huffman
                buildFixedTables();
                if (!inflateBlock(reader, writer, &fixed_lit_table, &fixed_dist_table)) return false;
            },
            2 => {
                // Dynamic Huffman
                const hlit = (reader.readBits(5) orelse return false) + 257;
                const hdist = (reader.readBits(5) orelse return false) + 1;
                const hclen = (reader.readBits(4) orelse return false) + 4;

                // Read code length code lengths
                var cl_lengths: [19]u8 = .{0} ** 19;
                for (0..hclen) |i| {
                    cl_lengths[cl_order[i]] = @intCast(reader.readBits(3) orelse return false);
                }

                var cl_table: HuffmanTable = undefined;
                cl_table.build(&cl_lengths, 19);

                // Decode literal/length + distance code lengths
                var all_lengths: [288 + 32]u8 = .{0} ** (288 + 32);
                const total_codes = hlit + hdist;
                var i: u32 = 0;
                while (i < total_codes) {
                    const sym = cl_table.decode(reader) orelse return false;
                    if (sym < 16) {
                        all_lengths[i] = @intCast(sym);
                        i += 1;
                    } else if (sym == 16) {
                        // Repeat previous length 3-6 times
                        const rep = (reader.readBits(2) orelse return false) + 3;
                        if (i == 0) return false;
                        const prev = all_lengths[i - 1];
                        for (0..rep) |_| {
                            if (i >= total_codes) break;
                            all_lengths[i] = prev;
                            i += 1;
                        }
                    } else if (sym == 17) {
                        // Repeat 0 for 3-10 times
                        const rep = (reader.readBits(3) orelse return false) + 3;
                        for (0..rep) |_| {
                            if (i >= total_codes) break;
                            all_lengths[i] = 0;
                            i += 1;
                        }
                    } else if (sym == 18) {
                        // Repeat 0 for 11-138 times
                        const rep = (reader.readBitsWide(7) orelse return false) + 11;
                        for (0..rep) |_| {
                            if (i >= total_codes) break;
                            all_lengths[i] = 0;
                            i += 1;
                        }
                    } else {
                        return false;
                    }
                }

                var dyn_lit_table: HuffmanTable = undefined;
                var dyn_dist_table: HuffmanTable = undefined;
                dyn_lit_table.build(all_lengths[0..hlit], hlit);
                dyn_dist_table.build(all_lengths[hlit .. hlit + hdist], hdist);

                if (!inflateBlock(reader, writer, &dyn_lit_table, &dyn_dist_table)) return false;
            },
            else => return false, // reserved
        }

        if (bfinal == 1) break;
    }
    return true;
}

// ── ZIP reading helpers ──────────────────────────────────────────────
fn readU16(buf: []const u8) u16 {
    return @as(u16, buf[0]) | (@as(u16, buf[1]) << 8);
}

fn readU32(buf: []const u8) u32 {
    return @as(u32, buf[0]) | (@as(u32, buf[1]) << 8) | (@as(u32, buf[2]) << 16) | (@as(u32, buf[3]) << 24);
}

// ── Path safety ──────────────────────────────────────────────────────
fn isSafePath(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] == '/') return false;
    // Check for ../
    var i: usize = 0;
    while (i + 2 < name.len) : (i += 1) {
        if (name[i] == '.' and name[i + 1] == '.' and name[i + 2] == '/') return false;
    }
    // Check trailing ..
    if (name.len >= 2 and name[name.len - 2] == '.' and name[name.len - 1] == '.') return false;
    return true;
}

fn ensureParentDirs(name: []const u8) void {
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        if (name[i] == '/' and i > 0) {
            if (i < path_buf.len) {
                @memcpy(path_buf[0..i], name[0..i]);
                _ = fx.mkdir(path_buf[0..i]);
                // Ignore errors — dir may already exist
            }
        }
    }
}

// ── Stored extraction (method 0) ─────────────────────────────────────
fn extractStored(zip_fd: i32, data_offset: u64, size: u32, out_fd: i32) u32 {
    var crc: u32 = 0;
    var remaining: u64 = size;
    var offset = data_offset;

    while (remaining > 0) {
        const to_read: usize = @intCast(@min(remaining, input_buf.len));
        const n = fx.pread(zip_fd, input_buf[0..to_read], offset);
        if (n <= 0) break;
        const nbytes: usize = @intCast(n);
        crc = crc32update(crc, input_buf[0..nbytes]);
        _ = fx.syscall.write(out_fd, input_buf[0..nbytes]);
        offset += nbytes;
        remaining -= nbytes;
    }
    return crc;
}

// ── Main ─────────────────────────────────────────────────────────────
fn argSlice(arg: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (arg[len] != 0) : (len += 1) {}
    return arg[0..len];
}

export fn _start() noreturn {
    const args = fx.getArgs();

    if (args.len < 2) {
        err.puts("Usage: unzip file.zip\n");
        fx.exit(1);
    }

    const zip_path = argSlice(args[1]);
    initCrcTable();

    // Open ZIP file
    const zip_fd = fx.open(zip_path);
    if (zip_fd < 0) {
        err.print("unzip: cannot open {s}\n", .{zip_path});
        fx.exit(1);
    }

    out.print("Archive: {s}\n", .{zip_path});

    var header: [30]u8 = undefined;
    var offset: u64 = 0;
    var file_count: u32 = 0;

    while (true) {
        // Read local file header
        const hn = fx.pread(zip_fd, &header, offset);
        if (hn < 30) break;

        const sig = readU32(header[0..4]);

        // Central directory or end — stop
        if (sig == 0x02014b50 or sig == 0x06054b50) break;

        // Must be local file header
        if (sig != 0x04034b50) {
            err.puts("unzip: bad header, stopping\n");
            break;
        }

        const method = readU16(header[8..10]);
        const crc_expected = readU32(header[14..18]);
        const comp_size = readU32(header[18..22]);
        const uncomp_size = readU32(header[22..26]);
        const name_len = readU16(header[26..28]);
        const extra_len = readU16(header[28..30]);

        offset += 30;

        // Read filename
        const fn_len: usize = @min(name_len, filename_buf.len);
        if (fn_len > 0) {
            const fn_n = fx.pread(zip_fd, filename_buf[0..fn_len], offset);
            if (fn_n < @as(isize, @intCast(fn_len))) {
                break;
            }
        }
        offset += name_len;
        offset += extra_len;

        const name = filename_buf[0..fn_len];
        const data_offset = offset;
        offset += comp_size; // advance past data

        // Safety check
        if (!isSafePath(name)) {
            err.print("  skipping: {s} (unsafe path)\n", .{name});
            file_count += 1;
            continue;
        }

        // Directory entry
        if (fn_len > 0 and name[fn_len - 1] == '/') {
            out.print("  creating: {s}\n", .{name});
            ensureParentDirs(name);
            _ = fx.mkdir(name[0 .. fn_len - 1]); // mkdir without trailing /
            file_count += 1;
            continue;
        }

        // File entry
        ensureParentDirs(name);
        const out_fd = fx.create(name, 0);
        if (out_fd < 0) {
            err.print("  error: cannot create {s}\n", .{name});
            file_count += 1;
            continue;
        }

        if (method == 0) {
            // Stored
            out.print("extracting: {s}\n", .{name});
            const crc_actual = extractStored(zip_fd, data_offset, uncomp_size, out_fd);
            if (crc_expected != 0 and crc_actual != crc_expected) {
                err.print("  warning: CRC mismatch for {s}\n", .{name});
            }
        } else if (method == 8) {
            // Deflate
            out.print(" inflating: {s}\n", .{name});
            var reader = BitReader.init(zip_fd, data_offset, comp_size);
            var writer = OutputWriter.init(out_fd);
            const ok = inflate(&reader, &writer);
            writer.flushBuf();
            if (!ok) {
                err.print("  warning: inflate error for {s}\n", .{name});
            } else if (crc_expected != 0 and writer.crc != crc_expected) {
                err.print("  warning: CRC mismatch for {s}\n", .{name});
            }
        } else {
            out.print("  skipping: {s} (method {d})\n", .{ name, method });
        }

        _ = fx.close(out_fd);
        file_count += 1;
    }

    _ = fx.close(zip_fd);
    out.print("{d} file(s) processed\n", .{file_count});
    fx.exit(0);
}
