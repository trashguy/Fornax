/// partfs — partition info server.
///
/// Serves GPT partition information at /dev/ via IPC over fd 3 (server channel).
/// Block device accessed via fd 4 (raw, whole disk) using pread.
///
/// Protocol: handle-based, same as ramfs/fxfs.
///   T_OPEN(path)           → R_OK(handle) or R_ERROR
///   T_READ(handle, off, n) → R_OK(data) or R_ERROR
///   T_STAT(handle)         → R_OK(stat_data) or R_ERROR
///   T_CLOSE(handle)        → R_OK or R_ERROR
///
/// Namespace:
///   blk0     — whole disk info
///   blk0p1   — partition 1 info
///   blk0p2   — partition 2 info (etc.)
const fx = @import("fornax");

const BLOCK_SIZE = 4096;
const SERVER_FD = 3;
const BLK_FD = 4;
const MAX_HANDLES = 16;
const MAX_PARTITIONS = 8;

// GPT constants
const GPT_SIGNATURE = "EFI PART";
const GPT_ENTRY_SIZE = 128;

// ── Partition data ─────────────────────────────────────────────────

const PartInfo = struct {
    first_lba: u64,
    last_lba: u64,
    name: [36]u8,
    name_len: u8,
    valid: bool,
};

var disk_sectors: u64 = 0;
var parts: [MAX_PARTITIONS]PartInfo linksection(".bss") = undefined;
var part_count: u8 = 0;

// ── Handle table ───────────────────────────────────────────────────

const HandleKind = enum { disk, partition, directory };

const Handle = struct {
    kind: HandleKind,
    part_idx: u8, // which partition (for partition handles)
    active: bool,
};

var handles: [MAX_HANDLES]Handle linksection(".bss") = undefined;

fn allocHandle(kind: HandleKind, part_idx: u8) ?u32 {
    for (1..MAX_HANDLES) |i| {
        if (!handles[i].active) {
            handles[i] = .{ .kind = kind, .part_idx = part_idx, .active = true };
            return @intCast(i);
        }
    }
    return null;
}

fn freeHandle(handle: u32) void {
    if (handle > 0 and handle < MAX_HANDLES) {
        handles[handle].active = false;
    }
}

fn getHandle(handle: u32) ?*Handle {
    if (handle == 0 or handle >= MAX_HANDLES) return null;
    if (!handles[handle].active) return null;
    return &handles[handle];
}

// ── GPT parsing ────────────────────────────────────────────────────

var read_buf: [BLOCK_SIZE]u8 linksection(".bss") = undefined;
var entry_buf: [BLOCK_SIZE]u8 linksection(".bss") = undefined;

