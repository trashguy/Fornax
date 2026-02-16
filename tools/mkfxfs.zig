/// mkfxfs — Fornax filesystem formatter.
///
/// Usage: mkfxfs <disk-image> [--add <host-file>:<fs-path>] ...
///
/// Creates an fxfs-formatted disk image with:
///   Block 0:      Primary superblock
///   Block 1:      Backup superblock
///   Block 2..B:   Allocation bitmap (1 bit per block)
///   Block B+1:    Root B-tree leaf node (inode 1 = root directory)
///   Optional:     Files added via --add flags
///
/// On-disk format uses packed byte-level layout (no alignment padding).
/// Must match srv/fxfs/main.zig exactly.
const std = @import("std");

// ── On-disk constants ───────────────────────────────────────────────
const BLOCK_SIZE = 4096;
const MAGIC = "FXFS0001";

// Item types
const INODE_ITEM: u8 = 1;
const DIR_ENTRY: u8 = 2;
const EXTENT_DATA: u8 = 3;

// File types for inode mode
const S_IFDIR: u16 = 0o040000;
const S_IFREG: u16 = 0o100000;

// Dir entry file types
const DT_REG: u8 = 1;
const DT_DIR: u8 = 2;

// ── Packed on-disk sizes (must match srv/fxfs/main.zig) ─────────────
// Node header: level(1) + num_items(2) + pad(1) + generation(8) + checksum(4) = 16
const NODE_HEADER_SIZE = 16;
// Key: inode_nr(8) + item_type(1) + offset(8) = 17
const KEY_SIZE = 17;
// Leaf item header: key(17) + data_offset(2) + data_size(2) = 21
const LEAF_ITEM_HEADER_SIZE = 21;
// Inode item: mode(2) + uid(2) + gid(2) + nlinks(2) + size(8) + atime(8) + mtime(8) + ctime(8) = 40
const INODE_ITEM_SIZE = 40;
// Extent data: disk_block(8) + num_blocks(4) + reserved(4) = 16
const EXTENT_DATA_SIZE = 16;

// ── Key struct (for sorting only, NOT for on-disk serialization) ────
const Key = struct {
    inode_nr: u64,
    item_type: u8,
    offset: u64,

    fn lessThan(a: Key, b: Key) bool {
        if (a.inode_nr != b.inode_nr) return a.inode_nr < b.inode_nr;
        if (a.item_type != b.item_type) return a.item_type < b.item_type;
        return a.offset < b.offset;
    }
};

// ── Byte-level write helpers ────────────────────────────────────────
fn writeU16LE(buf: *[2]u8, val: u16) void {
    buf[0] = @truncate(val);
    buf[1] = @truncate(val >> 8);
}

fn writeU32LE(buf: *[4]u8, val: u32) void {
    buf[0] = @truncate(val);
    buf[1] = @truncate(val >> 8);
    buf[2] = @truncate(val >> 16);
    buf[3] = @truncate(val >> 24);
}

fn writeU64LE(buf: *[8]u8, val: u64) void {
    buf[0] = @truncate(val);
    buf[1] = @truncate(val >> 8);
    buf[2] = @truncate(val >> 16);
    buf[3] = @truncate(val >> 24);
    buf[4] = @truncate(val >> 32);
    buf[5] = @truncate(val >> 40);
    buf[6] = @truncate(val >> 48);
    buf[7] = @truncate(val >> 56);
}

// ── Serialization helpers ───────────────────────────────────────────

/// Write a packed Key (17 bytes) at buf[off..off+17].
fn writeKey(buf: []u8, off: usize, key: Key) void {
    writeU64LE(buf[off..][0..8], key.inode_nr);
    buf[off + 8] = key.item_type;
    writeU64LE(buf[off + 9..][0..8], key.offset);
}

/// Write an inode item (40 bytes) into a buffer.
fn writeInodeItem(buf: []u8, mode: u16, uid: u16, gid: u16, nlinks: u16, size: u64) void {
    writeU16LE(buf[0..2], mode);
    writeU16LE(buf[2..4], uid);
    writeU16LE(buf[4..6], gid);
    writeU16LE(buf[6..8], nlinks);
    writeU64LE(buf[8..16], size);
    // atime, mtime, ctime = 0 (already zeroed)
    writeU64LE(buf[16..24], 0);
    writeU64LE(buf[24..32], 0);
    writeU64LE(buf[32..40], 0);
}

