const fx = @import("fornax");

const out = fx.io.Writer.stdout;
const err = fx.io.Writer.stderr;

const deflate = fx.deflate;

// ── BSS Buffers ──────────────────────────────────────────────────────
var sliding_window: [32768]u8 linksection(".bss") = undefined;
var input_buf: [8192]u8 linksection(".bss") = undefined;
var out_buf: [8192]u8 linksection(".bss") = undefined;
var filename_buf: [512]u8 linksection(".bss") = undefined;
var path_buf: [512]u8 linksection(".bss") = undefined;
var crc_table_storage: fx.crc32.Crc32 linksection(".bss") = undefined;

// ── BitReader adapter: pread-backed with remaining tracking ──────────
const PreadCtx = struct {
    zip_fd: i32,
    file_offset: u64,
    bytes_remaining: u64,
};

var pread_ctx: PreadCtx = .{ .zip_fd = -1, .file_offset = 0, .bytes_remaining = 0 };

fn preadReadFn(ctx_ptr: *anyopaque, buf: []u8) isize {
    const ctx: *PreadCtx = @ptrCast(@alignCast(ctx_ptr));
    if (ctx.bytes_remaining == 0) return 0;
    const to_read: usize = @intCast(@min(ctx.bytes_remaining, buf.len));
    const n = fx.pread(ctx.zip_fd, buf[0..to_read], ctx.file_offset);
    if (n <= 0) return n;
    const nbytes: u64 = @intCast(n);
    ctx.file_offset += nbytes;
    ctx.bytes_remaining -= nbytes;
    return n;
}

// ── Output writer with buffering + CRC ───────────────────────────────
const OutputWriter = struct {
    fd: i32,
    pos: usize,
    crc: u32,
    total: u64,

    fn init(fd: i32) OutputWriter {
        return .{ .fd = fd, .pos = 0, .crc = 0, .total = 0 };
    }

    fn writeData(self: *OutputWriter, data: []const u8) void {
        for (data) |b| {
            out_buf[self.pos] = b;
            self.pos += 1;
            if (self.pos >= out_buf.len) {
                self.flushBuf();
            }
        }
    }

    fn flushBuf(self: *OutputWriter) void {
        if (self.pos > 0) {
            self.crc = crc_table_storage.update(self.crc, out_buf[0..self.pos]);
            self.total += self.pos;
            _ = fx.syscall.write(self.fd, out_buf[0..self.pos]);
            self.pos = 0;
        }
    }
};

// ── Path safety ──────────────────────────────────────────────────────
fn isSafePath(name: []const u8) bool {
    return fx.tar.isSafePath(name);
}

fn ensureParentDirs(name: []const u8) void {
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        if (name[i] == '/' and i > 0) {
            if (i < path_buf.len) {
                @memcpy(path_buf[0..i], name[0..i]);
                _ = fx.mkdir(path_buf[0..i]);
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
        crc = crc_table_storage.update(crc, input_buf[0..nbytes]);
        _ = fx.syscall.write(out_fd, input_buf[0..nbytes]);
        offset += nbytes;
        remaining -= nbytes;
    }
    return crc;
}

// ── ZIP reading helpers ──────────────────────────────────────────────
fn readU16(buf: []const u8) u16 {
    return @as(u16, buf[0]) | (@as(u16, buf[1]) << 8);
}

fn readU32(buf: []const u8) u32 {
    return @as(u32, buf[0]) | (@as(u32, buf[1]) << 8) | (@as(u32, buf[2]) << 16) | (@as(u32, buf[3]) << 24);
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
    crc_table_storage.init();

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
        const hn = fx.pread(zip_fd, &header, offset);
        if (hn < 30) break;

        const sig = readU32(header[0..4]);

        if (sig == 0x02014b50 or sig == 0x06054b50) break;

        if (sig != 0x04034b50) {
            err.puts("unzip: bad header, stopping\n");
            break;
        }

        const method = readU16(header[8..10]);
        const crc_expected = readU32(header[14..18]);
        const comp_size = readU32(header[18..22]);
        _ = readU32(header[22..26]); // uncomp_size
        const name_len = readU16(header[26..28]);
        const extra_len = readU16(header[28..30]);

        offset += 30;

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
        offset += comp_size;

        if (!isSafePath(name)) {
            err.print("  skipping: {s} (unsafe path)\n", .{name});
            file_count += 1;
            continue;
        }

        if (fn_len > 0 and name[fn_len - 1] == '/') {
            out.print("  creating: {s}\n", .{name});
            ensureParentDirs(name);
            _ = fx.mkdir(name[0 .. fn_len - 1]);
            file_count += 1;
            continue;
        }

        ensureParentDirs(name);
        const out_fd = fx.create(name, 0);
        if (out_fd < 0) {
            err.print("  error: cannot create {s}\n", .{name});
            file_count += 1;
            continue;
        }

        if (method == 0) {
            out.print("extracting: {s}\n", .{name});
            const uncomp_size = readU32(header[22..26]);
            const crc_actual = extractStored(zip_fd, data_offset, uncomp_size, out_fd);
            if (crc_expected != 0 and crc_actual != crc_expected) {
                err.print("  warning: CRC mismatch for {s}\n", .{name});
            }
        } else if (method == 8) {
            out.print(" inflating: {s}\n", .{name});
            pread_ctx = .{ .zip_fd = zip_fd, .file_offset = data_offset, .bytes_remaining = comp_size };
            var bit_reader = deflate.BitReader.init(&preadReadFn, @ptrCast(&pread_ctx), &input_buf);
            var inflater = deflate.Inflater.init(&sliding_window, &out_buf);
            var writer = OutputWriter.init(out_fd);

            var ok = true;
            while (!inflater.done) {
                var tmp: [4096]u8 = undefined;
                const n = inflater.readBytes(&bit_reader, &tmp);
                if (n == 0) break;
                writer.writeData(tmp[0..n]);
            }
            writer.flushBuf();
            if (!inflater.done) {
                ok = false;
            }
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