fn parseGpt() void {
    part_count = 0;

    // Read block 0: protective MBR + GPT header
    const n = fx.pread(BLK_FD, &read_buf, 0);
    if (n != BLOCK_SIZE) {
        _ = fx.write(1, "partfs: failed to read block 0\n");
        return;
    }

    // Check MBR signature
    if (read_buf[510] != 0x55 or read_buf[511] != 0xAA) return;

    // Check protective MBR type
    if (read_buf[450] != 0xEE) return;

    // GPT header at offset 512
    const hdr = read_buf[512..];
    if (!fx.str.eql(hdr[0..8], GPT_SIGNATURE)) return;

    // Parse disk size from header (backup LBA + 1)
    disk_sectors = readU64LE(hdr[32..40]) + 1;

    const partition_entry_lba = readU64LE(hdr[72..80]);
    const num_entries = readU32LE(hdr[80..84]);
    const entry_size = readU32LE(hdr[84..88]);

    if (entry_size < GPT_ENTRY_SIZE or entry_size > 512) return;

    // Read partition entries
    const entry_start_byte = partition_entry_lba * 512;
    const first_block = entry_start_byte / BLOCK_SIZE;
    const total_entry_bytes = @as(u64, num_entries) * entry_size;
    const last_block = (entry_start_byte + total_entry_bytes - 1) / BLOCK_SIZE;

    var block_nr = first_block;
    while (block_nr <= last_block and block_nr < 8) : (block_nr += 1) {
        const rn = fx.pread(BLK_FD, &entry_buf, block_nr * BLOCK_SIZE);
        if (rn != BLOCK_SIZE) break;

        const block_byte_start = block_nr * BLOCK_SIZE;
        var offset: usize = 0;

        while (offset + entry_size <= BLOCK_SIZE) : (offset += @intCast(entry_size)) {
            const abs_byte = block_byte_start + offset;
            if (abs_byte < entry_start_byte) continue;
            const entry_idx = (abs_byte - entry_start_byte) / entry_size;
            if (entry_idx >= num_entries) break;

            const entry = entry_buf[offset..][0..GPT_ENTRY_SIZE];

            // Check if type GUID is all zeros
            if (isZero(entry[0..16])) continue;

            if (part_count >= MAX_PARTITIONS) break;

            var p: PartInfo = undefined;
            p.first_lba = readU64LE(entry[32..40]);
            p.last_lba = readU64LE(entry[40..48]);
            p.valid = true;

            // Convert UTF-16LE name to ASCII
            p.name_len = 0;
            var ci: usize = 0;
            while (ci < 36) : (ci += 1) {
                const name_offset = 56 + ci * 2;
                if (name_offset + 1 >= GPT_ENTRY_SIZE) break;
                const lo = entry[name_offset];
                const hi = entry[name_offset + 1];
                if (lo == 0 and hi == 0) break;
                p.name[ci] = if (lo >= 0x20 and lo < 0x7F) lo else '?';
                p.name_len += 1;
            }
            while (ci < 36) : (ci += 1) {
                p.name[ci] = 0;
            }

            parts[part_count] = p;
            part_count += 1;
        }
    }
}

// ── Info text generation ───────────────────────────────────────────

var info_buf: [512]u8 linksection(".bss") = undefined;

fn formatDiskInfo() []const u8 {
    var pos: usize = 0;
    pos = appendStr(info_buf[0..], pos, "TYPE=disk\nSIZE=");
    pos = appendDec(info_buf[0..], pos, disk_sectors);
    pos = appendStr(info_buf[0..], pos, "\nBLOCKS=");
    pos = appendDec(info_buf[0..], pos, disk_sectors / 8); // 4096-byte blocks
    pos = appendStr(info_buf[0..], pos, "\n");
    return info_buf[0..pos];
}

fn formatPartInfo(idx: u8) []const u8 {
    if (idx >= part_count) return "";
    const p = &parts[idx];

    var pos: usize = 0;
    pos = appendStr(info_buf[0..], pos, "TYPE=part\nSTART=");
    pos = appendDec(info_buf[0..], pos, p.first_lba);
    pos = appendStr(info_buf[0..], pos, "\nEND=");
    pos = appendDec(info_buf[0..], pos, p.last_lba);
    pos = appendStr(info_buf[0..], pos, "\nSIZE=");
    pos = appendDec(info_buf[0..], pos, p.last_lba - p.first_lba + 1);
    pos = appendStr(info_buf[0..], pos, "\nNAME=");
    pos = appendStr(info_buf[0..], pos, p.name[0..p.name_len]);
    pos = appendStr(info_buf[0..], pos, "\n");
    return info_buf[0..pos];
}

// ── IPC handlers ───────────────────────────────────────────────────

var msg: fx.IpcMessage linksection(".bss") = undefined;
var reply: fx.IpcMessage linksection(".bss") = undefined;

