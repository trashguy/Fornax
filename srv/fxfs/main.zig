/// fxfs — Fornax filesystem server (read-only + read-write with CoW).
///
/// Serves a persistent B-tree filesystem via IPC over fd 3 (server channel).
/// Block device accessed via fd 4 (/dev/blk0) using pread/pwrite.
///
/// Protocol: same handle-based protocol as ramfs.
///   T_OPEN(path)           → R_OK(handle) or R_ERROR
///   T_CREATE(flags, path)  → R_OK(handle) or R_ERROR
///   T_READ(handle, off, n) → R_OK(data) or R_ERROR
///   T_WRITE(handle, data)  → R_OK(bytes_written) or R_ERROR
///   T_CLOSE(handle)        → R_OK or R_ERROR
///   T_STAT(handle)         → R_OK(stat_data) or R_ERROR
///   T_REMOVE(path)         → R_OK or R_ERROR
const fx = @import("fornax");

const BLOCK_SIZE = 4096;
const MAGIC = "FXFS0001";
const SERVER_FD = 3;
const BLK_FD = 4;

// Item types
const INODE_ITEM: u8 = 1;
const DIR_ENTRY: u8 = 2;
const EXTENT_DATA: u8 = 3;

// File types
const S_IFDIR: u16 = 0o040000;
const S_IFREG: u16 = 0o100000;
const S_IFMT: u16 = 0o170000;

// Dir entry file types
const DT_REG: u8 = 1;
const DT_DIR: u8 = 2;

// Max constants
const MAX_HANDLES = 32;
const MAX_NAME = 255;
const NODE_HEADER_SIZE = 16;
const NODE_DATA_SIZE = BLOCK_SIZE - NODE_HEADER_SIZE;

// Max items per leaf: (4096 - 16) / 21 = ~194 (but data space limits this)
const MAX_LEAF_ITEMS = 194;

// Max keys per internal node: (4096 - 16) / (17 + 8) = 163
const MAX_INTERNAL_KEYS = 163;

// Node cache
const CACHE_SIZE = 16;

// ── On-disk structures ─────────────────────────────────────────────

const Key = struct {
    inode_nr: u64,
    item_type: u8,
    offset: u64,

    fn lessThan(a: Key, b: Key) bool {
        if (a.inode_nr != b.inode_nr) return a.inode_nr < b.inode_nr;
        if (a.item_type != b.item_type) return a.item_type < b.item_type;
        return a.offset < b.offset;
    }

    fn eql(a: Key, b: Key) bool {
        return a.inode_nr == b.inode_nr and a.item_type == b.item_type and a.offset == b.offset;
    }

    fn lessOrEqual(a: Key, b: Key) bool {
        return a.lessThan(b) or a.eql(b);
    }
};

const InodeItem = struct {
    mode: u16,
    uid: u16,
    gid: u16,
    nlinks: u16,
    size: u64,
    atime: u64,
    mtime: u64,
    ctime: u64,
};

const INODE_ITEM_SIZE = 40; // 2+2+2+2+8+8+8+8

const ExtentData = struct {
    disk_block: u64,
    num_blocks: u32,
};

const EXTENT_DATA_SIZE = 16; // 8+4+4(reserved)

// ── Leaf item ──────────────────────────────────────────────────────

const LeafItemHeader = struct {
    key: Key,
    data_offset: u16,
    data_size: u16,
};

const LEAF_ITEM_HEADER_SIZE = 21; // 8+1+8+2+2

// ── Handle table ───────────────────────────────────────────────────

const Handle = struct {
    inode_nr: u64,
    write_offset: u64,
    active: bool,
};

var handles: [MAX_HANDLES]Handle linksection(".bss") = undefined;

