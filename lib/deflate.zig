// DEFLATE decompression (RFC 1951) with generic I/O.
// BitReader uses function-pointer + context for byte reads.
// All buffers are caller-provided (no allocation).

pub const ReadFn = *const fn (ctx: *anyopaque, buf: []u8) isize;

pub const BitReader = struct {
    read_fn: ReadFn,
    ctx: *anyopaque,
    buf: [*]u8,
    buf_size: usize,
    buf_pos: usize,
    buf_len: usize,
    bit_buf: u32,
    bit_count: u5,

    pub fn init(read_fn: ReadFn, ctx: *anyopaque, buf: []u8) BitReader {
        return .{
            .read_fn = read_fn,
            .ctx = ctx,
            .buf = buf.ptr,
            .buf_size = buf.len,
            .buf_pos = 0,
            .buf_len = 0,
            .bit_buf = 0,
            .bit_count = 0,
        };
    }

    pub fn readByte(self: *BitReader) ?u8 {
        if (self.buf_pos >= self.buf_len) {
            const n = self.read_fn(self.ctx, self.buf[0..self.buf_size]);
            if (n <= 0) return null;
            self.buf_len = @intCast(n);
            self.buf_pos = 0;
        }
        const b = self.buf[self.buf_pos];
        self.buf_pos += 1;
        return b;
    }

    pub fn readBits(self: *BitReader, count: u5) ?u32 {
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

    pub fn readBitsWide(self: *BitReader, count: u8) ?u32 {
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

    pub fn alignToByte(self: *BitReader) void {
        self.bit_buf = 0;
        self.bit_count = 0;
    }
};

// ── Huffman Table ────────────────────────────────────────────────────
pub const MAX_SYMBOLS = 288;
pub const MAX_BITS = 15;

pub const HuffmanTable = struct {
    counts: [MAX_BITS + 1]u16,
    symbols: [MAX_SYMBOLS]u16,
    num_symbols: u16,

    pub fn build(self: *HuffmanTable, lengths: []const u8, n: usize) void {
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

    pub fn decode(self: *const HuffmanTable, reader: *BitReader) ?u16 {
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

// ── DEFLATE lookup tables ────────────────────────────────────────────
pub const len_base = [_]u16{
    3,   4,   5,   6,   7,   8,   9,   10,  11,  13,
    15,  17,  19,  23,  27,  31,  35,  43,  51,  59,
    67,  83,  99,  115, 131, 163, 195, 227, 258,
};
pub const len_extra = [_]u8{
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1,
    1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
    4, 4, 4, 4, 5, 5, 5, 5, 0,
};
pub const dist_base = [_]u16{
    1,    2,    3,    4,    5,    7,    9,    13,    17,    25,
    33,   49,   65,   97,   129,  193,  257,  385,   513,   769,
    1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
};
pub const dist_extra = [_]u8{
    0,  0,  0,  0,  1,  1,  2,  2,  3,  3,
    4,  4,  5,  5,  6,  6,  7,  7,  8,  8,
    9,  9,  10, 10, 11, 11, 12, 12, 13, 13,
};
pub const cl_order = [_]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

// ── Inflater ─────────────────────────────────────────────────────────
pub const Inflater = struct {
    window: *[32768]u8,
    win_pos: usize,
    out_buf: [*]u8,
    out_size: usize,
    out_pos: usize,
    out_ready: usize,
    // Fixed tables (lazily built)
    fixed_lit_table: HuffmanTable,
    fixed_dist_table: HuffmanTable,
    fixed_built: bool,
    // Dynamic tables for current block
    dyn_lit_table: HuffmanTable,
    dyn_dist_table: HuffmanTable,
    // Block state
    in_block: bool,
    bfinal: bool,
    btype: u2,
    stored_remaining: u16,
    lit_table_ptr: ?*const HuffmanTable,
    dist_table_ptr: ?*const HuffmanTable,
    done: bool,

    pub fn init(window: *[32768]u8, out_buf: []u8) Inflater {
        return .{
            .window = window,
            .win_pos = 0,
            .out_buf = out_buf.ptr,
            .out_size = out_buf.len,
            .out_pos = 0,
            .out_ready = 0,
            .fixed_lit_table = undefined,
            .fixed_dist_table = undefined,
            .fixed_built = false,
            .dyn_lit_table = undefined,
            .dyn_dist_table = undefined,
            .in_block = false,
            .bfinal = false,
            .btype = 0,
            .stored_remaining = 0,
            .lit_table_ptr = null,
            .dist_table_ptr = null,
            .done = false,
        };
    }

    fn buildFixedTables(self: *Inflater) void {
        if (self.fixed_built) return;
        var lit_lengths: [288]u8 = undefined;
        for (0..144) |i| lit_lengths[i] = 8;
        for (144..256) |i| lit_lengths[i] = 9;
        for (256..280) |i| lit_lengths[i] = 7;
        for (280..288) |i| lit_lengths[i] = 8;
        self.fixed_lit_table.build(&lit_lengths, 288);
        var dist_lengths: [32]u8 = undefined;
        for (&dist_lengths) |*d| d.* = 5;
        self.fixed_dist_table.build(&dist_lengths, 32);
        self.fixed_built = true;
    }

    fn writeByte(self: *Inflater, b: u8) void {
        self.window[self.win_pos] = b;
        self.win_pos = (self.win_pos + 1) & 0x7FFF;
        if (self.out_ready < self.out_size) {
            self.out_buf[self.out_ready] = b;
        }
        self.out_ready += 1;
    }

    fn copyFromWindow(self: *Inflater, dist: u16, length: u16) void {
        var src = (self.win_pos -% @as(usize, dist)) & 0x7FFF;
        for (0..length) |_| {
            const b = self.window[src];
            src = (src + 1) & 0x7FFF;
            self.writeByte(b);
        }
    }

    fn decodeDynamicTables(self: *Inflater, reader: *BitReader) bool {
        const hlit = (reader.readBits(5) orelse return false) + 257;
        const hdist = (reader.readBits(5) orelse return false) + 1;
        const hclen = (reader.readBits(4) orelse return false) + 4;

        var cl_lengths_arr: [19]u8 = .{0} ** 19;
        for (0..hclen) |i| {
            cl_lengths_arr[cl_order[i]] = @intCast(reader.readBits(3) orelse return false);
        }

        var cl_table: HuffmanTable = undefined;
        cl_table.build(&cl_lengths_arr, 19);

        var all_lengths: [288 + 32]u8 = .{0} ** (288 + 32);
        const total_codes = hlit + hdist;
        var i: u32 = 0;
        while (i < total_codes) {
            const sym = cl_table.decode(reader) orelse return false;
            if (sym < 16) {
                all_lengths[i] = @intCast(sym);
                i += 1;
            } else if (sym == 16) {
                const rep = (reader.readBits(2) orelse return false) + 3;
                if (i == 0) return false;
                const prev = all_lengths[i - 1];
                for (0..rep) |_| {
                    if (i >= total_codes) break;
                    all_lengths[i] = prev;
                    i += 1;
                }
            } else if (sym == 17) {
                const rep = (reader.readBits(3) orelse return false) + 3;
                for (0..rep) |_| {
                    if (i >= total_codes) break;
                    all_lengths[i] = 0;
                    i += 1;
                }
            } else if (sym == 18) {
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

        self.dyn_lit_table.build(all_lengths[0..hlit], hlit);
        self.dyn_dist_table.build(all_lengths[hlit .. hlit + hdist], hdist);
        return true;
    }

    /// Read up to `dest.len` decompressed bytes. Returns number of bytes
    /// written to `dest`, or 0 on EOF/error.
    pub fn readBytes(self: *Inflater, reader: *BitReader, dest: []u8) usize {
        if (self.done) return 0;

        // Deliver leftover bytes from previous call's overshoot
        if (self.out_ready > self.out_pos) {
            const avail = self.out_ready - self.out_pos;
            const n = @min(avail, dest.len);
            @memcpy(dest[0..n], self.out_buf[self.out_pos..][0..n]);
            self.out_pos += n;
            if (self.out_pos >= self.out_ready) {
                self.out_pos = 0;
                self.out_ready = 0;
            }
            return n;
        }

        self.out_pos = 0;
        self.out_ready = 0;

        while (self.out_ready < dest.len) {
            if (!self.in_block) {
                const bf = reader.readBits(1) orelse break;
                const bt = reader.readBits(2) orelse break;
                self.bfinal = bf == 1;
                self.btype = @intCast(bt);
                self.in_block = true;

                switch (self.btype) {
                    0 => {
                        reader.alignToByte();
                        const len_lo = reader.readBitsWide(16) orelse break;
                        _ = reader.readBitsWide(16) orelse break;
                        self.stored_remaining = @intCast(len_lo);
                    },
                    1 => {
                        self.buildFixedTables();
                        self.lit_table_ptr = &self.fixed_lit_table;
                        self.dist_table_ptr = &self.fixed_dist_table;
                    },
                    2 => {
                        if (!self.decodeDynamicTables(reader)) break;
                        self.lit_table_ptr = &self.dyn_lit_table;
                        self.dist_table_ptr = &self.dyn_dist_table;
                    },
                    else => break,
                }
            }

            if (self.btype == 0) {
                while (self.stored_remaining > 0 and self.out_ready < dest.len) {
                    const b = reader.readByte() orelse return self.finishRead(dest);
                    self.writeByte(b);
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
                const lt = self.lit_table_ptr orelse break;
                const dt = self.dist_table_ptr orelse break;
                while (self.out_ready < dest.len) {
                    const sym = lt.decode(reader) orelse return self.finishRead(dest);
                    if (sym < 256) {
                        self.writeByte(@intCast(sym));
                    } else if (sym == 256) {
                        self.in_block = false;
                        if (self.bfinal) self.done = true;
                        break;
                    } else {
                        const len_idx = sym - 257;
                        if (len_idx >= len_base.len) return self.finishRead(dest);
                        const el = len_extra[len_idx];
                        var length: u16 = len_base[len_idx];
                        if (el > 0) {
                            const extra = reader.readBitsWide(el) orelse return self.finishRead(dest);
                            length += @intCast(extra);
                        }
                        const dist_sym = dt.decode(reader) orelse return self.finishRead(dest);
                        if (dist_sym >= dist_base.len) return self.finishRead(dest);
                        const ed = dist_extra[dist_sym];
                        var distance: u16 = dist_base[dist_sym];
                        if (ed > 0) {
                            const extra = reader.readBitsWide(ed) orelse return self.finishRead(dest);
                            distance += @intCast(extra);
                        }
                        self.copyFromWindow(distance, length);
                    }
                }
            }
        }

        return self.finishRead(dest);
    }

    fn finishRead(self: *Inflater, dest: []u8) usize {
        const in_buf = @min(self.out_ready, self.out_size);
        const n = @min(in_buf, dest.len);
        if (n > 0) {
            @memcpy(dest[0..n], self.out_buf[0..n]);
        }
        const excess = self.out_ready - n;
        if (excess > 0) {
            // Replay excess bytes from window into out_buf for next call
            const to_save = @min(excess, self.out_size);
            var src = (self.win_pos -% excess) & 0x7FFF;
            for (0..to_save) |i| {
                self.out_buf[i] = self.window[src];
                src = (src + 1) & 0x7FFF;
            }
            self.out_pos = 0;
            self.out_ready = to_save;
        } else {
            self.out_pos = 0;
            self.out_ready = 0;
        }
        return n;
    }

    /// Convenience: decompress an entire stream, writing to a callback.
    /// Returns true on success.
    pub fn inflateAll(self: *Inflater, reader: *BitReader, writeFn: *const fn (data: []const u8) void) bool {
        while (!self.done) {
            var tmp: [4096]u8 = undefined;
            const n = self.readBytes(reader, &tmp);
            if (n == 0) break;
            writeFn(tmp[0..n]);
        }
        return self.done;
    }
};

// ── Gzip helpers ─────────────────────────────────────────────────────

pub fn skipGzipHeader(reader: *BitReader) bool {
    const magic1 = reader.readByte() orelse return false;
    const magic2 = reader.readByte() orelse return false;
    if (magic1 != 0x1f or magic2 != 0x8b) return false;
    const method = reader.readByte() orelse return false;
    if (method != 8) return false;
    const flags = reader.readByte() orelse return false;
    // Skip mtime(4), xfl(1), os(1)
    for (0..6) |_| _ = reader.readByte() orelse return false;

    if (flags & 0x04 != 0) { // FEXTRA
        const lo = reader.readByte() orelse return false;
        const hi = reader.readByte() orelse return false;
        const xlen = @as(u16, lo) | (@as(u16, hi) << 8);
        for (0..xlen) |_| _ = reader.readByte() orelse return false;
    }
    if (flags & 0x08 != 0) { // FNAME
        while (true) {
            const b = reader.readByte() orelse return false;
            if (b == 0) break;
        }
    }
    if (flags & 0x10 != 0) { // FCOMMENT
        while (true) {
            const b = reader.readByte() orelse return false;
            if (b == 0) break;
        }
    }
    if (flags & 0x02 != 0) { // FHCRC
        _ = reader.readByte() orelse return false;
        _ = reader.readByte() orelse return false;
    }
    return true;
}
