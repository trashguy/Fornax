/// GPT partition table parser for boot-time partition detection.
///
/// Reads GPT header + partition entries from the virtio-blk device.
/// Used by main.zig to set partition offsets for fxfs and to provide
/// partition info for partfs.
const klog = @import("klog.zig");
const virtio_blk = @import("virtio_blk.zig");

pub const MAX_PARTITIONS = 8;

pub const PartitionInfo = struct {
    type_guid: [16]u8,
    first_lba: u64,
    last_lba: u64,
    name: [36]u8,
    name_len: u8,
};

var partitions: [MAX_PARTITIONS]PartitionInfo = undefined;
var partition_count: u8 = 0;
var disk_sectors: u64 = 0;
var initialized: bool = false;

/// GPT header signature: "EFI PART"
const GPT_SIGNATURE = "EFI PART";

/// Size of a GPT partition entry (minimum per spec)
const GPT_ENTRY_SIZE = 128;

/// Block size used by virtio-blk
const BLOCK_SIZE = 4096;

/// Read blocks needed for GPT parsing and detect partitions.
/// Returns true if a valid GPT was found.
pub fn init() bool {
    if (!virtio_blk.isInitialized()) return false;

    disk_sectors = virtio_blk.getCapacitySectors();

    // Read block 0: contains protective MBR (LBA 0) + GPT header (LBA 1)
    var block0: [BLOCK_SIZE]u8 = undefined;
    if (!virtio_blk.readBlock(0, &block0)) {
        klog.debug("gpt: failed to read block 0\n");
        return false;
    }

    // Validate MBR signature at bytes 510-511
    if (block0[510] != 0x55 or block0[511] != 0xAA) {
        klog.debug("gpt: no MBR signature\n");
        return false;
    }

    // Check protective MBR partition type at byte 450 (first partition entry type)
    if (block0[450] != 0xEE) {
        klog.debug("gpt: not a protective MBR (type=0x");
        klog.debugHex(block0[450]);
        klog.debug(")\n");
        return false;
    }

    // GPT header at offset 512 (LBA 1 within block 0)
    const hdr = block0[512..];

    // Validate GPT signature
    if (!eql(hdr[0..8], GPT_SIGNATURE)) {
        klog.debug("gpt: bad GPT signature\n");
        return false;
    }

    // Parse header fields
    const partition_entry_lba = readU64LE(hdr[72..80]);
    const num_partition_entries = readU32LE(hdr[80..84]);
    const entry_size = readU32LE(hdr[84..88]);

    klog.debug("gpt: ");
    klog.debugDec(num_partition_entries);
    klog.debug(" partition entries at LBA ");
    klog.debugDec(partition_entry_lba);
    klog.debug(", entry size ");
    klog.debugDec(entry_size);
    klog.debug("\n");

    if (entry_size < GPT_ENTRY_SIZE or entry_size > 512) {
        klog.debug("gpt: unsupported entry size\n");
        return false;
    }

    // Read blocks containing partition entries
    // Entries start at partition_entry_lba (typically LBA 2 = byte 1024)
    // With 128-byte entries and 128 entries, that's 16384 bytes = 4 blocks
    const entry_start_byte = partition_entry_lba * 512;
    const first_entry_block = entry_start_byte / BLOCK_SIZE;
    const total_entry_bytes = @as(u64, num_partition_entries) * entry_size;
    const last_entry_block = (entry_start_byte + total_entry_bytes - 1) / BLOCK_SIZE;

    partition_count = 0;

    var block_nr = first_entry_block;
    while (block_nr <= last_entry_block and block_nr < 8) : (block_nr += 1) {
        var block_buf: [BLOCK_SIZE]u8 = undefined;
        if (!virtio_blk.readBlock(block_nr, &block_buf)) {
            klog.debug("gpt: failed to read entry block\n");
            break;
        }

        // Parse entries within this block
        const block_byte_start = block_nr * BLOCK_SIZE;
        var offset: usize = 0;

        while (offset + entry_size <= BLOCK_SIZE) : (offset += @intCast(entry_size)) {
            // Calculate which entry number this is
            const abs_byte = block_byte_start + offset;
            if (abs_byte < entry_start_byte) {
                continue;
            }
            const entry_idx = (abs_byte - entry_start_byte) / entry_size;
            if (entry_idx >= num_partition_entries) break;

            const entry = block_buf[offset..][0..GPT_ENTRY_SIZE];

            // Check if type GUID is all zeros (empty entry)
            if (isZero(entry[0..16])) continue;

            if (partition_count >= MAX_PARTITIONS) break;

            var part: PartitionInfo = undefined;
            @memcpy(&part.type_guid, entry[0..16]);
            part.first_lba = readU64LE(entry[32..40]);
            part.last_lba = readU64LE(entry[40..48]);

            // Convert UTF-16LE name to ASCII (bytes 56..128 = 72 bytes = 36 chars)
            part.name_len = 0;
            var ci: usize = 0;
            while (ci < 36) : (ci += 1) {
                const name_offset = 56 + ci * 2;
                if (name_offset + 1 >= GPT_ENTRY_SIZE) break;
                const lo = entry[name_offset];
                const hi = entry[name_offset + 1];
                if (lo == 0 and hi == 0) break;
                // Take low byte as ASCII
                part.name[ci] = if (lo >= 0x20 and lo < 0x7F) lo else '?';
                part.name_len += 1;
            }
            // Null-pad remaining
            while (ci < 36) : (ci += 1) {
                part.name[ci] = 0;
            }

            partitions[partition_count] = part;
            partition_count += 1;

            klog.debug("gpt: partition ");
            klog.debugDec(partition_count);
            klog.debug(": LBA ");
            klog.debugDec(part.first_lba);
            klog.debug("-");
            klog.debugDec(part.last_lba);
            klog.debug(" \"");
            klog.debug(part.name[0..part.name_len]);
            klog.debug("\"\n");
        }
    }

    initialized = partition_count > 0;
    return initialized;
}

pub fn isInitialized() bool {
    return initialized;
}

pub fn getPartitionCount() u8 {
    return partition_count;
}

pub fn getPartition(idx: u8) ?*const PartitionInfo {
    if (idx >= partition_count) return null;
    return &partitions[idx];
}

pub fn getDiskSectors() u64 {
    return disk_sectors;
}

// ── Helpers ────────────────────────────────────────────────────────

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

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

fn isZero(buf: []const u8) bool {
    for (buf) |b| {
        if (b != 0) return false;
    }
    return true;
}