fn allocHandle(inode_nr: u64) ?u32 {
    for (1..MAX_HANDLES) |i| {
        if (!handles[i].active) {
            handles[i] = .{ .inode_nr = inode_nr, .write_offset = 0, .active = true };
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

// ── Node cache ─────────────────────────────────────────────────────

const CacheEntry = struct {
    block_nr: u64,
    valid: bool,
    use_count: u32,
};

var cache_blocks: [CACHE_SIZE][BLOCK_SIZE]u8 linksection(".bss") = undefined;
var cache_entries: [CACHE_SIZE]CacheEntry linksection(".bss") = undefined;

fn cacheInit() void {
    for (0..CACHE_SIZE) |i| {
        cache_entries[i] = .{ .block_nr = 0, .valid = false, .use_count = 0 };
    }
}

fn cacheRead(block_nr: u64) ?*[BLOCK_SIZE]u8 {
    // Check if already cached
    for (0..CACHE_SIZE) |i| {
        if (cache_entries[i].valid and cache_entries[i].block_nr == block_nr) {
            cache_entries[i].use_count +%= 1;
            return &cache_blocks[i];
        }
    }
    return null;
}

fn cacheInsert(block_nr: u64, data: *const [BLOCK_SIZE]u8) *[BLOCK_SIZE]u8 {
    // Find free slot or evict LRU
    var min_use: u32 = 0xFFFFFFFF;
    var evict_idx: usize = 0;
    for (0..CACHE_SIZE) |i| {
        if (!cache_entries[i].valid) {
            evict_idx = i;
            break;
        }
        if (cache_entries[i].use_count < min_use) {
            min_use = cache_entries[i].use_count;
            evict_idx = i;
        }
    }

    @memcpy(&cache_blocks[evict_idx], data);
    cache_entries[evict_idx] = .{ .block_nr = block_nr, .valid = true, .use_count = 1 };
    return &cache_blocks[evict_idx];
}

fn cacheInvalidate(block_nr: u64) void {
    for (0..CACHE_SIZE) |i| {
        if (cache_entries[i].valid and cache_entries[i].block_nr == block_nr) {
            cache_entries[i].valid = false;
        }
    }
}

// ── Block I/O ──────────────────────────────────────────────────────

var io_buf: [BLOCK_SIZE]u8 linksection(".bss") = undefined;

fn readBlock(block_nr: u64, buf: *[BLOCK_SIZE]u8) bool {
    const n = fx.pread(BLK_FD, buf, block_nr * BLOCK_SIZE);
    return n == BLOCK_SIZE;
}

fn writeBlock(block_nr: u64, buf: *const [BLOCK_SIZE]u8) bool {
    const n = fx.pwrite(BLK_FD, buf, block_nr * BLOCK_SIZE);
    return n == BLOCK_SIZE;
}

fn readBlockCached(block_nr: u64) ?*[BLOCK_SIZE]u8 {
    if (cacheRead(block_nr)) |cached| return cached;

    if (!readBlock(block_nr, &io_buf)) return null;
    return cacheInsert(block_nr, &io_buf);
}

// ── Superblock ─────────────────────────────────────────────────────

var sb_tree_root: u64 = 0;
var sb_next_inode: u64 = 0;
var sb_free_blocks: u64 = 0;
var sb_generation: u64 = 0;
var sb_bitmap_start: u64 = 0;
var sb_data_start: u64 = 0;
var sb_total_blocks: u64 = 0;

fn loadSuperblock() bool {
    var sb_buf: [BLOCK_SIZE]u8 = undefined;
    if (!readBlock(0, &sb_buf)) return false;

    // Check magic
    if (!fx.str.eql(sb_buf[0..8], MAGIC)) {
        _ = fx.write(1, "fxfs: bad magic\n");
        return false;
    }

    sb_total_blocks = readU64LE(sb_buf[16..24]);
    sb_tree_root = readU64LE(sb_buf[24..32]);
    sb_next_inode = readU64LE(sb_buf[32..40]);
    sb_free_blocks = readU64LE(sb_buf[40..48]);
    sb_generation = readU64LE(sb_buf[48..56]);
    sb_bitmap_start = readU64LE(sb_buf[56..64]);
    sb_data_start = readU64LE(sb_buf[64..72]);

    return true;
}

fn writeSuperblock() bool {
    var sb_buf: [BLOCK_SIZE]u8 = [_]u8{0} ** BLOCK_SIZE;
    @memcpy(sb_buf[0..8], MAGIC);
    writeU32LE(sb_buf[8..12], BLOCK_SIZE); // block_size
    writeU64LE(sb_buf[16..24], sb_total_blocks);
    writeU64LE(sb_buf[24..32], sb_tree_root);
    writeU64LE(sb_buf[32..40], sb_next_inode);
    writeU64LE(sb_buf[40..48], sb_free_blocks);
    writeU64LE(sb_buf[48..56], sb_generation);
    writeU64LE(sb_buf[56..64], sb_bitmap_start);
    writeU64LE(sb_buf[64..72], sb_data_start);

    // Checksum
    const cksum = crc32(sb_buf[0..80]);
    writeU32LE(sb_buf[76..80], cksum);

    // Write primary and backup
    if (!writeBlock(0, &sb_buf)) return false;
    if (!writeBlock(1, &sb_buf)) return false;
    return true;
}

// ── Byte helpers ───────────────────────────────────────────────────

fn readU16LE(buf: *const [2]u8) u16 {
    return @as(u16, buf[0]) | (@as(u16, buf[1]) << 8);
}

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

fn crc32(data: []const u8) u32 {
    // Simple CRC32 (IEEE polynomial)
    var crc: u32 = 0xFFFFFFFF;
    for (data) |b| {
        crc ^= b;
        for (0..8) |_| {
            if (crc & 1 != 0) {
                crc = (crc >> 1) ^ 0xEDB88320;
            } else {
                crc = crc >> 1;
            }
        }
    }
    return crc ^ 0xFFFFFFFF;
}

fn fnvHash(data: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (data) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

// ── B-tree node parsing ────────────────────────────────────────────

fn parseNodeLevel(node: *const [BLOCK_SIZE]u8) u8 {
    return node[0];
}

fn parseNodeNumItems(node: *const [BLOCK_SIZE]u8) u16 {
    return readU16LE(node[1..3]);
}

fn parseLeafItemKey(node: *const [BLOCK_SIZE]u8, idx: u16) Key {
    const base = NODE_HEADER_SIZE + @as(usize, idx) * LEAF_ITEM_HEADER_SIZE;
    return .{
        .inode_nr = readU64LE(node[base..][0..8]),
        .item_type = node[base + 8],
        .offset = readU64LE(node[base + 9..][0..8]),
    };
}

fn parseLeafItemDataOffset(node: *const [BLOCK_SIZE]u8, idx: u16) u16 {
    const base = NODE_HEADER_SIZE + @as(usize, idx) * LEAF_ITEM_HEADER_SIZE + 17;
    return readU16LE(node[base..][0..2]);
}

fn parseLeafItemDataSize(node: *const [BLOCK_SIZE]u8, idx: u16) u16 {
    const base = NODE_HEADER_SIZE + @as(usize, idx) * LEAF_ITEM_HEADER_SIZE + 19;
    return readU16LE(node[base..][0..2]);
}

fn parseLeafItemData(node: *const [BLOCK_SIZE]u8, idx: u16) []const u8 {
    const d_offset = parseLeafItemDataOffset(node, idx);
    const d_size = parseLeafItemDataSize(node, idx);
    if (d_offset + d_size > BLOCK_SIZE) return &[_]u8{};
    return node[d_offset..][0..d_size];
}

fn parseInternalKey(node: *const [BLOCK_SIZE]u8, idx: u16) Key {
    // Internal nodes: keys start at NODE_HEADER_SIZE, each key is 17 bytes
    const base = NODE_HEADER_SIZE + @as(usize, idx) * 17;
    return .{
        .inode_nr = readU64LE(node[base..][0..8]),
        .item_type = node[base + 8],
        .offset = readU64LE(node[base + 9..][0..8]),
    };
}

fn parseInternalChild(node: *const [BLOCK_SIZE]u8, num_keys: u16, idx: u16) u64 {
    // Children stored after all keys
    const children_base = NODE_HEADER_SIZE + @as(usize, num_keys) * 17;
    const child_offset = children_base + @as(usize, idx) * 8;
    if (child_offset + 8 > BLOCK_SIZE) return 0;
    return readU64LE(node[child_offset..][0..8]);
}

// ── B-tree search ──────────────────────────────────────────────────

/// Search the B-tree for an exact key match. Returns the leaf item data, or null.
fn btreeSearch(key: Key) ?[]const u8 {
    var block_nr = sb_tree_root;

    // Walk down from root
    var depth: u8 = 0;
    while (depth < 10) : (depth += 1) {
        const node = readBlockCached(block_nr) orelse return null;
        const level = parseNodeLevel(node);
        const num_items = parseNodeNumItems(node);

        if (level == 0) {
            // Leaf: binary search for exact key
            return leafSearch(node, num_items, key);
        }

        // Internal node: find child to descend into
        // Find the largest key <= search key
        var child_idx: u16 = 0;
        var i: u16 = 0;
        while (i < num_items) : (i += 1) {
            const k = parseInternalKey(node, i);
            if (k.lessOrEqual(key)) {
                child_idx = i + 1;
            } else {
                break;
            }
        }
        block_nr = parseInternalChild(node, num_items, child_idx);
        if (block_nr == 0) return null;
    }

    return null;
}

fn leafSearch(node: *const [BLOCK_SIZE]u8, num_items: u16, key: Key) ?[]const u8 {
    // Linear search (could be binary but leaves are small)
    var i: u16 = 0;
    while (i < num_items) : (i += 1) {
        const k = parseLeafItemKey(node, i);
        if (k.eql(key)) {
            return parseLeafItemData(node, i);
        }
        // Keys are sorted, so if we've passed the target, stop
        if (key.lessThan(k)) return null;
    }
    return null;
}

/// Scan all items in the tree with a given inode_nr and item_type.
/// Calls callback for each matching item. Returns number of matches.
fn btreeScan(inode_nr: u64, item_type: u8, context: anytype, callback: fn (ctx: @TypeOf(context), key: Key, data: []const u8) void) u32 {
    // Start from root, find the first key >= (inode_nr, item_type, 0)
    const start_key = Key{ .inode_nr = inode_nr, .item_type = item_type, .offset = 0 };
    var count: u32 = 0;

    // Walk the tree to find the leaf containing start_key
    var block_nr = sb_tree_root;
    var depth: u8 = 0;

    while (depth < 10) : (depth += 1) {
        const node = readBlockCached(block_nr) orelse return count;
        const level = parseNodeLevel(node);
        const num_items = parseNodeNumItems(node);

        if (level == 0) {
            // Scan this leaf for matching items
            var i: u16 = 0;
            while (i < num_items) : (i += 1) {
                const k = parseLeafItemKey(node, i);
                if (k.inode_nr == inode_nr and k.item_type == item_type) {
                    const data = parseLeafItemData(node, i);
                    callback(context, k, data);
                    count += 1;
                } else if (k.inode_nr > inode_nr or (k.inode_nr == inode_nr and k.item_type > item_type)) {
                    return count; // Past our range
                }
            }
            return count;
        }

        // Internal: descend to the right child
        var child_idx: u16 = 0;
        var i: u16 = 0;
        while (i < num_items) : (i += 1) {
            const k = parseInternalKey(node, i);
            if (k.lessOrEqual(start_key)) {
                child_idx = i + 1;
            } else {
                break;
            }
        }
        block_nr = parseInternalChild(node, num_items, child_idx);
        if (block_nr == 0) return count;
    }

    return count;
}

// ── Inode operations ───────────────────────────────────────────────

fn readInode(inode_nr: u64) ?InodeItem {
    const data = btreeSearch(.{ .inode_nr = inode_nr, .item_type = INODE_ITEM, .offset = 0 }) orelse return null;
    if (data.len < INODE_ITEM_SIZE) return null;

    return .{
        .mode = readU16LE(data[0..2]),
        .uid = readU16LE(data[2..4]),
        .gid = readU16LE(data[4..6]),
        .nlinks = readU16LE(data[6..8]),
        .size = readU64LE(data[8..16]),
        .atime = readU64LE(data[16..24]),
        .mtime = readU64LE(data[24..32]),
        .ctime = readU64LE(data[32..40]),
    };
}

fn isDirectory(inode: InodeItem) bool {
    return (inode.mode & S_IFMT) == S_IFDIR;
}

// ── Directory lookup ───────────────────────────────────────────────

/// Look up a name in a directory inode. Returns the child inode number, or null.
fn dirLookup(dir_inode: u64, name: []const u8) ?u64 {
    const name_hash = fnvHash(name);
    const key = Key{ .inode_nr = dir_inode, .item_type = DIR_ENTRY, .offset = name_hash };

    // Exact hash lookup first
    if (btreeSearch(key)) |data| {
        if (data.len >= 10) {
            const entry_name_len: usize = data[9];
            if (entry_name_len <= data.len - 10) {
                const entry_name = data[10..][0..entry_name_len];
                if (fx.str.eql(entry_name, name)) {
                    return readU64LE(data[0..8]);
                }
            }
        }
    }

    // Hash collision: scan all DIR_ENTRY items for this directory
    const Ctx = struct {
        target_name: []const u8,
        result: ?u64,
    };
    var ctx = Ctx{ .target_name = name, .result = null };

    _ = btreeScan(dir_inode, DIR_ENTRY, &ctx, struct {
        fn cb(c: *Ctx, _: Key, data: []const u8) void {
            if (data.len >= 10 and c.result == null) {
                const n_len: usize = data[9];
                if (n_len <= data.len - 10) {
                    const n = data[10..][0..n_len];
                    if (fx.str.eql(n, c.target_name)) {
                        c.result = readU64LE(data[0..8]);
                    }
                }
            }
        }
    }.cb);

    return ctx.result;
}

/// Resolve a path from root (inode 1) to an inode number.
fn resolvePath(path: []const u8) ?u64 {
    var current: u64 = 1; // root inode
    var remaining = path;

    // Skip leading slash
    if (remaining.len > 0 and remaining[0] == '/') remaining = remaining[1..];
    if (remaining.len == 0) return 1;

    while (remaining.len > 0) {
        // Extract next component
        var comp_end: usize = 0;
        while (comp_end < remaining.len and remaining[comp_end] != '/') {
            comp_end += 1;
        }
        const component = remaining[0..comp_end];
        if (component.len == 0) {
            remaining = if (comp_end < remaining.len) remaining[comp_end + 1 ..] else remaining[remaining.len..];
            continue;
        }

        // Verify current is a directory
        const inode = readInode(current) orelse return null;
        if (!isDirectory(inode)) return null;

        current = dirLookup(current, component) orelse return null;
        remaining = if (comp_end < remaining.len) remaining[comp_end + 1 ..] else remaining[remaining.len..];
    }

    return current;
}

// ── File data reading ──────────────────────────────────────────────

/// Read file data at a given offset. Returns bytes read.
var read_data_buf: [BLOCK_SIZE]u8 linksection(".bss") = undefined;

fn readFileData(inode_nr: u64, file_offset: u64, dest: []u8) u32 {
    const inode = readInode(inode_nr) orelse return 0;
    if (file_offset >= inode.size) return 0;

    const available = inode.size - file_offset;
    const want: u32 = @intCast(@min(dest.len, @min(available, 4096)));
    if (want == 0) return 0;

    // Search for EXTENT_DATA at offset 0 (covers inline and extent data)
    const extent_key = Key{ .inode_nr = inode_nr, .item_type = EXTENT_DATA, .offset = 0 };
    const data = btreeSearch(extent_key) orelse return 0;

    // Extent items are always exactly EXTENT_DATA_SIZE bytes with disk_block > 0.
    // Everything else is inline data (raw file content stored in the B-tree leaf).
    if (data.len == EXTENT_DATA_SIZE) {
        const disk_block = readU64LE(data[0..8]);
        if (disk_block > 0) {
            // Extent: read from disk blocks
            const block_in_extent = file_offset / BLOCK_SIZE;
            const offset_in_block = file_offset % BLOCK_SIZE;
            const target_block = disk_block + block_in_extent;

            if (!readBlock(target_block, &read_data_buf)) return 0;

            const block_avail: u32 = @intCast(BLOCK_SIZE - offset_in_block);
            const to_copy = @min(want, block_avail);
            @memcpy(dest[0..to_copy], read_data_buf[@intCast(offset_in_block)..][0..to_copy]);
            return to_copy;
        }
    }

    // Inline data: raw file content stored directly in B-tree leaf
    if (file_offset < data.len) {
        const avail: u32 = @intCast(data.len - file_offset);
        const to_copy = @min(want, avail);
        @memcpy(dest[0..to_copy], data[@intCast(file_offset)..][0..to_copy]);
        return to_copy;
    }

    return 0;
}

// ── Bitmap operations ──────────────────────────────────────────────

var bitmap_buf: [BLOCK_SIZE]u8 linksection(".bss") = undefined;
var bitmap_loaded: bool = false;

fn loadBitmap() bool {
    if (bitmap_loaded) return true;
    if (!readBlock(sb_bitmap_start, &bitmap_buf)) return false;
    bitmap_loaded = true;
    return true;
}

fn isBitSet(block: u64) bool {
    if (!loadBitmap()) return true; // assume allocated on failure
    const byte_idx = block / 8;
    const bit_idx: u3 = @intCast(block % 8);
    if (byte_idx >= BLOCK_SIZE) return true;
    return (bitmap_buf[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
}

fn setBit(block: u64) void {
    if (!loadBitmap()) return;
    const byte_idx = block / 8;
    const bit_idx: u3 = @intCast(block % 8);
    if (byte_idx < BLOCK_SIZE) {
        bitmap_buf[byte_idx] |= @as(u8, 1) << bit_idx;
    }
}

fn clearBit(block: u64) void {
    if (!loadBitmap()) return;
    const byte_idx = block / 8;
    const bit_idx: u3 = @intCast(block % 8);
    if (byte_idx < BLOCK_SIZE) {
        bitmap_buf[byte_idx] &= ~(@as(u8, 1) << bit_idx);
    }
}

fn flushBitmap() bool {
    if (!bitmap_loaded) return true;
    return writeBlock(sb_bitmap_start, &bitmap_buf);
}

fn allocBlock() ?u64 {
    if (!loadBitmap()) return null;
    var block: u64 = sb_data_start;
    while (block < sb_total_blocks) : (block += 1) {
        if (!isBitSet(block)) {
            setBit(block);
            sb_free_blocks -%= 1;
            return block;
        }
    }
    return null;
}

fn freeBlock(block: u64) void {
    clearBit(block);
    sb_free_blocks +%= 1;
    cacheInvalidate(block);
}

// ── B-tree node writing (for CoW) ──────────────────────────────────

fn writeNodeHeader(buf: *[BLOCK_SIZE]u8, level: u8, num_items: u16, generation: u64) void {
    buf[0] = level;
    writeU16LE(buf[1..3], num_items);
    buf[3] = 0; // pad
    writeU64LE(buf[4..12], generation);
    writeU32LE(buf[12..16], 0); // checksum placeholder
}

fn writeLeafItem(buf: *[BLOCK_SIZE]u8, idx: u16, key: Key, data_offset: u16, data_size: u16) void {
    const base = NODE_HEADER_SIZE + @as(usize, idx) * LEAF_ITEM_HEADER_SIZE;
    writeU64LE(buf[base..][0..8], key.inode_nr);
    buf[base + 8] = key.item_type;
    writeU64LE(buf[base + 9..][0..8], key.offset);
    writeU16LE(buf[base + 17..][0..2], data_offset);
    writeU16LE(buf[base + 19..][0..2], data_size);
}

fn writeInternalKey(buf: *[BLOCK_SIZE]u8, idx: u16, key: Key) void {
    const base = NODE_HEADER_SIZE + @as(usize, idx) * 17;
    writeU64LE(buf[base..][0..8], key.inode_nr);
    buf[base + 8] = key.item_type;
    writeU64LE(buf[base + 9..][0..8], key.offset);
}

fn writeInternalChild(buf: *[BLOCK_SIZE]u8, num_keys: u16, idx: u16, child: u64) void {
    const children_base = NODE_HEADER_SIZE + @as(usize, num_keys) * 17;
    const child_offset = children_base + @as(usize, idx) * 8;
    if (child_offset + 8 <= BLOCK_SIZE) {
        writeU64LE(buf[child_offset..][0..8], child);
    }
}

// ── CoW B-tree mutation ────────────────────────────────────────────

/// Copy a node to a new block (CoW). Returns new block number.
fn cowNode(old_block: u64) ?u64 {
    const new_block = allocBlock() orelse return null;
    const old_data = readBlockCached(old_block) orelse {
        freeBlock(new_block);
        return null;
    };

    var new_data: [BLOCK_SIZE]u8 = undefined;
    @memcpy(&new_data, old_data);

    // Update generation
    writeU64LE(new_data[4..12], sb_generation + 1);

    if (!writeBlock(new_block, &new_data)) {
        freeBlock(new_block);
        return null;
    }

    // Insert into cache
    _ = cacheInsert(new_block, &new_data);

    return new_block;
}

/// Insert an item into the B-tree. Does CoW on modified nodes.
/// Returns true on success.
fn btreeInsert(key: Key, data: []const u8) bool {
    // For now, handle single-leaf trees (no splits needed for small filesystems)
    // TODO: implement node splitting for deeper trees

    const root = readBlockCached(sb_tree_root) orelse return false;
    const level = parseNodeLevel(root);

    if (level != 0) {
        // Multi-level tree: need recursive insert (not yet implemented)
        _ = fx.write(1, "fxfs: multi-level insert not yet supported\n");
        return false;
    }

    // Single leaf tree: CoW the leaf, insert the item
    return leafInsert(sb_tree_root, key, data);
}

fn leafInsert(leaf_block: u64, key: Key, data: []const u8) bool {
    const old_leaf = readBlockCached(leaf_block) orelse return false;
    const num_items = parseNodeNumItems(old_leaf);

    // Build new leaf with the item inserted in sorted order
    var new_buf: [BLOCK_SIZE]u8 = [_]u8{0} ** BLOCK_SIZE;
    var data_cursor: usize = BLOCK_SIZE;
    var new_count: u16 = 0;
    var inserted = false;

    var i: u16 = 0;
    while (i < num_items) : (i += 1) {
        const k = parseLeafItemKey(old_leaf, i);

        // Insert new item before first key that's greater
        if (!inserted and key.lessThan(k)) {
            data_cursor -= data.len;
            @memcpy(new_buf[data_cursor..][0..data.len], data);
            writeLeafItem(&new_buf, new_count, key, @intCast(data_cursor), @intCast(data.len));
            new_count += 1;
            inserted = true;
        }

        // Copy existing item
        const old_data = parseLeafItemData(old_leaf, i);
        data_cursor -= old_data.len;
        @memcpy(new_buf[data_cursor..][0..old_data.len], old_data);
        writeLeafItem(&new_buf, new_count, k, @intCast(data_cursor), @intCast(old_data.len));
        new_count += 1;
    }

    // Insert at end if not yet inserted
    if (!inserted) {
        data_cursor -= data.len;
        @memcpy(new_buf[data_cursor..][0..data.len], data);
        writeLeafItem(&new_buf, new_count, key, @intCast(data_cursor), @intCast(data.len));
        new_count += 1;
    }

    // Write header
    writeNodeHeader(&new_buf, 0, new_count, sb_generation + 1);

    // Allocate new block
    const new_block = allocBlock() orelse return false;
    if (!writeBlock(new_block, &new_buf)) {
        freeBlock(new_block);
        return false;
    }
    _ = cacheInsert(new_block, &new_buf);

    // Free old root, update tree root
    if (leaf_block != sb_tree_root or leaf_block == sb_tree_root) {
        freeBlock(leaf_block);
    }
    sb_tree_root = new_block;

    return true;
}

/// Delete an item from the B-tree by key. Returns true on success.
fn btreeDelete(key: Key) bool {
    const root = readBlockCached(sb_tree_root) orelse return false;
    const level = parseNodeLevel(root);

    if (level != 0) {
        _ = fx.write(1, "fxfs: multi-level delete not yet supported\n");
        return false;
    }

    return leafDelete(sb_tree_root, key);
}

fn leafDelete(leaf_block: u64, key: Key) bool {
    const old_leaf = readBlockCached(leaf_block) orelse return false;
    const num_items = parseNodeNumItems(old_leaf);

    var new_buf: [BLOCK_SIZE]u8 = [_]u8{0} ** BLOCK_SIZE;
    var data_cursor: usize = BLOCK_SIZE;
    var new_count: u16 = 0;
    var deleted = false;

    var i: u16 = 0;
    while (i < num_items) : (i += 1) {
        const k = parseLeafItemKey(old_leaf, i);

        if (k.eql(key)) {
            deleted = true;
            continue; // skip this item
        }

        const old_data = parseLeafItemData(old_leaf, i);
        data_cursor -= old_data.len;
        @memcpy(new_buf[data_cursor..][0..old_data.len], old_data);
        writeLeafItem(&new_buf, new_count, k, @intCast(data_cursor), @intCast(old_data.len));
        new_count += 1;
    }

    if (!deleted) return false;

    writeNodeHeader(&new_buf, 0, new_count, sb_generation + 1);

    const new_block = allocBlock() orelse return false;
    if (!writeBlock(new_block, &new_buf)) {
        freeBlock(new_block);
        return false;
    }
    _ = cacheInsert(new_block, &new_buf);

    freeBlock(leaf_block);
    sb_tree_root = new_block;

    return true;
}

/// Update an existing item (delete + insert)
fn btreeUpdate(key: Key, data: []const u8) bool {
    // Delete old, insert new
    _ = btreeDelete(key);
    return btreeInsert(key, data);
}

fn commitTransaction() bool {
    sb_generation += 1;
    if (!flushBitmap()) return false;
    if (!writeSuperblock()) return false;
    return true;
}

// ── IPC handlers ───────────────────────────────────────────────────

var msg: fx.IpcMessage linksection(".bss") = undefined;
var reply: fx.IpcMessage linksection(".bss") = undefined;

fn ctlAppendStr(buf: []u8, pos: usize, s: []const u8) usize {
    if (pos + s.len > buf.len) return pos;
    @memcpy(buf[pos..][0..s.len], s);
    return pos + s.len;
}

fn ctlAppendDec(buf: []u8, pos: usize, val: u64) usize {
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
    var i: usize = 0;
    while (i < len) : (i += 1) {
        buf[pos + i] = tmp[len - 1 - i];
    }
    return pos + len;
}

fn handleOpen(req: *fx.IpcMessage, resp: *fx.IpcMessage) void {
    const path = req.data[0..req.data_len];

    // Virtual "ctl" file for filesystem stats
    if (fx.str.eql(path, "ctl")) {
        const handle = allocHandle(0xFFFF_FFFF_FFFF_FFFF) orelse {
            resp.* = fx.IpcMessage.init(fx.R_ERROR);
            return;
        };
        resp.* = fx.IpcMessage.init(fx.R_OK);
        writeU32LE(resp.data[0..4], handle);
        resp.data_len = 4;
        return;
    }

    const inode_nr = resolvePath(path) orelse {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    // Verify inode exists
    _ = readInode(inode_nr) orelse {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    const handle = allocHandle(inode_nr) orelse {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    resp.* = fx.IpcMessage.init(fx.R_OK);
    writeU32LE(resp.data[0..4], handle);
    resp.data_len = 4;
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

    // Virtual ctl file: return filesystem stats
    if (h.inode_nr == 0xFFFF_FFFF_FFFF_FFFF) {
        resp.* = fx.IpcMessage.init(fx.R_OK);
        var ctl_buf: [256]u8 = undefined;
        var pos: usize = 0;
        pos = ctlAppendStr(&ctl_buf, pos, "TOTAL=");
        pos = ctlAppendDec(&ctl_buf, pos, sb_total_blocks);
        pos = ctlAppendStr(&ctl_buf, pos, "\nFREE=");
        pos = ctlAppendDec(&ctl_buf, pos, sb_free_blocks);
        pos = ctlAppendStr(&ctl_buf, pos, "\nBSIZE=4096\n");
        if (offset >= pos) {
            resp.data_len = 0;
            return;
        }
        const remaining = pos - offset;
        const to_copy: u32 = @intCast(@min(remaining, @min(count, 4096)));
        @memcpy(resp.data[0..to_copy], ctl_buf[offset..][0..to_copy]);
        resp.data_len = to_copy;
        return;
    }

    const inode = readInode(h.inode_nr) orelse {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    if (isDirectory(inode)) {
        readDirectory(h.inode_nr, offset, count, resp);
        return;
    }

    // Read file data
    resp.* = fx.IpcMessage.init(fx.R_OK);
    const to_read = @min(count, 4096);
    const n = readFileData(h.inode_nr, offset, resp.data[0..to_read]);
    resp.data_len = n;
}

fn readDirectory(inode_nr: u64, offset: u32, count: u32, resp: *fx.IpcMessage) void {
    resp.* = fx.IpcMessage.init(fx.R_OK);

    const entry_size = @sizeOf(fx.DirEntry);
    const max_entries: u32 = @intCast(@min(count / entry_size, 4096 / entry_size));
    const skip = offset / entry_size;

    const Ctx = struct {
        resp_ptr: *fx.IpcMessage,
        written: u32,
        entries_written: u32,
        skipped: u32,
        skip_target: u32,
        max_entries: u32,
        entry_size: u32,
    };

    var ctx = Ctx{
        .resp_ptr = resp,
        .written = 0,
        .entries_written = 0,
        .skipped = 0,
        .skip_target = skip,
        .max_entries = max_entries,
        .entry_size = entry_size,
    };

    _ = btreeScan(inode_nr, DIR_ENTRY, &ctx, struct {
        fn cb(c: *Ctx, _: Key, data: []const u8) void {
            if (c.entries_written >= c.max_entries) return;

            if (c.skipped < c.skip_target) {
                c.skipped += 1;
                return;
            }

            if (data.len < 10) return;
            const child_inode = readU64LE(data[0..8]);
            _ = child_inode;
            const file_type: u8 = data[8];
            const name_len: usize = data[9];
            if (name_len > data.len - 10) return;
            const name = data[10..][0..name_len];

            // Read child inode for size
            var size: u32 = 0;
            if (readInode(readU64LE(data[0..8]))) |child| {
                size = @intCast(@min(child.size, 0xFFFFFFFF));
            }

            // Write DirEntry
            const dest_base = c.written;
            if (dest_base + c.entry_size > 4096) return;

            const dest: *fx.DirEntry = @ptrCast(@alignCast(c.resp_ptr.data[dest_base..][0..c.entry_size]));
            @memset(&dest.name, 0);
            const copy_len = @min(name_len, 63);
            @memcpy(dest.name[0..copy_len], name[0..copy_len]);
            dest.file_type = if (file_type == DT_DIR) 1 else 0;
            dest.size = size;

            c.written += c.entry_size;
            c.entries_written += 1;
        }
    }.cb);

    resp.data_len = ctx.written;
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

    // Virtual ctl file stat
    if (h.inode_nr == 0xFFFF_FFFF_FFFF_FFFF) {
        resp.* = fx.IpcMessage.init(fx.R_OK);
        @memset(resp.data[0..64], 0);
        writeU32LE(resp.data[0..4], 256); // approximate size
        writeU32LE(resp.data[4..8], 0); // file
        resp.data_len = 64;
        return;
    }

    const inode = readInode(h.inode_nr) orelse {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    resp.* = fx.IpcMessage.init(fx.R_OK);
    @memset(resp.data[0..64], 0);
    writeU32LE(resp.data[0..4], @intCast(@min(inode.size, 0xFFFFFFFF)));
    writeU32LE(resp.data[4..8], if (isDirectory(inode)) 1 else 0);
    resp.data_len = 64;
}

fn handleCreate(req: *fx.IpcMessage, resp: *fx.IpcMessage) void {
    if (req.data_len < 4) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }

    const flags = readU32LE(req.data[0..4]);
    const path = req.data[4..req.data_len];
    const is_dir = (flags & 1) != 0;

    // Check if already exists
    if (resolvePath(path)) |existing| {
        const handle = allocHandle(existing) orelse {
            resp.* = fx.IpcMessage.init(fx.R_ERROR);
            return;
        };
        resp.* = fx.IpcMessage.init(fx.R_OK);
        writeU32LE(resp.data[0..4], handle);
        resp.data_len = 4;
        return;
    }

    // Find parent directory
    var parent_inode: u64 = 1;
    var file_name: []const u8 = path;

    // Find last '/'
    var last_slash: ?usize = null;
    for (path, 0..) |c, i_| {
        if (c == '/') last_slash = i_;
    }

    if (last_slash) |slash| {
        const dir_path = path[0..slash];
        file_name = path[slash + 1 ..];
        parent_inode = resolvePath(dir_path) orelse {
            resp.* = fx.IpcMessage.init(fx.R_ERROR);
            return;
        };
    }

    if (file_name.len == 0 or file_name.len > MAX_NAME) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }

    // Allocate inode number
    const new_inode = sb_next_inode;
    sb_next_inode += 1;

    // Create INODE_ITEM
    var inode_data: [INODE_ITEM_SIZE]u8 = undefined;
    const mode: u16 = if (is_dir) S_IFDIR | 0o755 else S_IFREG | 0o644;
    writeU16LE(inode_data[0..2], mode);
    writeU16LE(inode_data[2..4], 0); // uid
    writeU16LE(inode_data[4..6], 0); // gid
    writeU16LE(inode_data[6..8], 1); // nlinks
    writeU64LE(inode_data[8..16], 0); // size
    writeU64LE(inode_data[16..24], 0); // atime
    writeU64LE(inode_data[24..32], 0); // mtime
    writeU64LE(inode_data[32..40], 0); // ctime

    if (!btreeInsert(.{ .inode_nr = new_inode, .item_type = INODE_ITEM, .offset = 0 }, &inode_data)) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }

    // Create DIR_ENTRY in parent
    const name_hash = fnvHash(file_name);
    var dir_data: [266]u8 = undefined;
    writeU64LE(dir_data[0..8], new_inode);
    dir_data[8] = if (is_dir) DT_DIR else DT_REG;
    dir_data[9] = @intCast(file_name.len);
    @memcpy(dir_data[10..][0..file_name.len], file_name);
    const dir_len: usize = 10 + file_name.len;

    if (!btreeInsert(.{ .inode_nr = parent_inode, .item_type = DIR_ENTRY, .offset = name_hash }, dir_data[0..dir_len])) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }

    if (!commitTransaction()) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }

    const handle = allocHandle(new_inode) orelse {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    resp.* = fx.IpcMessage.init(fx.R_OK);
    writeU32LE(resp.data[0..4], handle);
    resp.data_len = 4;
}

fn handleWrite(req: *fx.IpcMessage, resp: *fx.IpcMessage) void {
    if (req.data_len < 4) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }

    const handle_id = readU32LE(req.data[0..4]);
    const write_data = req.data[4..req.data_len];

    const h = getHandle(handle_id) orelse {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    const inode = readInode(h.inode_nr) orelse {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    if (isDirectory(inode)) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }

    const write_offset: usize = @intCast(h.write_offset);
    const new_end: usize = write_offset + write_data.len;
    const new_size: u64 = @max(inode.size, new_end);

    // For small files, store inline in the B-tree
    if (new_end <= 3800) {
        // Build combined buffer: preserve existing data, place new data at write_offset
        var combined: [3800]u8 = [_]u8{0} ** 3800;

        // Read existing inline data before tree modification (btreeSearch returns
        // a slice into a cached block buffer that gets invalidated by btreeDelete)
        if (write_offset > 0) {
            if (btreeSearch(.{ .inode_nr = h.inode_nr, .item_type = EXTENT_DATA, .offset = 0 })) |existing| {
                // Extent items are exactly EXTENT_DATA_SIZE bytes with disk_block > 0
                const is_extent = existing.len == EXTENT_DATA_SIZE and readU64LE(existing[0..8]) > 0;
                if (!is_extent) {
                    const copy_len = @min(existing.len, write_offset);
                    @memcpy(combined[0..copy_len], existing[0..copy_len]);
                }
            }
        }

        // Place new data at write_offset
        @memcpy(combined[write_offset..][0..write_data.len], write_data);

        // Delete old extent data if exists
        _ = btreeDelete(.{ .inode_nr = h.inode_nr, .item_type = EXTENT_DATA, .offset = 0 });

        // Insert combined inline data
        if (!btreeInsert(.{ .inode_nr = h.inode_nr, .item_type = EXTENT_DATA, .offset = 0 }, combined[0..new_end])) {
            resp.* = fx.IpcMessage.init(fx.R_ERROR);
            return;
        }
    } else {
        // Allocate data block(s)
        const num_blocks = (new_end + BLOCK_SIZE - 1) / BLOCK_SIZE;
        const first_block = allocBlock() orelse {
            resp.* = fx.IpcMessage.init(fx.R_ERROR);
            return;
        };

        // Allocate remaining blocks (must be contiguous for simple extent)
        var blocks_ok = true;
        var b: u64 = 1;
        while (b < num_blocks) : (b += 1) {
            const next = allocBlock() orelse {
                blocks_ok = false;
                break;
            };
            if (next != first_block + b) {
                // Not contiguous — give up for now
                freeBlock(next);
                blocks_ok = false;
                break;
            }
        }

        if (!blocks_ok) {
            freeBlock(first_block);
            resp.* = fx.IpcMessage.init(fx.R_ERROR);
            return;
        }

        // Read existing data if we're writing at an offset
        // then overlay new data at write_offset
        var block_buf: [BLOCK_SIZE]u8 = [_]u8{0} ** BLOCK_SIZE;

        // Write data blocks
        var offset: usize = 0;
        b = 0;
        while (b < num_blocks) : (b += 1) {
            @memset(&block_buf, 0);
            // Copy existing data for this block range if needed
            // (for simplicity, just write new data at write_offset)
            const block_start = b * BLOCK_SIZE;
            if (block_start < new_end) {
                // Determine what part of the combined data falls in this block
                const data_start = if (block_start >= write_offset) block_start - write_offset else 0;
                const buf_start = if (write_offset > block_start) write_offset - block_start else 0;
                if (data_start < write_data.len) {
                    const remaining = write_data.len - data_start;
                    const space = BLOCK_SIZE - buf_start;
                    const to_copy = @min(remaining, space);
                    @memcpy(block_buf[buf_start..][0..to_copy], write_data[data_start..][0..to_copy]);
                }
            }
            if (!writeBlock(first_block + b, &block_buf)) {
                resp.* = fx.IpcMessage.init(fx.R_ERROR);
                return;
            }
            offset += BLOCK_SIZE;
        }

        // Delete old extent data
        _ = btreeDelete(.{ .inode_nr = h.inode_nr, .item_type = EXTENT_DATA, .offset = 0 });

        // Insert extent reference
        var extent_data: [EXTENT_DATA_SIZE]u8 = undefined;
        writeU64LE(extent_data[0..8], first_block);
        writeU32LE(extent_data[8..12], @intCast(num_blocks));
        writeU32LE(extent_data[12..16], 0); // reserved

        if (!btreeInsert(.{ .inode_nr = h.inode_nr, .item_type = EXTENT_DATA, .offset = 0 }, &extent_data)) {
            resp.* = fx.IpcMessage.init(fx.R_ERROR);
            return;
        }
    }

    // Update inode size
    var inode_data: [INODE_ITEM_SIZE]u8 = undefined;
    writeU16LE(inode_data[0..2], inode.mode);
    writeU16LE(inode_data[2..4], inode.uid);
    writeU16LE(inode_data[4..6], inode.gid);
    writeU16LE(inode_data[6..8], inode.nlinks);
    writeU64LE(inode_data[8..16], new_size);
    writeU64LE(inode_data[16..24], inode.atime);
    writeU64LE(inode_data[24..32], inode.mtime);
    writeU64LE(inode_data[32..40], inode.ctime);

    if (!btreeUpdate(.{ .inode_nr = h.inode_nr, .item_type = INODE_ITEM, .offset = 0 }, &inode_data)) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }

    if (!commitTransaction()) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }

    // Advance write offset
    h.write_offset = new_end;

    resp.* = fx.IpcMessage.init(fx.R_OK);
    const written: u32 = @intCast(write_data.len);
    writeU32LE(resp.data[0..4], written);
    resp.data_len = 4;
}

fn handleRemove(req: *fx.IpcMessage, resp: *fx.IpcMessage) void {
    const path = req.data[0..req.data_len];

    // Find the inode
    const inode_nr = resolvePath(path) orelse {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    // Don't remove root
    if (inode_nr == 1) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }

    // Find parent and name
    var parent_inode: u64 = 1;
    var file_name: []const u8 = path;

    var last_slash: ?usize = null;
    for (path, 0..) |c, i_| {
        if (c == '/') last_slash = i_;
    }

    if (last_slash) |slash| {
        const dir_path = path[0..slash];
        file_name = path[slash + 1 ..];
        parent_inode = resolvePath(dir_path) orelse {
            resp.* = fx.IpcMessage.init(fx.R_ERROR);
            return;
        };
    }

    // Delete DIR_ENTRY from parent
    const name_hash = fnvHash(file_name);
    _ = btreeDelete(.{ .inode_nr = parent_inode, .item_type = DIR_ENTRY, .offset = name_hash });

    // Delete EXTENT_DATA (free data blocks if extent)
    if (btreeSearch(.{ .inode_nr = inode_nr, .item_type = EXTENT_DATA, .offset = 0 })) |data| {
        if (data.len >= EXTENT_DATA_SIZE) {
            const disk_block = readU64LE(data[0..8]);
            const num_blocks = readU32LE(data[8..12]);
            if (disk_block != 0) {
                var b: u64 = 0;
                while (b < num_blocks) : (b += 1) {
                    freeBlock(disk_block + b);
                }
            }
        }
        _ = btreeDelete(.{ .inode_nr = inode_nr, .item_type = EXTENT_DATA, .offset = 0 });
    }

    // Delete INODE_ITEM
    _ = btreeDelete(.{ .inode_nr = inode_nr, .item_type = INODE_ITEM, .offset = 0 });

    // Invalidate handles
    for (1..MAX_HANDLES) |i| {
        if (handles[i].active and handles[i].inode_nr == inode_nr) {
            handles[i].active = false;
        }
    }

    if (!commitTransaction()) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }

    resp.* = fx.IpcMessage.init(fx.R_OK);
    resp.data_len = 0;
}

// ── Auto-format ────────────────────────────────────────────────────

/// Format the disk with an empty fxfs filesystem.
/// Probes disk size by reading blocks until failure.
fn formatDisk() bool {
    // Probe disk size: try reading blocks to find total capacity
    // A 64MB disk = 16384 blocks. Try common sizes.
    var total_blocks: u64 = 0;
    var probe_buf: [BLOCK_SIZE]u8 = undefined;

    // Binary search for disk size (max 1M blocks = 4GB)
    var lo: u64 = 0;
    var hi: u64 = 1048576;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (readBlock(mid, &probe_buf)) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    total_blocks = lo;
    if (total_blocks < 8) return false;

    const bitmap_blocks: u64 = (total_blocks + (BLOCK_SIZE * 8) - 1) / (BLOCK_SIZE * 8);
    const bitmap_start: u64 = 2;
    const data_start: u64 = bitmap_start + bitmap_blocks;
    const root_block: u64 = data_start;

    // Write bitmap: mark blocks 0..root_block as allocated
    var bm_buf: [BLOCK_SIZE]u8 = [_]u8{0} ** BLOCK_SIZE;
    var b: u64 = 0;
    while (b <= root_block) : (b += 1) {
        const byte_idx = b / 8;
        const bit_idx: u3 = @intCast(b % 8);
        if (byte_idx < BLOCK_SIZE) {
            bm_buf[byte_idx] |= @as(u8, 1) << bit_idx;
        }
    }
    if (!writeBlock(bitmap_start, &bm_buf)) return false;

    // Write root B-tree leaf (inode 1 = root directory)
    var leaf_buf: [BLOCK_SIZE]u8 = [_]u8{0} ** BLOCK_SIZE;

    // Node header: level=0, num_items=1, generation=1
    leaf_buf[0] = 0; // level
    writeU16LE(leaf_buf[1..3], 1); // num_items
    leaf_buf[3] = 0; // pad
    writeU64LE(leaf_buf[4..12], 1); // generation

    // Inode item data (placed at end of block)
    const inode_size: u16 = INODE_ITEM_SIZE;
    const data_offset: u16 = BLOCK_SIZE - inode_size;

    // Leaf item header at NODE_HEADER_SIZE
    writeU64LE(leaf_buf[NODE_HEADER_SIZE..][0..8], 1); // inode_nr = 1
    leaf_buf[NODE_HEADER_SIZE + 8] = INODE_ITEM; // item_type
    writeU64LE(leaf_buf[NODE_HEADER_SIZE + 9..][0..8], 0); // offset = 0
    writeU16LE(leaf_buf[NODE_HEADER_SIZE + 17..][0..2], data_offset); // data_offset
    writeU16LE(leaf_buf[NODE_HEADER_SIZE + 19..][0..2], inode_size); // data_size

    // Inode data: mode=S_IFDIR|0755, nlinks=2, rest zeros
    writeU16LE(leaf_buf[data_offset..][0..2], S_IFDIR | 0o755); // mode
    writeU16LE(leaf_buf[data_offset + 2..][0..2], 0); // uid
    writeU16LE(leaf_buf[data_offset + 4..][0..2], 0); // gid
    writeU16LE(leaf_buf[data_offset + 6..][0..2], 2); // nlinks
    // size, atime, mtime, ctime all zero (already zeroed)

    if (!writeBlock(root_block, &leaf_buf)) return false;

    // Write superblock
    var sb_buf_fmt: [BLOCK_SIZE]u8 = [_]u8{0} ** BLOCK_SIZE;
    @memcpy(sb_buf_fmt[0..8], MAGIC);
    writeU32LE(sb_buf_fmt[8..12], BLOCK_SIZE);
    writeU64LE(sb_buf_fmt[16..24], total_blocks);
    writeU64LE(sb_buf_fmt[24..32], root_block);
    writeU64LE(sb_buf_fmt[32..40], 2); // next_inode
    writeU64LE(sb_buf_fmt[40..48], total_blocks - root_block - 1); // free_blocks
    writeU64LE(sb_buf_fmt[48..56], 1); // generation
    writeU64LE(sb_buf_fmt[56..64], bitmap_start);
    writeU64LE(sb_buf_fmt[64..72], data_start);

    if (!writeBlock(0, &sb_buf_fmt)) return false;
    if (!writeBlock(1, &sb_buf_fmt)) return false;

    _ = fx.write(1, "fxfs: formatted disk\n");
    return true;
}

// ── Entry point ────────────────────────────────────────────────────

export fn _start() noreturn {
    // Initialize
    cacheInit();
    for (0..MAX_HANDLES) |i| {
        handles[i] = .{ .inode_nr = 0, .write_offset = 0, .active = false };
    }

    // Load superblock from /dev/blk0 (fd 4)
    if (!loadSuperblock()) {
        _ = fx.write(1, "fxfs: no valid superblock, formatting disk\n");
        if (!formatDisk()) {
            _ = fx.write(1, "fxfs: format failed\n");
            fx.exit(1);
        }
        if (!loadSuperblock()) {
            _ = fx.write(1, "fxfs: failed to load superblock after format\n");
            fx.exit(1);
        }
    }

    // Server loop
    while (true) {
        const rc = fx.ipc_recv(SERVER_FD, &msg);
        if (rc < 0) {
            _ = fx.write(2, "fxfs: ipc_recv error\n");
            continue;
        }

        switch (msg.tag) {
            fx.T_OPEN => handleOpen(&msg, &reply),
            fx.T_CREATE => handleCreate(&msg, &reply),
            fx.T_READ => handleRead(&msg, &reply),
            fx.T_WRITE => handleWrite(&msg, &reply),
            fx.T_CLOSE => handleClose(&msg, &reply),
            fx.T_STAT => handleStat(&msg, &reply),
            fx.T_REMOVE => handleRemove(&msg, &reply),
            else => {
                reply = fx.IpcMessage.init(fx.R_ERROR);
            },
        }

        _ = fx.ipc_reply(SERVER_FD, &reply);
    }
}
