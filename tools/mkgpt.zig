/// mkgpt — GPT partition table creator for Fornax disk images.
///
/// Usage: mkgpt <disk-image>
///
/// Creates:
///   LBA 0:     Protective MBR (boot signature 0x55AA, partition type 0xEE)
///   LBA 1:     Primary GPT header
///   LBA 2-33:  Partition entry array (128 entries × 128 bytes)
///   LBA 34+:   (reserved for data; partition 1 starts at LBA 2048)
///   Last LBAs: Backup partition entries + backup GPT header
///
/// Partition 1: Linux filesystem type, name "Fornax Root", starts at LBA 2048.
const std = @import("std");

const SECTOR_SIZE = 512;
const GPT_HEADER_SIZE = 92;
const GPT_ENTRY_SIZE = 128;
const GPT_ENTRY_COUNT = 128;
const PARTITION_ARRAY_SECTORS = (GPT_ENTRY_COUNT * GPT_ENTRY_SIZE + SECTOR_SIZE - 1) / SECTOR_SIZE; // 32

// Linux filesystem GUID: 0FC63DAF-8483-4772-8E79-3D69D8477DE4
// Mixed-endian per UEFI spec: first 3 components LE, last 2 BE
const LINUX_FS_GUID = [16]u8{
    0xAF, 0x3D, 0xC6, 0x0F, // 0FC63DAF LE
    0x83, 0x84, // 8483 LE
    0x72, 0x47, // 4772 LE
    0x8E, 0x79, // 8E79 BE
    0x3D, 0x69, 0xD8, 0x47, 0x7D, 0xE4, // 3D69D8477DE4 BE
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try std.process.argsAlloc(alloc);
    if (args.len < 2) {
        std.debug.print("Usage: mkgpt <disk-image>\n", .{});
        std.process.exit(1);
    }

    const image_path = args[1];

    const file = try std.fs.cwd().openFile(image_path, .{ .mode = .read_write });
    defer file.close();

    const file_size = try file.getEndPos();
    if (file_size < 1024 * 1024) {
        std.debug.print("Error: disk image too small (need at least 1 MB)\n", .{});
        std.process.exit(1);
    }

    const total_sectors = file_size / SECTOR_SIZE;
    const last_usable_lba = total_sectors - 1 - 1 - PARTITION_ARRAY_SECTORS; // -1 backup header, -32 backup entries
    const first_usable_lba: u64 = 2 + PARTITION_ARRAY_SECTORS; // after header + entries = LBA 34

    // Partition 1: starts at LBA 2048 (1 MB aligned), extends to last_usable_lba
    const part1_start: u64 = 2048;
    const part1_end: u64 = last_usable_lba;

    if (part1_start >= part1_end) {
        std.debug.print("Error: disk too small for partition at LBA 2048\n", .{});
        std.process.exit(1);
    }

    // Generate pseudo-random GUIDs (deterministic from file size for reproducibility)
    var disk_guid: [16]u8 = undefined;
    var part1_guid: [16]u8 = undefined;
    {
        var h = std.hash.Fnv1a_128.init();
        h.update("fornax-disk-guid");
        h.update(std.mem.asBytes(&file_size));
        const hash = h.final();
        @memcpy(&disk_guid, std.mem.asBytes(&hash)[0..16]);
        // Set version 4 (random) and variant 1
        disk_guid[6] = (disk_guid[6] & 0x0F) | 0x40;
        disk_guid[8] = (disk_guid[8] & 0x3F) | 0x80;
    }
    {
        var h = std.hash.Fnv1a_128.init();
        h.update("fornax-part1-guid");
        h.update(std.mem.asBytes(&file_size));
        const hash = h.final();
        @memcpy(&part1_guid, std.mem.asBytes(&hash)[0..16]);
        part1_guid[6] = (part1_guid[6] & 0x0F) | 0x40;
        part1_guid[8] = (part1_guid[8] & 0x3F) | 0x80;
    }

    // ── Build partition entries ──────────────────────────────────────

    var entries_buf = try alloc.alloc(u8, PARTITION_ARRAY_SECTORS * SECTOR_SIZE);
    @memset(entries_buf, 0);

    // Entry 0: partition 1
    const e = entries_buf[0..GPT_ENTRY_SIZE];
    @memcpy(e[0..16], &LINUX_FS_GUID); // type GUID
    @memcpy(e[16..32], &part1_guid); // unique GUID
    writeU64LE(e[32..40], part1_start); // first LBA
    writeU64LE(e[40..48], part1_end); // last LBA
    writeU64LE(e[48..56], 0); // attributes

    // Name: "Fornax Root" in UTF-16LE (bytes 56..128)
    const name = "Fornax Root";
    for (name, 0..) |c, i| {
        e[56 + i * 2] = c;
        e[56 + i * 2 + 1] = 0;
    }

    // CRC32 of partition entries
    const entries_crc = std.hash.Crc32.hash(entries_buf);

    // ── Build primary GPT header (LBA 1) ────────────────────────────

    var hdr: [SECTOR_SIZE]u8 = [_]u8{0} ** SECTOR_SIZE;
    @memcpy(hdr[0..8], "EFI PART"); // signature
    writeU32LE(hdr[8..12], 0x00010000); // revision 1.0
    writeU32LE(hdr[12..16], GPT_HEADER_SIZE); // header size
    writeU32LE(hdr[16..20], 0); // header CRC32 (filled below)
    writeU32LE(hdr[20..24], 0); // reserved
    writeU64LE(hdr[24..32], 1); // my LBA
    writeU64LE(hdr[32..40], total_sectors - 1); // alternate/backup LBA
    writeU64LE(hdr[40..48], first_usable_lba); // first usable LBA
    writeU64LE(hdr[48..56], last_usable_lba); // last usable LBA
    @memcpy(hdr[56..72], &disk_guid); // disk GUID
    writeU64LE(hdr[72..80], 2); // partition entry start LBA
    writeU32LE(hdr[80..84], GPT_ENTRY_COUNT); // number of partition entries
    writeU32LE(hdr[84..88], GPT_ENTRY_SIZE); // size of partition entry
    writeU32LE(hdr[88..92], entries_crc); // partition entries CRC32

    // Compute header CRC32 (over first 92 bytes, with CRC field zeroed)
    writeU32LE(hdr[16..20], 0);
    const hdr_crc = std.hash.Crc32.hash(hdr[0..GPT_HEADER_SIZE]);
    writeU32LE(hdr[16..20], hdr_crc);

    // ── Build backup GPT header ─────────────────────────────────────

    var backup_hdr: [SECTOR_SIZE]u8 = hdr;
    // Swap my_lba and alternate_lba
    writeU64LE(backup_hdr[24..32], total_sectors - 1); // my LBA (last sector)
    writeU64LE(backup_hdr[32..40], 1); // alternate LBA (primary)
    // Partition entries for backup are before the backup header
    writeU64LE(backup_hdr[72..80], total_sectors - 1 - PARTITION_ARRAY_SECTORS);

    // Recompute backup header CRC32
    writeU32LE(backup_hdr[16..20], 0);
    const backup_crc = std.hash.Crc32.hash(backup_hdr[0..GPT_HEADER_SIZE]);
    writeU32LE(backup_hdr[16..20], backup_crc);

    // ── Build protective MBR (LBA 0) ────────────────────────────────

    var mbr: [SECTOR_SIZE]u8 = [_]u8{0} ** SECTOR_SIZE;
    // Partition entry 1 at offset 446
    mbr[446] = 0x00; // status (not bootable)
    mbr[447] = 0x00; // CHS start head
    mbr[448] = 0x02; // CHS start sector/cylinder
    mbr[449] = 0x00; // CHS start cylinder
    mbr[450] = 0xEE; // partition type = GPT protective
    mbr[451] = 0xFF; // CHS end head
    mbr[452] = 0xFF; // CHS end sector/cylinder
    mbr[453] = 0xFF; // CHS end cylinder
    writeU32LE(mbr[454..458], 1); // LBA start
    const mbr_size: u32 = @intCast(@min(total_sectors - 1, 0xFFFFFFFF));
    writeU32LE(mbr[458..462], mbr_size); // LBA size
    mbr[510] = 0x55; // boot signature
    mbr[511] = 0xAA;

    // ── Write everything to disk ────────────────────────────────────

    // LBA 0: Protective MBR
    try file.seekTo(0);
    try file.writeAll(&mbr);

    // LBA 1: Primary GPT header
    try file.seekTo(SECTOR_SIZE);
    try file.writeAll(&hdr);

    // LBA 2-33: Primary partition entry array
    try file.seekTo(2 * SECTOR_SIZE);
    try file.writeAll(entries_buf);

    // Backup partition entries (before last sector)
    const backup_entries_lba = total_sectors - 1 - PARTITION_ARRAY_SECTORS;
    try file.seekTo(backup_entries_lba * SECTOR_SIZE);
    try file.writeAll(entries_buf);

    // Backup GPT header (last sector)
    try file.seekTo((total_sectors - 1) * SECTOR_SIZE);
    try file.writeAll(&backup_hdr);

    std.debug.print("mkgpt: created GPT on {s}\n", .{image_path});
    std.debug.print("  disk size: {d} sectors ({d} MB)\n", .{ total_sectors, file_size / (1024 * 1024) });
    std.debug.print("  partition 1: LBA {d}-{d} ({d} sectors, {d} MB)\n", .{
        part1_start,
        part1_end,
        part1_end - part1_start + 1,
        (part1_end - part1_start + 1) * SECTOR_SIZE / (1024 * 1024),
    });
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
