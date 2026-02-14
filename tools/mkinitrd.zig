/// mkinitrd — Fornax initrd image packer.
///
/// Usage: mkinitrd <output-file> <file1> [file2 ...]
///
/// Produces a flat namespace image:
///   [0..8)    magic: "FXINITRD"
///   [8..12)   entry_count: u32
///   [12..)    entries: [entry_count]Entry (72 bytes each)
///             file data
///
/// Entry: 64-byte name (null-padded) + u32 offset + u32 size.
/// File names are taken as-is from arguments (e.g. "init", "console").
const std = @import("std");

const MAGIC = "FXINITRD";
const MAX_NAME_LEN = 64;
const ENTRY_SIZE = 72; // 64 + 4 + 4

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try std.process.argsAlloc(alloc);
    if (args.len < 2) {
        std.debug.print("Usage: mkinitrd <output> [file1 file2 ...]\n", .{});
        std.process.exit(1);
    }

    const output_path = args[1];
    const input_files = args[2..];

    // Read all input files
    const FileEntry = struct {
        name: []const u8,
        data: []const u8,
    };

    var entries = try alloc.alloc(FileEntry, input_files.len);
    for (input_files, 0..) |path, i| {
        const data = try std.fs.cwd().readFileAlloc(alloc, path, 16 * 1024 * 1024);
        // Use just the filename, not the full path
        const name = std.fs.path.basename(path);
        entries[i] = .{ .name = name, .data = data };
    }

    // Calculate layout
    const entry_count: u32 = @intCast(entries.len);
    const header_size: u32 = 12 + entry_count * ENTRY_SIZE;

    // Calculate offsets
    var data_offset: u32 = header_size;
    var offsets = try alloc.alloc(u32, entries.len);
    for (entries, 0..) |e, i| {
        offsets[i] = data_offset;
        data_offset += @intCast(e.data.len);
    }

    // Build the entire image in memory, then write it out
    const total_size: usize = data_offset;
    var image = try alloc.alloc(u8, total_size);

    // Magic
    @memcpy(image[0..8], MAGIC);

    // Entry count (little-endian)
    writeU32(image[8..12], entry_count);

    // Entries
    var pos: usize = 12;
    for (entries, 0..) |e, i| {
        // Name (64 bytes, null-padded)
        @memset(image[pos..][0..MAX_NAME_LEN], 0);
        const copy_len = @min(e.name.len, MAX_NAME_LEN - 1);
        @memcpy(image[pos..][0..copy_len], e.name[0..copy_len]);
        pos += MAX_NAME_LEN;

        // Offset + size
        writeU32(image[pos..][0..4], offsets[i]);
        pos += 4;
        writeU32(image[pos..][0..4], @intCast(e.data.len));
        pos += 4;
    }

    // File data
    for (entries) |e| {
        @memcpy(image[pos..][0..e.data.len], e.data);
        pos += e.data.len;
    }

    // Write output
    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();
    try file.writeAll(image);

    std.debug.print("mkinitrd: {d} files, {d} bytes\n", .{ entry_count, total_size });
}

fn writeU32(buf: *[4]u8, val: u32) void {
    buf[0] = @truncate(val);
    buf[1] = @truncate(val >> 8);
    buf[2] = @truncate(val >> 16);
    buf[3] = @truncate(val >> 24);
}