fn handleOpen(req: *fx.IpcMessage, resp: *fx.IpcMessage) void {
    const path: []const u8 = req.data[0..req.data_len];

    // Strip leading slash
    var name: []const u8 = path;
    if (name.len > 0 and name[0] == '/') name = name[1..];

    // Directory listing (empty path)
    if (name.len == 0) {
        const handle = allocHandle(.directory, 0) orelse {
            resp.* = fx.IpcMessage.init(fx.R_ERROR);
            return;
        };
        resp.* = fx.IpcMessage.init(fx.R_OK);
        writeU32LE(resp.data[0..4], handle);
        resp.data_len = 4;
        return;
    }

    // "blk0" — whole disk
    if (fx.str.eql(name, "blk0")) {
        const handle = allocHandle(.disk, 0) orelse {
            resp.* = fx.IpcMessage.init(fx.R_ERROR);
            return;
        };
        resp.* = fx.IpcMessage.init(fx.R_OK);
        writeU32LE(resp.data[0..4], handle);
        resp.data_len = 4;
        return;
    }

    // "blk0pN" — partition N
    if (fx.str.startsWith(name, "blk0p")) {
        const idx_str = name[5..];
        if (fx.str.parseUint(idx_str)) |idx| {
            if (idx >= 1 and idx <= part_count) {
                const handle = allocHandle(.partition, @intCast(idx - 1)) orelse {
                    resp.* = fx.IpcMessage.init(fx.R_ERROR);
                    return;
                };
                resp.* = fx.IpcMessage.init(fx.R_OK);
                writeU32LE(resp.data[0..4], handle);
                resp.data_len = 4;
                return;
            }
        }
    }

    resp.* = fx.IpcMessage.init(fx.R_ERROR);
}

fn handleRead(req: *fx.IpcMessage, resp: *fx.IpcMessage) void {
    if (req.data_len < 12) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }

    const handle_id = readU32LE(req.data[0..4]);
    const offset = readU32LE(req.data[4..8]);
    const count = readU32LE(req.data[8..12]);

    const h = getHandle(handle_id) orelse {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    resp.* = fx.IpcMessage.init(fx.R_OK);

    switch (h.kind) {
        .directory => {
            // Return directory entries
            const entry_size = @sizeOf(fx.DirEntry);
            const skip = offset / entry_size;
            var written: u32 = 0;
            var entries_written: u32 = 0;
            const max_entries: u32 = @intCast(@min(count / entry_size, 4096 / entry_size));

            // Entry 0: blk0
            if (skip == 0 and entries_written < max_entries) {
                const dest: *fx.DirEntry = @ptrCast(@alignCast(resp.data[written..][0..entry_size]));
                @memset(&dest.name, 0);
                @memcpy(dest.name[0..4], "blk0");
                dest.file_type = 0;
                dest.size = 0;
                written += entry_size;
                entries_written += 1;
            }

            // Entries 1..N: blk0pN
            var pi: u32 = 0;
            while (pi < part_count and entries_written < max_entries) : (pi += 1) {
                const entry_idx = pi + 1;
                if (entry_idx < skip) continue;

                if (written + entry_size > 4096) break;

                const dest: *fx.DirEntry = @ptrCast(@alignCast(resp.data[written..][0..entry_size]));
                @memset(&dest.name, 0);
                // "blk0p1", "blk0p2", etc.
                @memcpy(dest.name[0..5], "blk0p");
                dest.name[5] = '1' + @as(u8, @intCast(pi));
                dest.file_type = 0;
                dest.size = 0;
                written += entry_size;
                entries_written += 1;
            }

            resp.data_len = written;
        },
        .disk => {
            const text = formatDiskInfo();
            if (offset >= text.len) {
                resp.data_len = 0;
                return;
            }
            const remaining = text.len - offset;
            const to_copy: u32 = @intCast(@min(remaining, @min(count, 4096)));
            @memcpy(resp.data[0..to_copy], text[offset..][0..to_copy]);
            resp.data_len = to_copy;
        },
        .partition => {
            const text = formatPartInfo(h.part_idx);
            if (offset >= text.len) {
                resp.data_len = 0;
                return;
            }
            const remaining = text.len - offset;
            const to_copy: u32 = @intCast(@min(remaining, @min(count, 4096)));
            @memcpy(resp.data[0..to_copy], text[offset..][0..to_copy]);
            resp.data_len = to_copy;
        },
    }
}

fn handleStat(req: *fx.IpcMessage, resp: *fx.IpcMessage) void {
    if (req.data_len < 4) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }

    const handle_id = readU32LE(req.data[0..4]);
    const h = getHandle(handle_id) orelse {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    resp.* = fx.IpcMessage.init(fx.R_OK);
    @memset(resp.data[0..64], 0);

    switch (h.kind) {
        .directory => {
            writeU32LE(resp.data[0..4], 0);
            writeU32LE(resp.data[4..8], 1); // directory
        },
        .disk => {
            const text = formatDiskInfo();
            writeU32LE(resp.data[0..4], @intCast(text.len));
            writeU32LE(resp.data[4..8], 0); // file
        },
        .partition => {
            const text = formatPartInfo(h.part_idx);
            writeU32LE(resp.data[0..4], @intCast(text.len));
            writeU32LE(resp.data[4..8], 0); // file
        },
    }
    resp.data_len = 64;
}