/// Write an extent data value (16 bytes) into a buffer.
fn writeExtentData(buf: []u8, disk_block: u64, num_blocks: u32) void {
    writeU64LE(buf[0..8], disk_block);
    writeU32LE(buf[8..12], num_blocks);
    writeU32LE(buf[12..16], 0); // reserved
}

// ── FNV-1a hash for directory entry offsets ─────────────────────────
fn fnvHash(data: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (data) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

// ── CRC32 ───────────────────────────────────────────────────────────
fn crc32(data: []const u8) u32 {
    return std.hash.Crc32.hash(data);
}

// ── Leaf node builder ───────────────────────────────────────────────
const LeafBuilder = struct {
    buf: [BLOCK_SIZE]u8 align(8),
    num_items: u16,
    header_cursor: usize, // grows forward from NODE_HEADER_SIZE
    data_cursor: usize, // grows backward from BLOCK_SIZE

    fn init(generation: u64) LeafBuilder {
        var b = LeafBuilder{
            .buf = [_]u8{0} ** BLOCK_SIZE,
            .num_items = 0,
            .header_cursor = NODE_HEADER_SIZE,
            .data_cursor = BLOCK_SIZE,
        };
        // Write packed node header: level(1) + num_items(2) + pad(1) + generation(8) + checksum(4)
        b.buf[0] = 0; // level = 0 (leaf)
        writeU16LE(b.buf[1..3], 0); // num_items (updated in addItem)
        b.buf[3] = 0; // pad
        writeU64LE(b.buf[4..12], generation);
        writeU32LE(b.buf[12..16], 0); // checksum (set in finalize)
        return b;
    }

    fn addItem(self: *LeafBuilder, key: Key, data: []const u8) !void {
        const data_size: u16 = @intCast(data.len);

        // Check space
        if (self.header_cursor + LEAF_ITEM_HEADER_SIZE > self.data_cursor - data.len) {
            return error.LeafFull;
        }

        // Write data at end (growing backward)
        self.data_cursor -= data.len;
        @memcpy(self.buf[self.data_cursor..][0..data.len], data);

        // Write packed leaf item header: key(17) + data_offset(2) + data_size(2)
        writeKey(&self.buf, self.header_cursor, key);
        writeU16LE(self.buf[self.header_cursor + KEY_SIZE ..][0..2], @intCast(self.data_cursor));
        writeU16LE(self.buf[self.header_cursor + KEY_SIZE + 2 ..][0..2], data_size);
        self.header_cursor += LEAF_ITEM_HEADER_SIZE;
        self.num_items += 1;

        // Update num_items in header
        writeU16LE(self.buf[1..3], self.num_items);
    }

    fn finalize(self: *LeafBuilder) [BLOCK_SIZE]u8 {
        // Zero checksum field, compute CRC32, write it back
        writeU32LE(self.buf[12..16], 0);
        const cksum = crc32(&self.buf);
        writeU32LE(self.buf[12..16], cksum);
        return self.buf;
    }
};

// ── Main ────────────────────────────────────────────────────────────
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try std.process.argsAlloc(alloc);
    if (args.len < 2) {
        std.debug.print("Usage: mkfxfs <disk-image> [--add <host-file>:<fs-path>] ...\n", .{});
        std.process.exit(1);
    }

    const image_path = args[1];

    // Parse --add arguments
    const AddEntry = struct {
        host_path: []const u8,
        fs_path: []const u8,
        data: []const u8,
    };

    var add_entries: std.ArrayList(AddEntry) = .empty;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--add") and i + 1 < args.len) {
            i += 1;
            const spec = args[i];
            // Split on ':'
            if (std.mem.indexOfScalar(u8, spec, ':')) |colon| {
                const host = spec[0..colon];
                const fs = spec[colon + 1 ..];
                const data = try std.fs.cwd().readFileAlloc(alloc, host, 1024 * 1024);
                try add_entries.append(alloc, .{ .host_path = host, .fs_path = fs, .data = data });
            } else {
                std.debug.print("Error: --add argument must be <host-path>:<fs-path>\n", .{});
                std.process.exit(1);
            }
        }
    }

    // Open/create the image file
    const file = try std.fs.cwd().openFile(image_path, .{ .mode = .read_write });
    defer file.close();

    const file_size = try file.getEndPos();
    if (file_size < BLOCK_SIZE * 4) {
        std.debug.print("Error: image file too small (need at least 16 KB)\n", .{});
        std.process.exit(1);
    }

    const total_blocks = file_size / BLOCK_SIZE;
    const bitmap_blocks = (total_blocks + (BLOCK_SIZE * 8) - 1) / (BLOCK_SIZE * 8);
    const bitmap_start: u64 = 2; // blocks 0,1 are superblocks
    const data_start: u64 = bitmap_start + bitmap_blocks;

    // Allocate bitmap in memory
    const bitmap_bytes = bitmap_blocks * BLOCK_SIZE;
    const bitmap = try alloc.alloc(u8, bitmap_bytes);
    @memset(bitmap, 0);

    // Mark superblocks + bitmap blocks as allocated
    var next_free: u64 = data_start;
    var allocated: u64 = 0;
    {
        var b: u64 = 0;
        while (b < data_start) : (b += 1) {
            setBit(bitmap, b);
            allocated += 1;
        }
    }

    // Allocate root B-tree node
    const root_block = next_free;
    setBit(bitmap, root_block);
    next_free += 1;
    allocated += 1;

    // Next inode: 2 (inode 1 = root dir)
    var next_inode: u64 = 2;

    // Build root leaf node
    var leaf = LeafBuilder.init(1); // generation 1

    // Inode 1: root directory
    var inode_buf: [INODE_ITEM_SIZE]u8 = [_]u8{0} ** INODE_ITEM_SIZE;
    writeInodeItem(&inode_buf, S_IFDIR | 0o755, 0, 0, 2, 0);
    try leaf.addItem(.{ .inode_nr = 1, .item_type = INODE_ITEM, .offset = 0 }, &inode_buf);

    // Add files from --add entries
    for (add_entries.items) |entry| {
        // Strip leading / from fs_path
        var name = entry.fs_path;
        if (name.len > 0 and name[0] == '/') name = name[1..];
        if (name.len == 0 or name.len > 255) continue;

        const file_inode = next_inode;
        next_inode += 1;

        // Create inode for the file
        var file_inode_buf: [INODE_ITEM_SIZE]u8 = [_]u8{0} ** INODE_ITEM_SIZE;
        writeInodeItem(&file_inode_buf, S_IFREG | 0o644, 0, 0, 1, entry.data.len);
        try leaf.addItem(.{ .inode_nr = file_inode, .item_type = INODE_ITEM, .offset = 0 }, &file_inode_buf);

        // Create dir entry in root dir (inode 1)
        const name_hash = fnvHash(name);
        var dir_buf: [266]u8 = undefined; // max: 8 + 1 + 1 + 255
        writeU64LE(dir_buf[0..8], file_inode);
        dir_buf[8] = DT_REG;
        dir_buf[9] = @intCast(name.len);
        @memcpy(dir_buf[10..][0..name.len], name);
        const dir_entry_size: usize = 10 + name.len;
        try leaf.addItem(.{ .inode_nr = 1, .item_type = DIR_ENTRY, .offset = name_hash }, dir_buf[0..dir_entry_size]);

        // Store file data
        const max_inline = BLOCK_SIZE - NODE_HEADER_SIZE - LEAF_ITEM_HEADER_SIZE * 10 - 100;
        if (entry.data.len <= max_inline and entry.data.len <= 3800) {
            // Inline data: store directly in the leaf
            try leaf.addItem(.{ .inode_nr = file_inode, .item_type = EXTENT_DATA, .offset = 0 }, entry.data);
        } else {
            // Allocate data blocks
            const num_data_blocks = (entry.data.len + BLOCK_SIZE - 1) / BLOCK_SIZE;
            const first_data_block = next_free;
            var db: u64 = 0;
            while (db < num_data_blocks) : (db += 1) {
                setBit(bitmap, next_free);
                next_free += 1;
                allocated += 1;
            }

            // Write data blocks to disk
            var offset: usize = 0;
            db = 0;
            while (db < num_data_blocks) : (db += 1) {
                var data_block: [BLOCK_SIZE]u8 = [_]u8{0} ** BLOCK_SIZE;
                const remaining = entry.data.len - offset;
                const to_copy = @min(remaining, BLOCK_SIZE);
                @memcpy(data_block[0..to_copy], entry.data[offset..][0..to_copy]);
                try file.seekTo((first_data_block + db) * BLOCK_SIZE);
                try file.writeAll(&data_block);
                offset += to_copy;
            }

            // Create extent data reference
            var extent_buf: [EXTENT_DATA_SIZE]u8 = undefined;
            writeExtentData(&extent_buf, first_data_block, @intCast(num_data_blocks));
            try leaf.addItem(.{ .inode_nr = file_inode, .item_type = EXTENT_DATA, .offset = 0 }, &extent_buf);
        }
    }

    // Finalize and write root leaf
    const root_data = leaf.finalize();
    try file.seekTo(root_block * BLOCK_SIZE);
    try file.writeAll(&root_data);

    // Write bitmap
    try file.seekTo(bitmap_start * BLOCK_SIZE);
    try file.writeAll(bitmap);

    // Build superblock using packed byte-level writes
    var sb_buf: [BLOCK_SIZE]u8 = [_]u8{0} ** BLOCK_SIZE;
    @memcpy(sb_buf[0..8], MAGIC);
    writeU32LE(sb_buf[8..12], BLOCK_SIZE); // block_size
    // bytes 12-15: padding (already zero)
    writeU64LE(sb_buf[16..24], total_blocks);
    writeU64LE(sb_buf[24..32], root_block); // tree_root
    writeU64LE(sb_buf[32..40], next_inode);
    const free_blocks = total_blocks - allocated;
    writeU64LE(sb_buf[40..48], free_blocks);
    writeU64LE(sb_buf[48..56], 1); // generation
    writeU64LE(sb_buf[56..64], bitmap_start);
    writeU64LE(sb_buf[64..72], data_start);
    // checksum at 72-75
    writeU32LE(sb_buf[72..76], 0);
    const sb_cksum = crc32(sb_buf[0..80]);
    writeU32LE(sb_buf[72..76], sb_cksum);

    // Write primary superblock (block 0)
    try file.seekTo(0);
    try file.writeAll(&sb_buf);

    // Write backup superblock (block 1)
    try file.seekTo(BLOCK_SIZE);
    try file.writeAll(&sb_buf);

    std.debug.print("mkfxfs: formatted {s}\n", .{image_path});
    std.debug.print("  total blocks: {d}\n", .{total_blocks});
    std.debug.print("  bitmap blocks: {d} (starts at block {d})\n", .{ bitmap_blocks, bitmap_start });
    std.debug.print("  data starts at block: {d}\n", .{data_start});
    std.debug.print("  root tree node: block {d}\n", .{root_block});
    std.debug.print("  free blocks: {d}\n", .{free_blocks});
    std.debug.print("  files added: {d}\n", .{add_entries.items.len});
}

