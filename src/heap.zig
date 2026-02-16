/// Kernel bump allocator backed by PMM.
/// No free for MVP — just bumps forward. Good enough for kernel init structures.
const pmm = @import("pmm.zig");
const klog = @import("klog.zig");

const page_size = 4096;

/// Number of pages to grab from PMM at init for the heap arena.
const initial_pages = 64; // 256 KB

var arena_base: usize = 0;
var arena_size: usize = 0;
var offset: usize = 0;
var initialized: bool = false;

pub fn init() void {
    // Allocate contiguous-ish pages from PMM
    // For MVP, grab the first page and use it as the base, then grab more
    const first = pmm.allocPage() orelse {
        klog.err("Heap: failed to allocate from PMM!\n");
        return;
    };
    arena_base = first;
    arena_size = page_size;

    // Try to grab more pages — they may not be contiguous but we allocate
    // enough initial pages to cover MVP needs
    var pages_allocated: usize = 1;
    while (pages_allocated < initial_pages) : (pages_allocated += 1) {
        const page = pmm.allocPage() orelse break;
        // Only extend arena if this page is contiguous
        if (page == arena_base + arena_size) {
            arena_size += page_size;
        } else {
            // Non-contiguous — return it and stop
            pmm.freePage(page);
            break;
        }
    }

    offset = 0;
    initialized = true;

    klog.info("Heap: ");
    klog.infoDec(arena_size / 1024);
    klog.info(" KB arena at ");
    klog.infoHex(arena_base);
    klog.info("\n");
}

pub fn alloc(size: usize) ?[*]u8 {
    return allocAligned(size, 8);
}

pub fn allocAligned(size: usize, alignment: usize) ?[*]u8 {
    if (!initialized or size == 0) return null;

    // Align offset up
    const aligned_offset = (offset + alignment - 1) & ~(alignment - 1);
    if (aligned_offset + size > arena_size) {
        // Try to grow by allocating more pages from PMM
        const needed = aligned_offset + size - arena_size;
        const pages_needed = (needed + page_size - 1) / page_size;
        var grown: usize = 0;
        while (grown < pages_needed) : (grown += 1) {
            const page = pmm.allocPage() orelse break;
            if (page == arena_base + arena_size) {
                arena_size += page_size;
            } else {
                pmm.freePage(page);
                break;
            }
        }
        if (aligned_offset + size > arena_size) return null;
    }

    offset = aligned_offset + size;
    return @ptrFromInt(arena_base + aligned_offset);
}

/// Returns how much heap space has been used so far.
pub fn used() usize {
    return offset;
}

/// Returns total arena capacity.
pub fn capacity() usize {
    return arena_size;
}