fn handleClose(req: *fx.IpcMessage, resp: *fx.IpcMessage) void {
    if (req.data_len < 4) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }
    const handle_id = readU32LE(req.data[0..4]);
    freeHandle(handle_id);
    resp.* = fx.IpcMessage.init(fx.R_OK);
    resp.data_len = 0;
}

// ── Byte helpers ───────────────────────────────────────────────────

fn readU32LE(buf: *const [4]u8) u32 {
    return @as(u32, buf[0]) |
        (@as(u32, buf[1]) << 8) |
        (@as(u32, buf[2]) << 16) |
        (@as(u32, buf[3]) << 24);
}

fn readU64LE(buf: *const [8]u8) u64 {
    return @as(u64, buf[0]) |
        (@as(u64, buf[1]) << 8) |
        (@as(u64, buf[2]) << 16) |
        (@as(u64, buf[3]) << 24) |
        (@as(u64, buf[4]) << 32) |
        (@as(u64, buf[5]) << 40) |
        (@as(u64, buf[6]) << 48) |
        (@as(u64, buf[7]) << 56);
}

fn writeU32LE(buf: *[4]u8, val: u32) void {
    buf[0] = @truncate(val);
    buf[1] = @truncate(val >> 8);
    buf[2] = @truncate(val >> 16);
    buf[3] = @truncate(val >> 24);
}

fn isZero(buf: []const u8) bool {
    for (buf) |b| {
        if (b != 0) return false;
    }
    return true;
}

fn appendStr(buf: []u8, pos: usize, s: []const u8) usize {
    if (pos + s.len > buf.len) return pos;
    @memcpy(buf[pos..][0..s.len], s);
    return pos + s.len;
}

fn appendDec(buf: []u8, pos: usize, val: u64) usize {
    if (val == 0) {
        if (pos < buf.len) {
            buf[pos] = '0';
            return pos + 1;
        }
        return pos;
    }
    var tmp: [20]u8 = undefined;
    var len: usize = 0;
    var v = val;
    while (v > 0) : (v /= 10) {
        tmp[len] = '0' + @as(u8, @intCast(v % 10));
        len += 1;
    }
    if (pos + len > buf.len) return pos;
    // Reverse
    var i: usize = 0;
    while (i < len) : (i += 1) {
        buf[pos + i] = tmp[len - 1 - i];
    }
    return pos + len;
}

// ── Entry point ────────────────────────────────────────────────────

export fn _start() noreturn {
    _ = fx.write(1, "partfs: starting\n");

    // Initialize handles
    for (0..MAX_HANDLES) |i| {
        handles[i] = .{ .kind = .disk, .part_idx = 0, .active = false };
    }

    // Initialize partition info
    for (0..MAX_PARTITIONS) |i| {
        parts[i] = .{
            .first_lba = 0,
            .last_lba = 0,
            .name = [_]u8{0} ** 36,
            .name_len = 0,
            .valid = false,
        };
    }

    // Parse GPT from block device
    parseGpt();

    _ = fx.write(1, "partfs: ready\n");

    // Server loop
    while (true) {
        const rc = fx.ipc_recv(SERVER_FD, &msg);
        if (rc < 0) {
            _ = fx.write(2, "partfs: ipc_recv error\n");
            continue;
        }

        switch (msg.tag) {
            fx.T_OPEN => handleOpen(&msg, &reply),
            fx.T_READ => handleRead(&msg, &reply),
            fx.T_STAT => handleStat(&msg, &reply),
            fx.T_CLOSE => handleClose(&msg, &reply),
            else => {
                reply = fx.IpcMessage.init(fx.R_ERROR);
            },
        }

        _ = fx.ipc_reply(SERVER_FD, &reply);
    }
}
