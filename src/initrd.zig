/// Fornax initrd — flat namespace image.
///
/// Format (all little-endian):
///   [0..8)    magic: "FXINITRD"
///   [8..12)   entry_count: u32
///   [12..)    entries: [entry_count]Entry
///             file data (offsets relative to image start)
///
/// Entry (72 bytes):
///   [0..64)   name: null-terminated, zero-padded
///   [64..68)  offset: u32
///   [68..72)  size: u32
const serial = @import("serial.zig");
const console = @import("console.zig");
const ipc = @import("ipc.zig");
const namespace = @import("namespace.zig");

pub const MAGIC = "FXINITRD";
pub const MAX_NAME_LEN = 64;

pub const Entry = extern struct {
    name: [MAX_NAME_LEN]u8,
    offset: u32,
    size: u32,
};

comptime {
    if (@sizeOf(Entry) != 72) @compileError("Entry must be 72 bytes");
}

/// Validated initrd state.
var image_base: [*]const u8 = undefined;
var image_size: usize = 0;
var entries: [*]const Entry = undefined;
var entry_count: u32 = 0;
var ready: bool = false;

/// DirEntry-compatible struct for /boot directory listing (matches lib/ipc.zig DirEntry layout).
const BootDirEntry = extern struct {
    name: [64]u8,
    file_type: u32, // 0=file, 1=directory
    size: u32,
};
comptime {
    if (@sizeOf(BootDirEntry) != 72) @compileError("BootDirEntry must be 72 bytes");
}

const MAX_DIR_ENTRIES = 32;
var dir_listing: [MAX_DIR_ENTRIES]BootDirEntry = undefined;

/// Initialize the initrd from a memory region loaded by UEFI.
/// Returns false if the image is missing or invalid.
pub fn init(base: ?[*]const u8, size: usize) bool {
    const b = base orelse {
        serial.puts("initrd: no image loaded\n");
        return false;
    };

    if (size < 12) {
        serial.puts("initrd: image too small\n");
        return false;
    }

    // Check magic
    if (!eql(b[0..8], MAGIC)) {
        serial.puts("initrd: bad magic\n");
        return false;
    }

    const count = readU32(b[8..12]);
    const header_size = 12 + @as(usize, count) * @sizeOf(Entry);
    if (header_size > size) {
        serial.puts("initrd: truncated header\n");
        return false;
    }

    image_base = b;
    image_size = size;
    entry_count = count;
    entries = @ptrCast(@alignCast(b + 12));
    ready = true;

    console.puts("initrd: ");
    console.putDec(count);
    console.puts(" files\n");

    // Log file names
    for (0..count) |i| {
        const e = &entries[i];
        serial.puts("  ");
        serial.puts(entryName(e));
        serial.puts(" (");
        serial.putDec(e.size);
        serial.puts(" bytes)\n");
    }

    return true;
}

/// Find a file by name. Returns the raw bytes or null.
pub fn findFile(name: []const u8) ?[]const u8 {
    if (!ready) return null;

    for (0..entry_count) |i| {
        const e = &entries[i];
        if (nameEql(e, name)) {
            if (e.offset + e.size > image_size) return null; // corrupt
            return image_base[e.offset..][0..e.size];
        }
    }
    return null;
}

/// Number of files in the initrd.
pub fn fileCount() u32 {
    return entry_count;
}

/// Mount each initrd file as a kernel-backed channel in the root namespace.
/// Files are accessible at /boot/<filename> (e.g. /boot/init).
pub fn mountFiles() void {
    if (!ready) return;

    const root_ns = namespace.getRootNamespace();

    for (0..entry_count) |i| {
        const e = &entries[i];
        const name = entryName(e);
        const data = image_base[e.offset..][0..e.size];

        // Create kernel-backed channel for this file
        const chan_id = ipc.channelCreateKernelBacked(data) catch {
            serial.puts("initrd: failed to create channel for ");
            serial.puts(name);
            serial.puts("\n");
            continue;
        };

        // Build mount path: /boot/<name>
        var path_buf: [128]u8 = undefined;
        const prefix = "/boot/";
        @memcpy(path_buf[0..prefix.len], prefix);
        @memcpy(path_buf[prefix.len..][0..name.len], name);
        const path_len = prefix.len + name.len;

        root_ns.mount(path_buf[0..path_len], chan_id, .{ .replace = true }) catch {
            serial.puts("initrd: failed to mount /boot/");
            serial.puts(name);
            serial.puts("\n");
            continue;
        };

        serial.puts("initrd: mounted /boot/");
        serial.puts(name);
        serial.puts("\n");

        // Build DirEntry for directory listing (same 72-byte layout)
        if (i < MAX_DIR_ENTRIES) {
            var dir_entry = &dir_listing[i];
            dir_entry.name = e.name; // copy 64-byte name (already null-padded)
            dir_entry.file_type = 0; // file
            dir_entry.size = e.size;
        }
    }

    // Mount /boot directory listing as kernel-backed channel
    const dir_count = @min(entry_count, MAX_DIR_ENTRIES);
    if (dir_count > 0) {
        const dir_bytes: []const u8 = @as([*]const u8, @ptrCast(&dir_listing))[0 .. @as(usize, dir_count) * @sizeOf(BootDirEntry)];
        const dir_chan = ipc.channelCreateKernelBacked(dir_bytes) catch {
            serial.puts("initrd: failed to create /boot dir channel\n");
            return;
        };
        root_ns.mount("/boot", dir_chan, .{ .replace = true }) catch {
            serial.puts("initrd: failed to mount /boot dir\n");
            return;
        };
        serial.puts("initrd: mounted /boot directory\n");
    }
}

// -- helpers --

fn entryName(e: *const Entry) []const u8 {
    for (e.name, 0..) |c, i| {
        if (c == 0) return e.name[0..i];
    }
    return &e.name;
}

fn nameEql(e: *const Entry, name: []const u8) bool {
    const ename = entryName(e);
    return eql(ename, name);
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

fn readU32(bytes: *const [4]u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}
