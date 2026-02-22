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
const Mutex = fx.thread.Mutex;

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
    return allocHandleAt(inode_nr, 0);
}

fn allocHandleAt(inode_nr: u64, write_offset: u64) ?u32 {
    for (1..MAX_HANDLES) |i| {
        if (!handles[i].active) {
            handles[i] = .{ .inode_nr = inode_nr, .write_offset = write_offset, .active = true };
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
var alloc_hint: u64 = 0;

fn getTime() u64 {
    const info = fx.sysinfo() orelse return 0;
    return info.uptime_secs;
}

fn loadSuperblock() bool {
    var sb_buf: [BLOCK_SIZE]u8 = undefined;
    if (readBlock(0, &sb_buf) and validateSuperblock(&sb_buf)) {
        applySuperblock(&sb_buf);
        return true;
    }
    // Primary failed — try backup at block 1
    _ = fx.write(1, "fxfs: primary superblock bad, trying backup\n");
    if (readBlock(1, &sb_buf) and validateSuperblock(&sb_buf)) {
        applySuperblock(&sb_buf);
        return true;
    }
    _ = fx.write(1, "fxfs: both superblocks bad\n");
    return false;
}

fn validateSuperblock(sb_buf: *[BLOCK_SIZE]u8) bool {
    if (!fx.str.eql(sb_buf[0..8], MAGIC)) return false;
    // Validate CRC32: checksum covers bytes 0..80 with checksum field zeroed
    const stored_cksum = readU32LE(sb_buf[76..80]);
    if (stored_cksum != 0) {
        writeU32LE(sb_buf[76..80], 0);
        const computed = crc32(sb_buf[0..80]);
        writeU32LE(sb_buf[76..80], stored_cksum);
        if (computed != stored_cksum) return false;
    }
    return true;
}

fn applySuperblock(sb_buf: *const [BLOCK_SIZE]u8) void {
    sb_total_blocks = readU64LE(sb_buf[16..24]);
    sb_tree_root = readU64LE(sb_buf[24..32]);
    sb_next_inode = readU64LE(sb_buf[32..40]);
    sb_free_blocks = readU64LE(sb_buf[40..48]);
    sb_generation = readU64LE(sb_buf[48..56]);
    sb_bitmap_start = readU64LE(sb_buf[56..64]);
    sb_data_start = readU64LE(sb_buf[64..72]);
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

// ── B-tree path helpers (for multi-level tree operations) ──────────

const MAX_TREE_DEPTH = 10;
const PathEntry = struct { block: u64, child_idx: u16, num_keys: u16 };

/// Walk from root to the leaf containing `key`, recording the path through
/// internal nodes. Returns the leaf block number, or null on failure.
fn findLeafPath(key: Key, path: []PathEntry, path_len: *usize) ?u64 {
    var block_nr = sb_tree_root;
    path_len.* = 0;

    var depth: u8 = 0;
    while (depth < MAX_TREE_DEPTH) : (depth += 1) {
        const node = readBlockCached(block_nr) orelse return null;
        const level = parseNodeLevel(node);
        const num_items = parseNodeNumItems(node);

        if (level == 0) return block_nr;

        var child_idx: u16 = 0;
        var i: u16 = 0;
        while (i < num_items) : (i += 1) {
            const k = parseInternalKey(node, i);
            if (k.lessOrEqual(key)) {
                child_idx = i + 1;
            } else break;
        }

        if (path_len.* >= path.len) return null;
        path[path_len.*] = .{ .block = block_nr, .child_idx = child_idx, .num_keys = num_items };
        path_len.* += 1;

        block_nr = parseInternalChild(node, num_items, child_idx);
        if (block_nr == 0) return null;
    }
    return null;
}

/// After modifying a leaf, CoW each ancestor node in `path` back up to the root,
/// updating the child pointer at each level. Returns the new root block number.
fn cowPath(path: []const PathEntry, path_len: usize, new_leaf_block: u64) ?u64 {
    var child_block = new_leaf_block;
    var p = path_len;
    while (p > 0) {
        p -= 1;
        const pe = path[p];
        const old_parent = readBlockCached(pe.block) orelse return null;

        var parent_buf: [BLOCK_SIZE]u8 = undefined;
        @memcpy(&parent_buf, old_parent);

        // Update child pointer
        const children_base = NODE_HEADER_SIZE + @as(usize, pe.num_keys) * 17;
        const child_offset = children_base + @as(usize, pe.child_idx) * 8;
        writeU64LE(parent_buf[child_offset..][0..8], child_block);

        // Update generation and clear checksum
        writeU64LE(parent_buf[4..12], sb_generation + 1);
        writeU32LE(parent_buf[12..16], 0);

        const new_parent = allocBlock() orelse return null;
        if (!writeTreeNode(new_parent, &parent_buf)) {
            freeBlock(new_parent);
            return null;
        }
        _ = cacheInsert(new_parent, &parent_buf);
        freeBlock(pe.block);

        child_block = new_parent;
    }
    return child_block;
}

/// Advance to the next sibling leaf by walking up the path and descending
/// into the next child. Used by btreeScan for cross-leaf iteration.
fn advanceToNextLeaf(path: []PathEntry, path_len: *usize) ?u64 {
    while (path_len.* > 0) {
        path_len.* -= 1;
        const pe = path[path_len.*];

        // Can we advance to next child in this node?
        if (pe.child_idx < pe.num_keys) {
            const next_idx = pe.child_idx + 1;
            const node = readBlockCached(pe.block) orelse return null;
            const child = parseInternalChild(node, pe.num_keys, next_idx);
            if (child == 0) return null;

            // Update path entry with new child index
            path[path_len.*] = .{ .block = pe.block, .child_idx = next_idx, .num_keys = pe.num_keys };
            path_len.* += 1;

            // Descend to leftmost leaf from this child
            return descendToLeftmostLeaf(child, path, path_len);
        }
        // This node's children exhausted, pop up
    }
    return null;
}

/// Descend from `start_block` to the leftmost leaf, recording path entries.
fn descendToLeftmostLeaf(start_block: u64, path: []PathEntry, path_len: *usize) ?u64 {
    var block_nr = start_block;
    var depth: u8 = 0;
    while (depth < MAX_TREE_DEPTH) : (depth += 1) {
        const node = readBlockCached(block_nr) orelse return null;
        const level = parseNodeLevel(node);
        if (level == 0) return block_nr;

        const num_items = parseNodeNumItems(node);
        if (path_len.* >= path.len) return null;
        path[path_len.*] = .{ .block = block_nr, .child_idx = 0, .num_keys = num_items };
        path_len.* += 1;

        block_nr = parseInternalChild(node, num_items, 0);
        if (block_nr == 0) return null;
    }
    return null;
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
    const start_key = Key{ .inode_nr = inode_nr, .item_type = item_type, .offset = 0 };
    var count: u32 = 0;

    // Find starting leaf via path (supports multi-level trees)
    var path: [MAX_TREE_DEPTH]PathEntry = undefined;
    var path_len: usize = 0;
    var leaf_block_opt: ?u64 = findLeafPath(start_key, &path, &path_len);

    while (leaf_block_opt) |leaf_block| {
        const node = readBlockCached(leaf_block) orelse return count;
        const num_items = parseNodeNumItems(node);
        var past_range = false;

        var i: u16 = 0;
        while (i < num_items) : (i += 1) {
            const k = parseLeafItemKey(node, i);
            if (k.inode_nr == inode_nr and k.item_type == item_type) {
                const data = parseLeafItemData(node, i);
                callback(context, k, data);
                count += 1;
            } else if (k.inode_nr > inode_nr or (k.inode_nr == inode_nr and k.item_type > item_type)) {
                past_range = true;
                break;
            }
        }

        // If we hit a key past our range, or leaf is empty, we're done
        if (past_range or num_items == 0) break;

        // Items might continue in the next leaf — advance
        leaf_block_opt = advanceToNextLeaf(&path, &path_len);
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

    // Fast path: check EXTENT_DATA at offset 0 (handles inline + single extent)
    if (btreeSearch(.{ .inode_nr = inode_nr, .item_type = EXTENT_DATA, .offset = 0 })) |data| {
        if (data.len == EXTENT_DATA_SIZE and readU64LE(data[0..8]) > 0) {
            // Extent at offset 0
            const disk_block = readU64LE(data[0..8]);
            const num_blocks = readU32LE(data[8..12]);
            const ext_end: u64 = @as(u64, num_blocks) * BLOCK_SIZE;
            if (file_offset < ext_end) {
                const block_in_extent = file_offset / BLOCK_SIZE;
                const offset_in_block = file_offset % BLOCK_SIZE;
                const target_block = disk_block + block_in_extent;

                if (!readBlock(target_block, &read_data_buf)) return 0;

                const block_avail: u32 = @intCast(BLOCK_SIZE - offset_in_block);
                const to_copy = @min(want, block_avail);
                @memcpy(dest[0..to_copy], read_data_buf[@intCast(offset_in_block)..][0..to_copy]);
                return to_copy;
            }
            // file_offset beyond first extent — fall through to multi-extent scan
        } else {
            // Inline data: raw file content stored directly in B-tree leaf
            if (file_offset < data.len) {
                const avail: u32 = @intCast(data.len - file_offset);
                const to_copy = @min(want, avail);
                @memcpy(dest[0..to_copy], data[@intCast(file_offset)..][0..to_copy]);
                return to_copy;
            }
            return 0;
        }
    }

    // Multi-extent: scan all EXTENT_DATA items for this inode
    const Ctx = struct {
        file_offset: u64,
        dest: []u8,
        want: u32,
        result: u32,
    };
    var ctx = Ctx{ .file_offset = file_offset, .dest = dest, .want = want, .result = 0 };

    _ = btreeScan(inode_nr, EXTENT_DATA, &ctx, struct {
        fn cb(c: *Ctx, k: Key, data: []const u8) void {
            if (c.result > 0) return;
            if (data.len != EXTENT_DATA_SIZE) return;
            const disk_block = readU64LE(data[0..8]);
            if (disk_block == 0) return;
            const num_blocks = readU32LE(data[8..12]);
            const ext_start = k.offset;
            const ext_end = ext_start + @as(u64, num_blocks) * BLOCK_SIZE;
            if (c.file_offset >= ext_start and c.file_offset < ext_end) {
                const offset_in_extent = c.file_offset - ext_start;
                const block_in_extent = offset_in_extent / BLOCK_SIZE;
                const offset_in_block = offset_in_extent % BLOCK_SIZE;
                const target_block = disk_block + block_in_extent;

                if (!readBlock(target_block, &read_data_buf)) return;

                const block_avail: u32 = @intCast(BLOCK_SIZE - offset_in_block);
                const to_copy = @min(c.want, block_avail);
                @memcpy(c.dest[0..to_copy], read_data_buf[@intCast(offset_in_block)..][0..to_copy]);
                c.result = to_copy;
            }
        }
    }.cb);

    return ctx.result;
}

// ── Bitmap operations (multi-block) ───────────────────────────────
//
// One bitmap block covers BLOCK_SIZE*8 = 32768 blocks = 128 MB.
// For larger filesystems, the bitmap spans multiple consecutive blocks
// starting at sb_bitmap_start. We cache one bitmap block at a time.

const BITS_PER_BITMAP_BLOCK: u64 = BLOCK_SIZE * 8;

var bitmap_buf: [BLOCK_SIZE]u8 linksection(".bss") = undefined;
var bitmap_loaded: bool = false;
var bitmap_cached_idx: u64 = 0; // which bitmap block is cached (0-based)
var bitmap_dirty: bool = false;

/// Ensure the bitmap block covering `block_nr` is loaded into bitmap_buf.
fn ensureBitmapBlock(block_nr: u64) bool {
    const idx = block_nr / BITS_PER_BITMAP_BLOCK;
    if (bitmap_loaded and bitmap_cached_idx == idx) return true;
    // Flush current block if dirty
    if (bitmap_loaded and bitmap_dirty) {
        if (!writeBlock(sb_bitmap_start + bitmap_cached_idx, &bitmap_buf)) return false;
        bitmap_dirty = false;
    }
    // Load the needed bitmap block
    if (!readBlock(sb_bitmap_start + idx, &bitmap_buf)) return false;
    bitmap_cached_idx = idx;
    bitmap_loaded = true;
    return true;
}

fn isBitSet(block: u64) bool {
    if (!ensureBitmapBlock(block)) return true; // assume allocated on failure
    const local_bit = block % BITS_PER_BITMAP_BLOCK;
    const byte_idx = local_bit / 8;
    const bit_idx: u3 = @intCast(local_bit % 8);
    return (bitmap_buf[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
}

fn setBit(block: u64) void {
    if (!ensureBitmapBlock(block)) return;
    const local_bit = block % BITS_PER_BITMAP_BLOCK;
    const byte_idx = local_bit / 8;
    const bit_idx: u3 = @intCast(local_bit % 8);
    bitmap_buf[byte_idx] |= @as(u8, 1) << bit_idx;
    bitmap_dirty = true;
}

fn clearBit(block: u64) void {
    if (!ensureBitmapBlock(block)) return;
    const local_bit = block % BITS_PER_BITMAP_BLOCK;
    const byte_idx = local_bit / 8;
    const bit_idx: u3 = @intCast(local_bit % 8);
    bitmap_buf[byte_idx] &= ~(@as(u8, 1) << bit_idx);
    bitmap_dirty = true;
}

fn flushBitmap() bool {
    if (!bitmap_loaded or !bitmap_dirty) return true;
    if (!writeBlock(sb_bitmap_start + bitmap_cached_idx, &bitmap_buf)) return false;
    bitmap_dirty = false;
    return true;
}

fn allocBlock() ?u64 {
    // Start search from hint for O(1) sequential allocation
    const start = if (alloc_hint >= sb_data_start and alloc_hint < sb_total_blocks) alloc_hint else sb_data_start;
    var block: u64 = start;
    while (block < sb_total_blocks) : (block += 1) {
        if (!isBitSet(block)) {
            setBit(block);
            sb_free_blocks -%= 1;
            alloc_hint = block + 1;
            return block;
        }
    }
    // Wrap around from data_start to hint
    block = sb_data_start;
    while (block < start) : (block += 1) {
        if (!isBitSet(block)) {
            setBit(block);
            sb_free_blocks -%= 1;
            alloc_hint = block + 1;
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

/// Write a B-tree node block with CRC32 checksum at bytes 12-15.
fn writeTreeNode(block_nr: u64, buf: *[BLOCK_SIZE]u8) bool {
    // Compute CRC32 with checksum field zeroed
    writeU32LE(buf[12..16], 0);
    const cksum = crc32(buf);
    writeU32LE(buf[12..16], cksum);
    return writeBlock(block_nr, buf);
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

    if (!writeTreeNode(new_block, &new_data)) {
        freeBlock(new_block);
        return null;
    }

    // Insert into cache
    _ = cacheInsert(new_block, &new_data);

    return new_block;
}

/// Insert an item into the B-tree. Does CoW on modified nodes.
/// Returns true on success.
/// Build a leaf from a range of "combined items" (old leaf items + new item in sorted order).
/// Items from combined index range_start (inclusive) to range_end (exclusive) are written.
/// Returns the first key written (used as separator key for splits).
fn buildLeafRange(
    old_leaf: *const [BLOCK_SIZE]u8,
    old_num_items: u16,
    new_key: Key,
    new_data: []const u8,
    range_start: u16,
    range_end: u16,
    out_buf: *[BLOCK_SIZE]u8,
) Key {
    @memset(out_buf, 0);
    var data_cursor: usize = BLOCK_SIZE;
    var write_count: u16 = 0;
    var first_key: Key = undefined;

    var old_idx: u16 = 0;
    var combined_idx: u16 = 0;
    var new_inserted = false;
    const total_combined: u16 = old_num_items + 1;

    while (combined_idx < range_end and combined_idx < total_combined) {
        var use_new = false;
        if (!new_inserted) {
            if (old_idx >= old_num_items) {
                use_new = true;
            } else {
                const k = parseLeafItemKey(old_leaf, old_idx);
                if (new_key.lessThan(k)) {
                    use_new = true;
                }
            }
        }

        if (combined_idx >= range_start) {
            if (use_new) {
                data_cursor -= new_data.len;
                @memcpy(out_buf[data_cursor..][0..new_data.len], new_data);
                writeLeafItem(out_buf, write_count, new_key, @intCast(data_cursor), @intCast(new_data.len));
                if (write_count == 0) first_key = new_key;
                write_count += 1;
            } else {
                const k = parseLeafItemKey(old_leaf, old_idx);
                const d = parseLeafItemData(old_leaf, old_idx);
                data_cursor -= d.len;
                @memcpy(out_buf[data_cursor..][0..d.len], d);
                writeLeafItem(out_buf, write_count, k, @intCast(data_cursor), @intCast(d.len));
                if (write_count == 0) first_key = k;
                write_count += 1;
            }
        }

        if (use_new) {
            new_inserted = true;
        } else {
            old_idx += 1;
        }
        combined_idx += 1;
    }

    writeNodeHeader(out_buf, 0, write_count, sb_generation + 1);
    return first_key;
}

/// Build an internal node by inserting a separator key + right child at a split point.
fn buildInternalWithInsert(
    out_buf: *[BLOCK_SIZE]u8,
    old_buf: *const [BLOCK_SIZE]u8,
    level: u8,
    old_num_keys: u16,
    insert_at: u16,
    left_child: u64,
    sep_key: Key,
    right_child: u64,
) void {
    const new_num_keys = old_num_keys + 1;
    @memset(out_buf, 0);
    writeNodeHeader(out_buf, level, new_num_keys, sb_generation + 1);

    // Write keys
    var ki: u16 = 0;
    while (ki < new_num_keys) : (ki += 1) {
        if (ki < insert_at) {
            writeInternalKey(out_buf, ki, parseInternalKey(old_buf, ki));
        } else if (ki == insert_at) {
            writeInternalKey(out_buf, ki, sep_key);
        } else {
            writeInternalKey(out_buf, ki, parseInternalKey(old_buf, ki - 1));
        }
    }

    // Write children
    var ci: u16 = 0;
    while (ci <= new_num_keys) : (ci += 1) {
        if (ci < insert_at) {
            writeInternalChild(out_buf, new_num_keys, ci, parseInternalChild(old_buf, old_num_keys, ci));
        } else if (ci == insert_at) {
            writeInternalChild(out_buf, new_num_keys, ci, left_child);
        } else if (ci == insert_at + 1) {
            writeInternalChild(out_buf, new_num_keys, ci, right_child);
        } else {
            writeInternalChild(out_buf, new_num_keys, ci, parseInternalChild(old_buf, old_num_keys, ci - 1));
        }
    }
}

/// Split an internal node after inserting a separator key + right child.
/// Returns the middle key (pushed up to parent) via pushed_sep.
fn splitInternalWithInsert(
    left_buf: *[BLOCK_SIZE]u8,
    right_buf: *[BLOCK_SIZE]u8,
    pushed_sep: *Key,
    old_buf: *const [BLOCK_SIZE]u8,
    level: u8,
    old_num_keys: u16,
    insert_at: u16,
    left_child: u64,
    sep_key: Key,
    right_child: u64,
) void {
    const total_keys: u16 = old_num_keys + 1;

    // Collect all keys and children into arrays
    var all_keys: [MAX_INTERNAL_KEYS + 1]Key = undefined;
    var all_children: [MAX_INTERNAL_KEYS + 2]u64 = undefined;

    var ki: u16 = 0;
    while (ki < total_keys) : (ki += 1) {
        if (ki < insert_at) {
            all_keys[ki] = parseInternalKey(old_buf, ki);
        } else if (ki == insert_at) {
            all_keys[ki] = sep_key;
        } else {
            all_keys[ki] = parseInternalKey(old_buf, ki - 1);
        }
    }

    var ci: u16 = 0;
    while (ci <= total_keys) : (ci += 1) {
        if (ci < insert_at) {
            all_children[ci] = parseInternalChild(old_buf, old_num_keys, ci);
        } else if (ci == insert_at) {
            all_children[ci] = left_child;
        } else if (ci == insert_at + 1) {
            all_children[ci] = right_child;
        } else {
            all_children[ci] = parseInternalChild(old_buf, old_num_keys, ci - 1);
        }
    }

    // Split: left gets [0..mid), pushed_sep = keys[mid], right gets [mid+1..total_keys)
    const mid: u16 = total_keys / 2;
    pushed_sep.* = all_keys[mid];

    // Build left internal node
    const left_keys: u16 = mid;
    @memset(left_buf, 0);
    writeNodeHeader(left_buf, level, left_keys, sb_generation + 1);
    var i: u16 = 0;
    while (i < left_keys) : (i += 1) {
        writeInternalKey(left_buf, i, all_keys[i]);
    }
    i = 0;
    while (i <= left_keys) : (i += 1) {
        writeInternalChild(left_buf, left_keys, i, all_children[i]);
    }

    // Build right internal node
    const right_keys: u16 = total_keys - mid - 1;
    @memset(right_buf, 0);
    writeNodeHeader(right_buf, level, right_keys, sb_generation + 1);
    i = 0;
    while (i < right_keys) : (i += 1) {
        writeInternalKey(right_buf, i, all_keys[mid + 1 + i]);
    }
    i = 0;
    while (i <= right_keys) : (i += 1) {
        writeInternalChild(right_buf, right_keys, i, all_children[mid + 1 + i]);
    }
}

/// CoW path with split propagation. When a leaf or internal node was split,
/// propagates the split upward, potentially splitting parent nodes too.
/// If the split reaches the root, creates a new root node.
fn cowPathWithSplit(path: []const PathEntry, path_len: usize, new_left: u64, sep_key: Key, new_right: u64) ?u64 {
    var carry_left = new_left;
    var carry_sep = sep_key;
    var carry_right = new_right;
    var has_split = true;

    var p = path_len;
    while (p > 0) {
        p -= 1;
        const pe = path[p];

        var parent_buf: [BLOCK_SIZE]u8 = undefined;
        {
            const cached = readBlockCached(pe.block) orelse return null;
            @memcpy(&parent_buf, cached);
        }
        const parent_level = parseNodeLevel(&parent_buf);

        if (has_split) {
            const old_num_keys = pe.num_keys;
            const new_num_keys = old_num_keys + 1;
            const space_needed = NODE_HEADER_SIZE + @as(usize, new_num_keys) * 17 + @as(usize, new_num_keys + 1) * 8;

            if (space_needed <= BLOCK_SIZE) {
                // Fits — build new parent with inserted key + child
                var new_parent: [BLOCK_SIZE]u8 = undefined;
                buildInternalWithInsert(&new_parent, &parent_buf, parent_level, old_num_keys, pe.child_idx, carry_left, carry_sep, carry_right);

                const new_block = allocBlock() orelse return null;
                if (!writeTreeNode(new_block, &new_parent)) {
                    freeBlock(new_block);
                    return null;
                }
                _ = cacheInsert(new_block, &new_parent);
                freeBlock(pe.block);

                carry_left = new_block;
                has_split = false;
            } else {
                // Parent needs to split too
                var left_internal: [BLOCK_SIZE]u8 = undefined;
                var right_internal: [BLOCK_SIZE]u8 = undefined;
                var pushed_sep: Key = undefined;

                splitInternalWithInsert(&left_internal, &right_internal, &pushed_sep, &parent_buf, parent_level, pe.num_keys, pe.child_idx, carry_left, carry_sep, carry_right);

                const left_block = allocBlock() orelse return null;
                if (!writeTreeNode(left_block, &left_internal)) {
                    freeBlock(left_block);
                    return null;
                }
                _ = cacheInsert(left_block, &left_internal);

                const right_block = allocBlock() orelse return null;
                if (!writeTreeNode(right_block, &right_internal)) {
                    freeBlock(right_block);
                    freeBlock(left_block);
                    return null;
                }
                _ = cacheInsert(right_block, &right_internal);

                freeBlock(pe.block);

                carry_left = left_block;
                carry_sep = pushed_sep;
                carry_right = right_block;
            }
        } else {
            // Normal CoW — just update child pointer
            const children_base = NODE_HEADER_SIZE + @as(usize, pe.num_keys) * 17;
            const child_offset = children_base + @as(usize, pe.child_idx) * 8;
            writeU64LE(parent_buf[child_offset..][0..8], carry_left);

            writeU64LE(parent_buf[4..12], sb_generation + 1);
            writeU32LE(parent_buf[12..16], 0);

            const new_block = allocBlock() orelse return null;
            if (!writeTreeNode(new_block, &parent_buf)) {
                freeBlock(new_block);
                return null;
            }
            _ = cacheInsert(new_block, &parent_buf);
            freeBlock(pe.block);

            carry_left = new_block;
        }
    }

    if (has_split) {
        // Root was split — create new root
        const child_node = readBlockCached(carry_left) orelse return null;
        const child_level = parseNodeLevel(child_node);
        const new_root_level: u8 = child_level + 1;

        var root_buf: [BLOCK_SIZE]u8 = [_]u8{0} ** BLOCK_SIZE;
        writeNodeHeader(&root_buf, new_root_level, 1, sb_generation + 1);
        writeInternalKey(&root_buf, 0, carry_sep);
        writeInternalChild(&root_buf, 1, 0, carry_left);
        writeInternalChild(&root_buf, 1, 1, carry_right);

        const new_root = allocBlock() orelse return null;
        if (!writeTreeNode(new_root, &root_buf)) {
            freeBlock(new_root);
            return null;
        }
        _ = cacheInsert(new_root, &root_buf);
        return new_root;
    }

    return carry_left;
}

fn btreeInsert(key: Key, data: []const u8) bool {
    const root = readBlockCached(sb_tree_root) orelse return false;
    const level = parseNodeLevel(root);

    if (level == 0) {
        // Single leaf tree — use existing logic
        return leafInsert(sb_tree_root, key, data);
    }

    // Multi-level tree: find leaf via path, insert with possible split
    var path: [MAX_TREE_DEPTH]PathEntry = undefined;
    var path_len: usize = 0;
    const leaf_block = findLeafPath(key, &path, &path_len) orelse return false;

    // Copy old leaf locally to survive cache invalidation during splits
    var old_leaf: [BLOCK_SIZE]u8 = undefined;
    {
        const cached = readBlockCached(leaf_block) orelse return false;
        @memcpy(&old_leaf, cached);
    }
    const num_items = parseNodeNumItems(&old_leaf);

    // Check if items fit in a single leaf
    var total_data: usize = data.len;
    {
        var i: u16 = 0;
        while (i < num_items) : (i += 1) {
            total_data += parseLeafItemDataSize(&old_leaf, i);
        }
    }
    const total_items: u16 = num_items + 1;
    const header_end = NODE_HEADER_SIZE + @as(usize, total_items) * LEAF_ITEM_HEADER_SIZE;

    if (header_end + total_data <= BLOCK_SIZE) {
        // Fits in single leaf — build directly
        var new_buf: [BLOCK_SIZE]u8 = [_]u8{0} ** BLOCK_SIZE;
        var data_cursor: usize = BLOCK_SIZE;
        var new_count: u16 = 0;
        var inserted = false;

        var i: u16 = 0;
        while (i < num_items) : (i += 1) {
            const k = parseLeafItemKey(&old_leaf, i);
            if (!inserted and key.lessThan(k)) {
                data_cursor -= data.len;
                @memcpy(new_buf[data_cursor..][0..data.len], data);
                writeLeafItem(&new_buf, new_count, key, @intCast(data_cursor), @intCast(data.len));
                new_count += 1;
                inserted = true;
            }
            const old_data = parseLeafItemData(&old_leaf, i);
            data_cursor -= old_data.len;
            @memcpy(new_buf[data_cursor..][0..old_data.len], old_data);
            writeLeafItem(&new_buf, new_count, k, @intCast(data_cursor), @intCast(old_data.len));
            new_count += 1;
        }
        if (!inserted) {
            data_cursor -= data.len;
            @memcpy(new_buf[data_cursor..][0..data.len], data);
            writeLeafItem(&new_buf, new_count, key, @intCast(data_cursor), @intCast(data.len));
            new_count += 1;
        }

        writeNodeHeader(&new_buf, 0, new_count, sb_generation + 1);

        const new_block = allocBlock() orelse return false;
        if (!writeTreeNode(new_block, &new_buf)) {
            freeBlock(new_block);
            return false;
        }
        _ = cacheInsert(new_block, &new_buf);
        freeBlock(leaf_block);

        // CoW the path back to root
        const new_root = cowPath(&path, path_len, new_block) orelse return false;
        sb_tree_root = new_root;
        return true;
    }

    // Leaf overflow — split into two halves
    const split_at = total_items / 2;

    var left_buf: [BLOCK_SIZE]u8 = undefined;
    _ = buildLeafRange(&old_leaf, num_items, key, data, 0, split_at, &left_buf);

    var right_buf: [BLOCK_SIZE]u8 = undefined;
    const separator = buildLeafRange(&old_leaf, num_items, key, data, split_at, total_items, &right_buf);

    const left_block = allocBlock() orelse return false;
    if (!writeTreeNode(left_block, &left_buf)) {
        freeBlock(left_block);
        return false;
    }
    _ = cacheInsert(left_block, &left_buf);

    const right_block = allocBlock() orelse return false;
    if (!writeTreeNode(right_block, &right_buf)) {
        freeBlock(right_block);
        freeBlock(left_block);
        return false;
    }
    _ = cacheInsert(right_block, &right_buf);

    freeBlock(leaf_block);

    // Propagate split up via cowPathWithSplit
    const new_root = cowPathWithSplit(&path, path_len, left_block, separator, right_block) orelse return false;
    sb_tree_root = new_root;
    return true;
}

fn leafInsert(leaf_block: u64, key: Key, data: []const u8) bool {
    // Copy old leaf locally to survive cache invalidation during splits
    var old_leaf: [BLOCK_SIZE]u8 = undefined;
    {
        const cached = readBlockCached(leaf_block) orelse return false;
        @memcpy(&old_leaf, cached);
    }
    const num_items = parseNodeNumItems(&old_leaf);

    // Check if items fit in a single leaf
    var total_data: usize = data.len;
    {
        var i: u16 = 0;
        while (i < num_items) : (i += 1) {
            total_data += parseLeafItemDataSize(&old_leaf, i);
        }
    }
    const total_items: u16 = num_items + 1;
    const header_end = NODE_HEADER_SIZE + @as(usize, total_items) * LEAF_ITEM_HEADER_SIZE;

    if (header_end + total_data <= BLOCK_SIZE) {
        // Fits in single leaf — build directly
        var new_buf: [BLOCK_SIZE]u8 = [_]u8{0} ** BLOCK_SIZE;
        var data_cursor: usize = BLOCK_SIZE;
        var new_count: u16 = 0;
        var inserted = false;

        var i: u16 = 0;
        while (i < num_items) : (i += 1) {
            const k = parseLeafItemKey(&old_leaf, i);
            if (!inserted and key.lessThan(k)) {
                data_cursor -= data.len;
                @memcpy(new_buf[data_cursor..][0..data.len], data);
                writeLeafItem(&new_buf, new_count, key, @intCast(data_cursor), @intCast(data.len));
                new_count += 1;
                inserted = true;
            }
            const old_data = parseLeafItemData(&old_leaf, i);
            data_cursor -= old_data.len;
            @memcpy(new_buf[data_cursor..][0..old_data.len], old_data);
            writeLeafItem(&new_buf, new_count, k, @intCast(data_cursor), @intCast(old_data.len));
            new_count += 1;
        }
        if (!inserted) {
            data_cursor -= data.len;
            @memcpy(new_buf[data_cursor..][0..data.len], data);
            writeLeafItem(&new_buf, new_count, key, @intCast(data_cursor), @intCast(data.len));
            new_count += 1;
        }

        writeNodeHeader(&new_buf, 0, new_count, sb_generation + 1);

        const new_block = allocBlock() orelse return false;
        if (!writeTreeNode(new_block, &new_buf)) {
            freeBlock(new_block);
            return false;
        }
        _ = cacheInsert(new_block, &new_buf);
        freeBlock(leaf_block);
        sb_tree_root = new_block;
        return true;
    }

    // Leaf overflow — split into two halves, create new internal root
    const split_at = total_items / 2;

    var left_buf: [BLOCK_SIZE]u8 = undefined;
    _ = buildLeafRange(&old_leaf, num_items, key, data, 0, split_at, &left_buf);

    var right_buf: [BLOCK_SIZE]u8 = undefined;
    const separator = buildLeafRange(&old_leaf, num_items, key, data, split_at, total_items, &right_buf);

    const left_block = allocBlock() orelse return false;
    if (!writeTreeNode(left_block, &left_buf)) {
        freeBlock(left_block);
        return false;
    }
    _ = cacheInsert(left_block, &left_buf);

    const right_block = allocBlock() orelse return false;
    if (!writeTreeNode(right_block, &right_buf)) {
        freeBlock(right_block);
        freeBlock(left_block);
        return false;
    }
    _ = cacheInsert(right_block, &right_buf);

    freeBlock(leaf_block);

    // Create new internal root (level 1)
    var root_buf: [BLOCK_SIZE]u8 = [_]u8{0} ** BLOCK_SIZE;
    writeNodeHeader(&root_buf, 1, 1, sb_generation + 1);
    writeInternalKey(&root_buf, 0, separator);
    writeInternalChild(&root_buf, 1, 0, left_block);
    writeInternalChild(&root_buf, 1, 1, right_block);

    const new_root = allocBlock() orelse return false;
    if (!writeTreeNode(new_root, &root_buf)) {
        freeBlock(new_root);
        return false;
    }
    _ = cacheInsert(new_root, &root_buf);

    sb_tree_root = new_root;
    return true;
}

/// Delete an item from the B-tree by key. Returns true on success.
fn btreeDelete(key: Key) bool {
    const root = readBlockCached(sb_tree_root) orelse return false;
    const level = parseNodeLevel(root);

    if (level == 0) {
        return leafDelete(sb_tree_root, key);
    }

    // Multi-level tree: find leaf via path, delete, CoW path
    var path: [MAX_TREE_DEPTH]PathEntry = undefined;
    var path_len: usize = 0;
    const leaf_block = findLeafPath(key, &path, &path_len) orelse return false;

    // Delete from leaf (CoW)
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
            continue;
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
    if (!writeTreeNode(new_block, &new_buf)) {
        freeBlock(new_block);
        return false;
    }
    _ = cacheInsert(new_block, &new_buf);
    freeBlock(leaf_block);

    // CoW the path back to root
    const new_root = cowPath(&path, path_len, new_block) orelse return false;
    sb_tree_root = new_root;
    return true;
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
    if (!writeTreeNode(new_block, &new_buf)) {
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

/// Protects all B-tree, bitmap, superblock, cache, and IO buffer state.
var fs_lock: Mutex = .{};
/// Protects the handles[] array.
var handle_lock: Mutex = .{};

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

/// Free all extent data blocks and delete all EXTENT_DATA B-tree items for an inode.
fn freeAllExtents(inode_nr: u64) void {
    // First pass: free data blocks and collect keys to delete
    const Ctx = struct {
        keys: [32]Key,
        count: usize,
    };
    var ctx = Ctx{ .keys = undefined, .count = 0 };

    _ = btreeScan(inode_nr, EXTENT_DATA, &ctx, struct {
        fn cb(c: *Ctx, k: Key, data: []const u8) void {
            // Free data blocks if this is an extent reference (not inline)
            if (data.len == EXTENT_DATA_SIZE) {
                const disk_block = readU64LE(data[0..8]);
                const num_blocks = readU32LE(data[8..12]);
                if (disk_block != 0) {
                    var b: u64 = 0;
                    while (b < num_blocks) : (b += 1) {
                        freeBlock(disk_block + b);
                    }
                }
            }
            if (c.count < 32) {
                c.keys[c.count] = k;
                c.count += 1;
            }
        }
    }.cb);

    // Second pass: delete B-tree items
    var i: usize = 0;
    while (i < ctx.count) : (i += 1) {
        _ = btreeDelete(ctx.keys[i]);
    }
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
    writeU64LE(resp.data[8..16], inode.mtime);
    writeU64LE(resp.data[16..24], inode.ctime);
    writeU32LE(resp.data[24..28], @as(u32, inode.mode));
    writeU16LE(resp.data[28..30], inode.uid);
    writeU16LE(resp.data[30..32], inode.gid);
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
    const is_append = (flags & 2) != 0;

    // Check if already exists
    if (resolvePath(path)) |existing| {
        var offset: u64 = 0;
        if (is_append) {
            if (readInode(existing)) |inode| {
                offset = inode.size;
            }
        }
        const handle = allocHandleAt(existing, offset) orelse {
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
    const now = getTime();
    writeU64LE(inode_data[16..24], now); // atime
    writeU64LE(inode_data[24..32], now); // mtime
    writeU64LE(inode_data[32..40], now); // ctime

    if (!btreeInsert(.{ .inode_nr = new_inode, .item_type = INODE_ITEM, .offset = 0 }, &inode_data)) {
        _ = fx.write(1, "fxfs: INODE_ITEM insert failed\n");
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
        _ = fx.write(1, "fxfs: DIR_ENTRY insert failed\n");
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

/// Allocate blocks for `data`, write them, and insert extent entries starting at `file_offset`.
fn appendBlocks(inode_nr: u64, file_offset: u64, data: []const u8) bool {
    if (data.len == 0) return true;

    const num_blocks = (data.len + BLOCK_SIZE - 1) / BLOCK_SIZE;
    const MAX_RUNS = 32;
    const RunInfo = struct { start: u64, count: u32 };
    var runs: [MAX_RUNS]RunInfo = undefined;
    var num_runs: usize = 0;
    var total_allocated: usize = 0;

    while (total_allocated < num_blocks) {
        const block = allocBlock() orelse {
            for (runs[0..num_runs]) |run| {
                var f: u32 = 0;
                while (f < run.count) : (f += 1) {
                    freeBlock(run.start + f);
                }
            }
            return false;
        };

        if (num_runs == 0 or block != runs[num_runs - 1].start + runs[num_runs - 1].count) {
            if (num_runs >= MAX_RUNS) {
                freeBlock(block);
                for (runs[0..num_runs]) |run| {
                    var f: u32 = 0;
                    while (f < run.count) : (f += 1) {
                        freeBlock(run.start + f);
                    }
                }
                return false;
            }
            runs[num_runs] = .{ .start = block, .count = 1 };
            num_runs += 1;
        } else {
            runs[num_runs - 1].count += 1;
        }
        total_allocated += 1;
    }

    // Write data to blocks
    var block_buf: [BLOCK_SIZE]u8 = [_]u8{0} ** BLOCK_SIZE;
    var data_pos: usize = 0;
    var block_idx: usize = 0;
    for (runs[0..num_runs]) |run| {
        var r: u32 = 0;
        while (r < run.count) : (r += 1) {
            @memset(&block_buf, 0);
            if (data_pos < data.len) {
                const remaining = data.len - data_pos;
                const to_copy = @min(remaining, BLOCK_SIZE);
                @memcpy(block_buf[0..to_copy], data[data_pos..][0..to_copy]);
                data_pos += to_copy;
            }
            if (!writeBlock(run.start + r, &block_buf)) return false;
            block_idx += 1;
        }
    }

    // Insert extent entries
    var ext_offset: u64 = file_offset;
    for (runs[0..num_runs]) |run| {
        var extent_data: [EXTENT_DATA_SIZE]u8 = undefined;
        writeU64LE(extent_data[0..8], run.start);
        writeU32LE(extent_data[8..12], run.count);
        writeU32LE(extent_data[12..16], 0);
        if (!btreeInsert(.{ .inode_nr = inode_nr, .item_type = EXTENT_DATA, .offset = ext_offset }, &extent_data)) {
            return false;
        }
        ext_offset += @as(u64, run.count) * BLOCK_SIZE;
    }

    return true;
}

/// Free a single extent at the given file offset (for CoW replacement of partial blocks).
fn freeExtentAt(inode_nr: u64, file_offset: u64) void {
    const key = Key{ .inode_nr = inode_nr, .item_type = EXTENT_DATA, .offset = file_offset };
    if (btreeSearch(key)) |data| {
        if (data.len == EXTENT_DATA_SIZE) {
            const disk_block = readU64LE(data[0..8]);
            const num_blocks = readU32LE(data[8..12]);
            if (disk_block > 0) {
                var i: u32 = 0;
                while (i < num_blocks) : (i += 1) {
                    freeBlock(disk_block + i);
                }
            }
        }
        _ = btreeDelete(key);
    }
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
    const old_size: usize = @intCast(inode.size);

    // For small files, store inline in the B-tree
    if (new_end <= 3800) {
        // Build combined buffer: preserve existing data, place new data at write_offset
        var combined: [3800]u8 = [_]u8{0} ** 3800;

        // Read existing inline data before tree modification (btreeSearch returns
        // a slice into a cached block buffer that gets invalidated by btreeDelete)
        if (write_offset > 0) {
            if (btreeSearch(.{ .inode_nr = h.inode_nr, .item_type = EXTENT_DATA, .offset = 0 })) |existing| {
                const is_extent = existing.len == EXTENT_DATA_SIZE and readU64LE(existing[0..8]) > 0;
                if (!is_extent) {
                    const copy_len = @min(existing.len, write_offset);
                    @memcpy(combined[0..copy_len], existing[0..copy_len]);
                }
            }
        }

        // Place new data at write_offset
        @memcpy(combined[write_offset..][0..write_data.len], write_data);

        // Delete all old extent data
        freeAllExtents(h.inode_nr);

        // Insert combined inline data
        if (!btreeInsert(.{ .inode_nr = h.inode_nr, .item_type = EXTENT_DATA, .offset = 0 }, combined[0..new_end])) {
            resp.* = fx.IpcMessage.init(fx.R_ERROR);
            return;
        }
    } else if (write_offset >= old_size) {
        // Append path: write_offset is at or past end of file.
        // Don't rewrite old blocks — just handle the partial last block and add new blocks.

        // If transitioning from inline to block-based, convert first
        if (old_size > 0 and old_size <= 3800) {
            // Read old inline data
            var inline_buf: [3800]u8 = [_]u8{0} ** 3800;
            var inline_len: usize = 0;
            if (btreeSearch(.{ .inode_nr = h.inode_nr, .item_type = EXTENT_DATA, .offset = 0 })) |data| {
                const is_extent = data.len == EXTENT_DATA_SIZE and readU64LE(data[0..8]) > 0;
                if (!is_extent) {
                    inline_len = data.len;
                    @memcpy(inline_buf[0..inline_len], data);
                }
            }

            // Free inline extent
            freeAllExtents(h.inode_nr);

            // Allocate block for old inline data + whatever new data fits
            const first_block = allocBlock() orelse {
                resp.* = fx.IpcMessage.init(fx.R_ERROR);
                return;
            };

            var block_buf: [BLOCK_SIZE]u8 = [_]u8{0} ** BLOCK_SIZE;
            // Copy old inline data
            if (inline_len > 0) {
                @memcpy(block_buf[0..inline_len], inline_buf[0..inline_len]);
            }
            // Copy new data that fits in the first block
            if (write_offset < BLOCK_SIZE) {
                const space = BLOCK_SIZE - write_offset;
                const to_copy = @min(space, write_data.len);
                @memcpy(block_buf[write_offset..][0..to_copy], write_data[0..to_copy]);
            }

            if (!writeBlock(first_block, &block_buf)) {
                freeBlock(first_block);
                resp.* = fx.IpcMessage.init(fx.R_ERROR);
                return;
            }

            // Insert extent for first block
            var extent_data: [EXTENT_DATA_SIZE]u8 = undefined;
            writeU64LE(extent_data[0..8], first_block);
            writeU32LE(extent_data[8..12], 1);
            writeU32LE(extent_data[12..16], 0);
            if (!btreeInsert(.{ .inode_nr = h.inode_nr, .item_type = EXTENT_DATA, .offset = 0 }, &extent_data)) {
                resp.* = fx.IpcMessage.init(fx.R_ERROR);
                return;
            }

            // If new data extends beyond first block, handle remaining below
            if (new_end > BLOCK_SIZE) {
                const remaining_offset = BLOCK_SIZE - write_offset;
                if (remaining_offset < write_data.len) {
                    const remaining_data = write_data[remaining_offset..];
                    if (!appendBlocks(h.inode_nr, BLOCK_SIZE, remaining_data)) {
                        resp.* = fx.IpcMessage.init(fx.R_ERROR);
                        return;
                    }
                }
            }
        } else {
            // Already block-based — handle partial last block + append new blocks
            const last_block_offset = (write_offset / BLOCK_SIZE) * BLOCK_SIZE;
            const offset_in_block = write_offset % BLOCK_SIZE;

            if (offset_in_block > 0) {
                // Partial last block: read it, overlay new data, write as new block (CoW)
                var block_buf: [BLOCK_SIZE]u8 = [_]u8{0} ** BLOCK_SIZE;
                _ = readFileData(h.inode_nr, @intCast(last_block_offset), &block_buf);

                const space = BLOCK_SIZE - offset_in_block;
                const to_copy = @min(space, write_data.len);
                @memcpy(block_buf[offset_in_block..][0..to_copy], write_data[0..to_copy]);

                const new_block = allocBlock() orelse {
                    resp.* = fx.IpcMessage.init(fx.R_ERROR);
                    return;
                };
                if (!writeBlock(new_block, &block_buf)) {
                    freeBlock(new_block);
                    resp.* = fx.IpcMessage.init(fx.R_ERROR);
                    return;
                }

                // Replace the extent entry for this block position
                // Find and delete old extent covering this offset, insert new one
                freeExtentAt(h.inode_nr, @intCast(last_block_offset));

                var extent_data: [EXTENT_DATA_SIZE]u8 = undefined;
                writeU64LE(extent_data[0..8], new_block);
                writeU32LE(extent_data[8..12], 1);
                writeU32LE(extent_data[12..16], 0);
                if (!btreeInsert(.{ .inode_nr = h.inode_nr, .item_type = EXTENT_DATA, .offset = @intCast(last_block_offset) }, &extent_data)) {
                    resp.* = fx.IpcMessage.init(fx.R_ERROR);
                    return;
                }

                // Append remaining data as new blocks
                if (to_copy < write_data.len) {
                    const next_offset = last_block_offset + BLOCK_SIZE;
                    if (!appendBlocks(h.inode_nr, @intCast(next_offset), write_data[to_copy..])) {
                        resp.* = fx.IpcMessage.init(fx.R_ERROR);
                        return;
                    }
                }
            } else {
                // write_offset is block-aligned — just append new blocks
                if (!appendBlocks(h.inode_nr, @intCast(write_offset), write_data)) {
                    resp.* = fx.IpcMessage.init(fx.R_ERROR);
                    return;
                }
            }
        }
    } else {
        // General overwrite path: rewrite entire file (rare case)
        // Save old inline data if applicable
        var inline_buf: [3800]u8 = [_]u8{0} ** 3800;
        var was_inline = false;
        if (old_size > 0 and old_size <= 3800) {
            if (btreeSearch(.{ .inode_nr = h.inode_nr, .item_type = EXTENT_DATA, .offset = 0 })) |data| {
                const is_extent = data.len == EXTENT_DATA_SIZE and readU64LE(data[0..8]) > 0;
                if (!is_extent) {
                    @memcpy(inline_buf[0..data.len], data);
                    was_inline = true;
                }
            }
        }

        const num_blocks = (new_end + BLOCK_SIZE - 1) / BLOCK_SIZE;
        const MAX_RUNS = 32;
        const RunInfo = struct { start: u64, count: u32 };
        var runs: [MAX_RUNS]RunInfo = undefined;
        var num_runs: usize = 0;
        var total_allocated: usize = 0;

        while (total_allocated < num_blocks) {
            const block = allocBlock() orelse {
                for (runs[0..num_runs]) |run| {
                    var f: u32 = 0;
                    while (f < run.count) : (f += 1) {
                        freeBlock(run.start + f);
                    }
                }
                resp.* = fx.IpcMessage.init(fx.R_ERROR);
                return;
            };

            if (num_runs == 0 or block != runs[num_runs - 1].start + runs[num_runs - 1].count) {
                if (num_runs >= MAX_RUNS) {
                    freeBlock(block);
                    for (runs[0..num_runs]) |run| {
                        var f: u32 = 0;
                        while (f < run.count) : (f += 1) {
                            freeBlock(run.start + f);
                        }
                    }
                    resp.* = fx.IpcMessage.init(fx.R_ERROR);
                    return;
                }
                runs[num_runs] = .{ .start = block, .count = 1 };
                num_runs += 1;
            } else {
                runs[num_runs - 1].count += 1;
            }
            total_allocated += 1;
        }

        // Write blocks with old + new data merged
        var block_buf: [BLOCK_SIZE]u8 = [_]u8{0} ** BLOCK_SIZE;
        var block_idx: usize = 0;
        for (runs[0..num_runs]) |run| {
            var r: u32 = 0;
            while (r < run.count) : (r += 1) {
                @memset(&block_buf, 0);
                const blk_start = block_idx * BLOCK_SIZE;

                if (blk_start < old_size) {
                    if (was_inline) {
                        const avail = old_size - blk_start;
                        const to_copy = @min(avail, BLOCK_SIZE);
                        @memcpy(block_buf[0..to_copy], inline_buf[blk_start..][0..to_copy]);
                    } else if (old_size > 3800) {
                        _ = readFileData(h.inode_nr, @intCast(blk_start), &block_buf);
                    }
                }

                if (blk_start + BLOCK_SIZE > write_offset and blk_start < new_end) {
                    const buf_start = if (write_offset > blk_start) write_offset - blk_start else 0;
                    const data_start = if (blk_start > write_offset) blk_start - write_offset else 0;
                    if (data_start < write_data.len) {
                        const remaining = write_data.len - data_start;
                        const space = BLOCK_SIZE - buf_start;
                        const to_copy = @min(remaining, space);
                        @memcpy(block_buf[buf_start..][0..to_copy], write_data[data_start..][0..to_copy]);
                    }
                }

                if (!writeBlock(run.start + r, &block_buf)) {
                    resp.* = fx.IpcMessage.init(fx.R_ERROR);
                    return;
                }
                block_idx += 1;
            }
        }

        freeAllExtents(h.inode_nr);

        var file_offset: u64 = 0;
        for (runs[0..num_runs]) |run| {
            var extent_data: [EXTENT_DATA_SIZE]u8 = undefined;
            writeU64LE(extent_data[0..8], run.start);
            writeU32LE(extent_data[8..12], run.count);
            writeU32LE(extent_data[12..16], 0);

            if (!btreeInsert(.{ .inode_nr = h.inode_nr, .item_type = EXTENT_DATA, .offset = file_offset }, &extent_data)) {
                resp.* = fx.IpcMessage.init(fx.R_ERROR);
                return;
            }
            file_offset += @as(u64, run.count) * BLOCK_SIZE;
        }
    }

    // Update inode size + mtime
    var inode_data: [INODE_ITEM_SIZE]u8 = undefined;
    writeU16LE(inode_data[0..2], inode.mode);
    writeU16LE(inode_data[2..4], inode.uid);
    writeU16LE(inode_data[4..6], inode.gid);
    writeU16LE(inode_data[6..8], inode.nlinks);
    writeU64LE(inode_data[8..16], new_size);
    writeU64LE(inode_data[16..24], inode.atime);
    writeU64LE(inode_data[24..32], getTime()); // mtime
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

    // Check if directory is non-empty
    const inode = readInode(inode_nr) orelse {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };
    if (isDirectory(inode)) {
        // Scan for any DIR_ENTRY items — refuse removal if any exist
        const count = btreeScan(inode_nr, DIR_ENTRY, {}, struct {
            fn cb(_: void, _: Key, _: []const u8) void {}
        }.cb);
        if (count > 0) {
            resp.* = fx.IpcMessage.init(fx.R_ERROR);
            return;
        }
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

    // Free all extent data blocks and delete all EXTENT_DATA items
    freeAllExtents(inode_nr);

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
fn handleRename(req: *fx.IpcMessage, resp: *fx.IpcMessage) void {
    // Data format: old_path \0 new_path
    const data = req.data[0..req.data_len];

    // Find the \0 separator
    var sep: ?usize = null;
    for (data, 0..) |c, i_| {
        if (c == 0) {
            sep = i_;
            break;
        }
    }
    const separator = sep orelse {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    const old_path = data[0..separator];
    const new_path = data[separator + 1 ..];

    if (old_path.len == 0 or new_path.len == 0) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }

    // Resolve old path to get the inode
    const inode_nr = resolvePath(old_path) orelse {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    // Don't rename root
    if (inode_nr == 1) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }

    // Get old parent + name
    var old_parent: u64 = 1;
    var old_name: []const u8 = old_path;
    {
        var last_slash: ?usize = null;
        for (old_path, 0..) |c, i_| {
            if (c == '/') last_slash = i_;
        }
        if (last_slash) |slash| {
            old_parent = resolvePath(old_path[0..slash]) orelse {
                resp.* = fx.IpcMessage.init(fx.R_ERROR);
                return;
            };
            old_name = old_path[slash + 1 ..];
        }
    }

    // Get new parent + name
    var new_parent: u64 = 1;
    var new_name: []const u8 = new_path;
    {
        var last_slash: ?usize = null;
        for (new_path, 0..) |c, i_| {
            if (c == '/') last_slash = i_;
        }
        if (last_slash) |slash| {
            new_parent = resolvePath(new_path[0..slash]) orelse {
                resp.* = fx.IpcMessage.init(fx.R_ERROR);
                return;
            };
            new_name = new_path[slash + 1 ..];
        }
    }

    if (new_name.len == 0 or new_name.len > MAX_NAME) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }

    // If target exists, remove it first (POSIX rename semantics)
    if (resolvePath(new_path)) |existing| {
        if (existing != inode_nr) {
            // Remove the existing target's DIR_ENTRY
            const existing_hash = fnvHash(new_name);
            _ = btreeDelete(.{ .inode_nr = new_parent, .item_type = DIR_ENTRY, .offset = existing_hash });
            // Free its data and inode
            freeAllExtents(existing);
            _ = btreeDelete(.{ .inode_nr = existing, .item_type = INODE_ITEM, .offset = 0 });
        }
    }

    // Delete old DIR_ENTRY
    const old_hash = fnvHash(old_name);
    _ = btreeDelete(.{ .inode_nr = old_parent, .item_type = DIR_ENTRY, .offset = old_hash });

    // Read inode to get file type for DIR_ENTRY
    const inode = readInode(inode_nr) orelse {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    // Insert new DIR_ENTRY
    const new_hash = fnvHash(new_name);
    var dir_data: [266]u8 = undefined;
    writeU64LE(dir_data[0..8], inode_nr);
    dir_data[8] = if (isDirectory(inode)) DT_DIR else DT_REG;
    dir_data[9] = @intCast(new_name.len);
    @memcpy(dir_data[10..][0..new_name.len], new_name);
    const dir_len: usize = 10 + new_name.len;

    if (!btreeInsert(.{ .inode_nr = new_parent, .item_type = DIR_ENTRY, .offset = new_hash }, dir_data[0..dir_len])) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }

    if (!commitTransaction()) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }

    resp.* = fx.IpcMessage.init(fx.R_OK);
    resp.data_len = 0;
}

fn handleTruncate(req: *fx.IpcMessage, resp: *fx.IpcMessage) void {
    if (req.data_len < 12) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }

    const handle_id = readU32LE(req.data[0..4]);
    const new_size = readU64LE(req.data[4..12]);

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

    if (new_size < inode.size) {
        // Shrinking: free excess extent data
        freeAllExtents(h.inode_nr);

        if (new_size > 0 and new_size <= 3800) {
            // Re-read data and store inline at new size
            // (data was already freed, so this results in a zero-filled inline item)
            var zero_buf: [3800]u8 = [_]u8{0} ** 3800;
            if (!btreeInsert(.{ .inode_nr = h.inode_nr, .item_type = EXTENT_DATA, .offset = 0 }, zero_buf[0..@intCast(new_size)])) {
                resp.* = fx.IpcMessage.init(fx.R_ERROR);
                return;
            }
        }
        // If new_size == 0, no EXTENT_DATA needed (empty file)
    }

    // Update inode size + mtime
    var inode_data: [INODE_ITEM_SIZE]u8 = undefined;
    writeU16LE(inode_data[0..2], inode.mode);
    writeU16LE(inode_data[2..4], inode.uid);
    writeU16LE(inode_data[4..6], inode.gid);
    writeU16LE(inode_data[6..8], inode.nlinks);
    writeU64LE(inode_data[8..16], new_size);
    writeU64LE(inode_data[16..24], inode.atime);
    writeU64LE(inode_data[24..32], getTime()); // mtime
    writeU64LE(inode_data[32..40], inode.ctime);

    if (!btreeUpdate(.{ .inode_nr = h.inode_nr, .item_type = INODE_ITEM, .offset = 0 }, &inode_data)) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }

    // Reset write offset if needed
    if (h.write_offset > new_size) {
        h.write_offset = new_size;
    }

    if (!commitTransaction()) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }

    resp.* = fx.IpcMessage.init(fx.R_OK);
    resp.data_len = 0;
}

fn handleWstat(req: *fx.IpcMessage, resp: *fx.IpcMessage) void {
    if (req.data_len < 24) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }

    const handle_id = readU32LE(req.data[0..4]);
    const mask = readU32LE(req.data[4..8]);
    const new_mode = readU32LE(req.data[8..12]);
    const new_uid = readU32LE(req.data[12..16]);
    const new_gid = readU32LE(req.data[16..20]);
    const caller_uid = readU32LE(req.data[20..24]);

    const h = getHandle(handle_id) orelse {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    var inode = readInode(h.inode_nr) orelse {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    // Apply requested changes
    if (mask & 0x1 != 0) {
        // Mode: update permission bits only, preserve file type
        inode.mode = (inode.mode & S_IFMT) | @as(u16, @truncate(new_mode & 0o7777));
    }
    if (mask & 0x2 != 0) {
        // UID: only root (uid 0) can chown
        if (caller_uid != 0) {
            resp.* = fx.IpcMessage.init(fx.R_ERROR);
            return;
        }
        inode.uid = @truncate(new_uid);
    }
    if (mask & 0x4 != 0) {
        // GID: only root or owner can chgrp
        if (caller_uid != 0 and caller_uid != inode.uid) {
            resp.* = fx.IpcMessage.init(fx.R_ERROR);
            return;
        }
        inode.gid = @truncate(new_gid);
    }

    // Update ctime
    inode.ctime = getTime();

    // Write inode back
    var inode_data: [INODE_ITEM_SIZE]u8 = undefined;
    writeU16LE(inode_data[0..2], inode.mode);
    writeU16LE(inode_data[2..4], inode.uid);
    writeU16LE(inode_data[4..6], inode.gid);
    writeU16LE(inode_data[6..8], inode.nlinks);
    writeU64LE(inode_data[8..16], inode.size);
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

    resp.* = fx.IpcMessage.init(fx.R_OK);
    resp.data_len = 0;
}

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

    if (!writeTreeNode(root_block, &leaf_buf)) return false;

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

/// Worker thread entry point (C calling convention for spawnThread).
fn workerEntry(_: *anyopaque) callconv(.c) void {
    workerLoop();
}

/// IPC server loop — each worker has its own msg/reply buffers on stack.
fn workerLoop() noreturn {
    var wmsg: fx.IpcMessage = undefined;
    var wreply: fx.IpcMessage = undefined;

    while (true) {
        const rc = fx.ipc_recv(SERVER_FD, &wmsg);
        if (rc < 0) continue;

        // Coarse lock: protects all shared state (B-tree, bitmap, cache, handles, IO buffers)
        fs_lock.lock();

        switch (wmsg.tag) {
            fx.T_OPEN => handleOpen(&wmsg, &wreply),
            fx.T_CREATE => handleCreate(&wmsg, &wreply),
            fx.T_READ => handleRead(&wmsg, &wreply),
            fx.T_WRITE => handleWrite(&wmsg, &wreply),
            fx.T_CLOSE => handleClose(&wmsg, &wreply),
            fx.T_STAT => handleStat(&wmsg, &wreply),
            fx.T_REMOVE => handleRemove(&wmsg, &wreply),
            fx.T_RENAME => handleRename(&wmsg, &wreply),
            fx.T_TRUNCATE => handleTruncate(&wmsg, &wreply),
            fx.T_WSTAT => handleWstat(&wmsg, &wreply),
            else => {
                wreply = fx.IpcMessage.init(fx.R_ERROR);
            },
        }

        fs_lock.unlock();

        _ = fx.ipc_reply(SERVER_FD, &wreply);
    }
}

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

    // Spawn worker threads (3 workers + main thread = 4 total)
    const NUM_WORKERS = 3;
    var i: usize = 0;
    while (i < NUM_WORKERS) : (i += 1) {
        _ = fx.thread.spawnThread(workerEntry, null) catch {};
    }

    // Main thread enters the same worker loop
    workerLoop();
}
