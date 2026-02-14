const std = @import("std");
const uefi = std.os.uefi;
const console = @import("console.zig");

pub const BootInfo = struct {
    framebuffer: console.Framebuffer,
    memory_map: MemoryMap,
    /// Initrd image loaded from ESP (null if not found).
    initrd_base: ?[*]const u8,
    initrd_size: usize,
};

pub const MemoryMap = struct {
    slice: uefi.tables.MemoryMapSlice,
    /// Raw buffer backing the memory map (must remain valid).
    buffer: []align(@alignOf(uefi.tables.MemoryDescriptor)) u8,
};

pub const InitError = error{
    NoBootServices,
    NoGOP,
    UnsupportedPixelFormat,
    MemoryMapFailed,
    ExitBootServicesFailed,
    PoolAllocFailed,
};

pub fn init() InitError!BootInfo {
    const boot_services = uefi.system_table.boot_services orelse return error.NoBootServices;

    // Locate GOP
    const gop = (boot_services.locateProtocol(uefi.protocol.GraphicsOutput, null) catch
        return error.NoGOP) orelse return error.NoGOP;

    const mode_info = gop.mode.info;
    const is_bgr = switch (mode_info.pixel_format) {
        .blue_green_red_reserved_8_bit_per_color => true,
        .red_green_blue_reserved_8_bit_per_color => false,
        else => return error.UnsupportedPixelFormat,
    };

    const framebuffer = console.Framebuffer{
        .base = @ptrFromInt(gop.mode.frame_buffer_base),
        .width = mode_info.horizontal_resolution,
        .height = mode_info.vertical_resolution,
        .stride = mode_info.pixels_per_scan_line,
        .is_bgr = is_bgr,
    };

    // Load initrd from ESP (optional — boot proceeds without it)
    const initrd = loadInitrd(boot_services);

    // Get memory map and exit boot services
    // Allocate a generous buffer for the memory map
    const map_buf_size: usize = 64 * 1024;
    const map_buf = boot_services.allocatePool(.loader_data, map_buf_size) catch
        return error.PoolAllocFailed;

    // Cast to properly aligned slice
    const aligned_buf: []align(@alignOf(uefi.tables.MemoryDescriptor)) u8 = @alignCast(map_buf);

    var memory_map = boot_services.getMemoryMap(aligned_buf) catch
        return error.MemoryMapFailed;

    // Exit boot services — may fail if map key is stale, so retry once
    boot_services.exitBootServices(uefi.handle, memory_map.info.key) catch {
        // Re-fetch memory map and try again
        memory_map = boot_services.getMemoryMap(aligned_buf) catch
            return error.MemoryMapFailed;
        boot_services.exitBootServices(uefi.handle, memory_map.info.key) catch
            return error.ExitBootServicesFailed;
    };

    return BootInfo{
        .framebuffer = framebuffer,
        .memory_map = .{
            .slice = memory_map,
            .buffer = aligned_buf,
        },
        .initrd_base = initrd.base,
        .initrd_size = initrd.size,
    };
}

const InitrdResult = struct {
    base: ?[*]const u8,
    size: usize,
};

/// Try to load \EFI\BOOT\INITRD from the ESP. Returns null base if not found.
fn loadInitrd(boot_services: *uefi.tables.BootServices) InitrdResult {
    const none = InitrdResult{ .base = null, .size = 0 };

    // Locate Simple File System protocol
    const sfs = (boot_services.locateProtocol(uefi.protocol.SimpleFileSystem, null) catch
        return none) orelse return none;

    // Open root volume
    const root = sfs.openVolume() catch return none;

    // Open \EFI\BOOT\INITRD
    const file = root.open(L("\\EFI\\BOOT\\INITRD"), .read, .{}) catch return none;

    // Get file size
    const info_buf_size = file.getInfoSize(.file) catch return none;
    const info_buf = boot_services.allocatePool(.loader_data, info_buf_size) catch return none;
    const aligned_info: []align(@alignOf(uefi.protocol.File.Info.File)) u8 = @alignCast(info_buf);
    const file_info = file.getInfo(.file, aligned_info) catch return none;
    const file_size: usize = @intCast(file_info.file_size);

    if (file_size == 0) return none;

    // Allocate buffer for file contents (persists after ExitBootServices)
    const data_buf = boot_services.allocatePool(.loader_data, file_size) catch return none;

    // Read the file
    const bytes_read = file.read(data_buf) catch return none;
    if (bytes_read != file_size) return none;

    file.close() catch {};

    return InitrdResult{
        .base = @ptrCast(data_buf.ptr),
        .size = file_size,
    };
}

pub fn errorName(err: InitError) [*:0]const u16 {
    return switch (err) {
        error.NoBootServices => L("NoBootServices"),
        error.NoGOP => L("NoGOP"),
        error.UnsupportedPixelFormat => L("UnsupportedPixelFormat"),
        error.MemoryMapFailed => L("MemoryMapFailed"),
        error.ExitBootServicesFailed => L("ExitBootServicesFailed"),
        error.PoolAllocFailed => L("PoolAllocFailed"),
    };
}

fn L(comptime ascii: []const u8) *const [ascii.len:0]u16 {
    const S = struct {
        const value = blk: {
            var buf: [ascii.len:0]u16 = undefined;
            for (0..ascii.len) |i| {
                buf[i] = ascii[i];
            }
            buf[ascii.len] = 0;
            break :blk buf;
        };
    };
    return &S.value;
}