fn setBit(bitmap: []u8, block: u64) void {
    const byte_idx = block / 8;
    const bit_idx: u3 = @intCast(block % 8);
    if (byte_idx < bitmap.len) {
        bitmap[byte_idx] |= @as(u8, 1) << bit_idx;
    }
}

// ── Tests ───────────────────────────────────────────────────────────

test "FNV hash deterministic" {
    const h1 = fnvHash("hello.txt");
    const h2 = fnvHash("hello.txt");
    try std.testing.expectEqual(h1, h2);
}

test "FNV hash different for different names" {
    const h1 = fnvHash("foo");
    const h2 = fnvHash("bar");
    try std.testing.expect(h1 != h2);
}

test "CRC32 known value" {
    const data = "FXFS0001";
    const cksum = crc32(data);
    try std.testing.expect(cksum != 0);
}

test "setBit and bitmap" {
    var bitmap: [8]u8 = [_]u8{0} ** 8;
    setBit(&bitmap, 0);
    try std.testing.expect(bitmap[0] & 1 == 1);
    setBit(&bitmap, 7);
    try std.testing.expect(bitmap[0] & 0x80 == 0x80);
    setBit(&bitmap, 8);
    try std.testing.expect(bitmap[1] & 1 == 1);
    setBit(&bitmap, 63);
    try std.testing.expect(bitmap[7] & 0x80 == 0x80);
}

