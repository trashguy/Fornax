const std = @import("std");
const uefi = std.os.uefi;
const boot = @import("boot.zig");
const klog = @import("klog.zig");

const page_size = 4096;

var bitmap: [*]u8 = undefined;
var bitmap_size: usize = 0; // in bytes
var total_pages: usize = 0;
var free_pages: usize = 0;
var initialized: bool = false;

pub const PmmError = error{
    NoConventionalMemory,
};

pub fn init(memory_map: boot.MemoryMap) PmmError!void {
    const map = memory_map.slice;

    // Pass 1: Find highest physical address to determine bitmap size
    var highest_addr: u64 = 0;
    {
        var it = map.iterator();
        while (it.next()) |desc| {
            const end = desc.physical_start + desc.number_of_pages * page_size;
            if (end > highest_addr) {
                highest_addr = end;
            }
        }
    }

    total_pages = @intCast(highest_addr / page_size);
    bitmap_size = (total_pages + 7) / 8;

    // Pass 2: Find a large enough conventional memory region to place the bitmap
    var bitmap_phys: u64 = 0;
    var found = false;
    {
        var it = map.iterator();
        while (it.next()) |desc| {
            if (desc.type != .conventional_memory) continue;
            const region_size = desc.number_of_pages * page_size;
            if (region_size >= bitmap_size) {
                bitmap_phys = desc.physical_start;
                found = true;
                break;
            }
        }
    }

    if (!found) return error.NoConventionalMemory;

    // Place bitmap
    bitmap = @ptrFromInt(bitmap_phys);

    // Mark everything as used (bit = 0 means free, bit = 1 means used)
    @memset(bitmap[0..bitmap_size], 0xFF);

    // Pass 3: Mark conventional memory as free
    {
        var it = map.iterator();
        while (it.next()) |desc| {
            if (desc.type != .conventional_memory) continue;
            const start_page: usize = @intCast(desc.physical_start / page_size);
            const num_pages: usize = @intCast(desc.number_of_pages);
            for (start_page..start_page + num_pages) |page| {
                markFree(page);
            }
        }
    }

    // Mark bitmap's own pages as used
    const bitmap_pages = (bitmap_size + page_size - 1) / page_size;
    const bitmap_start_page: usize = @intCast(bitmap_phys / page_size);
    for (bitmap_start_page..bitmap_start_page + bitmap_pages) |page| {
        markUsed(page);
    }

    // Count free pages
    free_pages = 0;
    for (0..total_pages) |page| {
        if (isFree(page)) {
            free_pages += 1;
        }
    }

    initialized = true;

    // Print summary
    klog.info("PMM: ");
    klog.infoDec(free_pages);
    klog.info(" free pages (");
    klog.infoDec(free_pages * page_size / (1024 * 1024));
    klog.info(" MB)\n");
}

pub fn allocPage() ?usize {
    if (!initialized) return null;
    for (0..total_pages) |page| {
        if (isFree(page)) {
            markUsed(page);
            free_pages -= 1;
            return page * page_size;
        }
    }
    return null;
}

pub fn freePage(phys_addr: usize) void {
    if (!initialized) return;
    const page = phys_addr / page_size;
    if (page < total_pages and !isFree(page)) {
        markFree(page);
        free_pages += 1;
    }
}

fn isFree(page: usize) bool {
    const byte = page / 8;
    const bit: u3 = @intCast(page % 8);
    return (bitmap[byte] & (@as(u8, 1) << bit)) == 0;
}

fn markFree(page: usize) void {
    const byte = page / 8;
    const bit: u3 = @intCast(page % 8);
    bitmap[byte] &= ~(@as(u8, 1) << bit);
}

fn markUsed(page: usize) void {
    const byte = page / 8;
    const bit: u3 = @intCast(page % 8);
    bitmap[byte] |= (@as(u8, 1) << bit);
}