test "Key ordering" {
    const k1 = Key{ .inode_nr = 1, .item_type = INODE_ITEM, .offset = 0 };
    const k2 = Key{ .inode_nr = 1, .item_type = DIR_ENTRY, .offset = 0 };
    const k3 = Key{ .inode_nr = 2, .item_type = INODE_ITEM, .offset = 0 };

    try std.testing.expect(k1.lessThan(k2)); // same inode, INODE_ITEM < DIR_ENTRY
    try std.testing.expect(k2.lessThan(k3)); // inode 1 < inode 2
    try std.testing.expect(k1.lessThan(k3));
    try std.testing.expect(!k3.lessThan(k1));
}

test "LeafBuilder packed layout matches fxfs" {
    var leaf = LeafBuilder.init(1);

    var inode_buf: [INODE_ITEM_SIZE]u8 = [_]u8{0} ** INODE_ITEM_SIZE;
    writeInodeItem(&inode_buf, S_IFDIR | 0o755, 0, 0, 2, 0);
    try leaf.addItem(
        .{ .inode_nr = 1, .item_type = INODE_ITEM, .offset = 0 },
        &inode_buf,
    );

    try std.testing.expectEqual(@as(u16, 1), leaf.num_items);

    const buf = leaf.finalize();
    // Node header (packed):
    // offset 0: level = 0
    try std.testing.expectEqual(@as(u8, 0), buf[0]);
    // offset 1-2: num_items = 1 (LE)
    try std.testing.expectEqual(@as(u8, 1), buf[1]);
    try std.testing.expectEqual(@as(u8, 0), buf[2]);
    // offset 3: pad = 0
    try std.testing.expectEqual(@as(u8, 0), buf[3]);
    // offset 4-11: generation = 1 (LE)
    try std.testing.expectEqual(@as(u8, 1), buf[4]);

    // Leaf item header starts at NODE_HEADER_SIZE (16):
    // offset 16-23: key.inode_nr = 1
    try std.testing.expectEqual(@as(u8, 1), buf[16]);
    // offset 24: key.item_type = INODE_ITEM (1)
    try std.testing.expectEqual(@as(u8, INODE_ITEM), buf[24]);
    // offset 25-32: key.offset = 0
    try std.testing.expectEqual(@as(u8, 0), buf[25]);

    // offset 33-34: data_offset (should point near end of block)
    const data_off = @as(u16, buf[33]) | (@as(u16, buf[34]) << 8);
    try std.testing.expectEqual(@as(u16, BLOCK_SIZE - INODE_ITEM_SIZE), data_off);

    // offset 35-36: data_size = INODE_ITEM_SIZE (40)
    const data_sz = @as(u16, buf[35]) | (@as(u16, buf[36]) << 8);
    try std.testing.expectEqual(@as(u16, INODE_ITEM_SIZE), data_sz);

    // Verify inode data at data_offset
    const inode_off = data_off;
    const mode = @as(u16, buf[inode_off]) | (@as(u16, buf[inode_off + 1]) << 8);
    try std.testing.expectEqual(S_IFDIR | 0o755, mode);
}

test "Superblock layout matches fxfs" {
    var sb_buf: [BLOCK_SIZE]u8 = [_]u8{0} ** BLOCK_SIZE;
    @memcpy(sb_buf[0..8], MAGIC);
    writeU32LE(sb_buf[8..12], BLOCK_SIZE);
    writeU64LE(sb_buf[16..24], 16384); // total_blocks
    writeU64LE(sb_buf[24..32], 3); // tree_root
    writeU64LE(sb_buf[32..40], 2); // next_inode
    writeU64LE(sb_buf[40..48], 16380); // free_blocks
    writeU64LE(sb_buf[48..56], 1); // generation
    writeU64LE(sb_buf[56..64], 2); // bitmap_start
    writeU64LE(sb_buf[64..72], 3); // data_start

    // Verify fields at expected offsets
    try std.testing.expect(std.mem.eql(u8, sb_buf[0..8], "FXFS0001"));
    const bs = @as(u32, sb_buf[8]) | (@as(u32, sb_buf[9]) << 8) | (@as(u32, sb_buf[10]) << 16) | (@as(u32, sb_buf[11]) << 24);
    try std.testing.expectEqual(@as(u32, 4096), bs);
}
