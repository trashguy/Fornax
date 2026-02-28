const std = @import("std");
const builtin = @import("builtin");
const boot = @import("boot.zig");
const mem = @import("mem.zig");
const klog = @import("klog.zig");
const SpinLock = @import("spinlock.zig").SpinLock;

const page_size = 4096;

var bitmap: [*]u8 = undefined;
var bitmap_size: usize = 0; // in bytes
var total_pages: usize = 0;
var free_pages: usize = 0;
var search_hint: usize = 0;
var usable_pages: usize = 0;
var initialized: bool = false;

/// Spinlock guarding PMM bitmap, free_pages, and search_hint.
pub var pmm_lock: SpinLock = .{};

/// DMA guard: physical range that must never be freed/re-allocated (debug trap).
var dma_guard_start: usize = 0;
var dma_guard_pages: usize = 0;

pub fn setDmaGuard(phys: usize, pages: usize) void {
    dma_guard_start = phys;
    dma_guard_pages = pages;
}

pub const PmmError = error{
    NoConventionalMemory,
};

pub fn init(memory_map: boot.MemoryMap) PmmError!void {
    const map = memory_map.slice;

    // Pass 1: Find highest physical address to determine bitmap size.
    // Cap at KERNEL_MAP_SIZE — the paging code only identity-maps this much,
    // so pages above it would be inaccessible via physPtr() and cause faults.
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
    if (highest_addr > mem.KERNEL_MAP_SIZE) {
        highest_addr = mem.KERNEL_MAP_SIZE;
    }

    total_pages = @intCast(highest_addr / page_size);
    bitmap_size = (total_pages + 7) / 8;

    // Pass 2: Find a large enough conventional memory region to place the bitmap.
    // Skip regions starting at address 0 — @ptrFromInt(0) is a null pointer in Zig,
    // and page 0 should remain reserved regardless.
    var bitmap_phys: u64 = 0;
    var found = false;
    {
        var it = map.iterator();
        while (it.next()) |desc| {
            if (desc.type != .conventional_memory) continue;
            if (desc.physical_start == 0) continue;
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

    // Pass 3: Mark conventional memory as free (clamped to total_pages)
    {
        var it = map.iterator();
        while (it.next()) |desc| {
            if (desc.type != .conventional_memory) continue;
            const start_page: usize = @intCast(desc.physical_start / page_size);
            const num_pages: usize = @intCast(desc.number_of_pages);
            const end_page = @min(start_page + num_pages, total_pages);
            if (start_page >= total_pages) continue;
            for (start_page..end_page) |page| {
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

    usable_pages = free_pages;
    initialized = true;

    // Print summary
    klog.info("PMM: ");
    klog.infoDec(free_pages);
    klog.info(" free pages (");
    klog.infoDec(free_pages * page_size / (1024 * 1024));
    klog.info(" MB)\n");
}

/// Initialize PMM from a flat physical memory range (for freestanding targets).
/// `ram_base` / `ram_size`: total RAM region.
/// `reserved_end`: everything below this address is reserved (firmware + kernel + initrd).
/// The bitmap is placed at `reserved_end`, free memory starts after it.
pub fn initDirect(ram_base: u64, ram_size: u64, reserved_end: u64) void {
    const raw_end = ram_base + ram_size;
    const ram_end = if (raw_end > mem.KERNEL_MAP_SIZE) mem.KERNEL_MAP_SIZE else raw_end;

    total_pages = @intCast(ram_end / page_size);
    bitmap_size = (total_pages + 7) / 8;

    // Place bitmap right after reserved area
    const bitmap_phys = (reserved_end + page_size - 1) & ~@as(u64, page_size - 1);
    bitmap = @ptrFromInt(bitmap_phys);

    // Mark everything as used
    @memset(bitmap[0..bitmap_size], 0xFF);

    // Mark free region (after bitmap) as free
    const bitmap_pages = (bitmap_size + page_size - 1) / page_size;
    const free_start = bitmap_phys + bitmap_pages * page_size;
    const free_start_page: usize = @intCast(free_start / page_size);
    const end_page: usize = @intCast(ram_end / page_size);

    for (free_start_page..end_page) |page| {
        markFree(page);
    }

    // Count free pages
    free_pages = 0;
    for (0..total_pages) |page| {
        if (isFree(page)) {
            free_pages += 1;
        }
    }

    usable_pages = free_pages;
    initialized = true;

    klog.info("PMM: ");
    klog.infoDec(free_pages);
    klog.info(" free pages (");
    klog.infoDec(free_pages * page_size / (1024 * 1024));
    klog.info(" MB)\n");
}

/// Upgrade the bitmap pointer from a physical (TTBR0) address to a higher-half
/// (TTBR1) virtual address. Must be called after paging is initialized.
///
/// Without this, bitmap accesses go through TTBR0 (the per-process page table).
/// On aarch64, the bitmap's physical address overlaps the user ELF image base
/// (both near 0x4000_0000), so user-space ELF mappings overwrite the identity-map
/// entries and corrupt the kernel's bitmap reads during syscalls.
pub fn upgradeBitmapToHigherHalf() void {
    if (initialized) {
        const phys = @intFromPtr(bitmap);
        bitmap = @ptrFromInt(phys + mem.KERNEL_VIRT_BASE);
    }
}

pub fn allocPage() ?usize {
    if (!initialized) return null;
    pmm_lock.lock();
    defer pmm_lock.unlock();
    // Start scanning from where we last found a free page (avoids O(n) rescan)
    var checked: usize = 0;
    while (checked < total_pages) : (checked += 1) {
        const page = (search_hint + checked) % total_pages;
        if (isFree(page)) {
            // Trap: catch re-allocation of DMA-guarded pages
            if (comptime @import("builtin").cpu.arch == .aarch64) {
                const addr = page * page_size;
                if (dma_guard_start != 0 and addr >= dma_guard_start and addr < dma_guard_start + dma_guard_pages * page_size) {
                    klog.err("PMM TRAP: allocPage DMA page 0x");
                    klog.errHex(@as(u32, @truncate(addr)));
                    klog.err("\n");
                }
            }
            markUsed(page);
            free_pages -= 1;
            search_hint = page + 1;
            return page * page_size;
        }
    }
    return null;
}

/// Allocate `count` physically contiguous pages.
/// Returns the physical address of the first page, or null if no
/// contiguous run of that length is available.
pub fn allocContiguousPages(count: usize) ?usize {
    if (!initialized or count == 0) return null;
    pmm_lock.lock();
    defer pmm_lock.unlock();

    var start = search_hint;
    var checked: usize = 0;
    while (checked < total_pages) {
        // Check if `count` pages starting at `start` are all free
        var run_ok = true;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const page = (start + i) % total_pages;
            if (page + count > total_pages and start + i >= total_pages) {
                // Would wrap around — skip
                run_ok = false;
                break;
            }
            if (!isFree(page)) {
                // Skip past this used page
                checked += i + 1;
                start = start + i + 1;
                run_ok = false;
                break;
            }
        }
        if (run_ok) {
            // Found a run — mark all used
            for (0..count) |j| {
                markUsed((start + j) % total_pages);
            }
            free_pages -= count;
            search_hint = start + count;
            return (start % total_pages) * page_size;
        }
    }
    return null;
}

pub fn freePage(phys_addr: usize) void {
    if (!initialized) return;
    // Trap: catch unexpected frees of DMA pages (aarch64 virtqueue debug)
    if (comptime @import("builtin").cpu.arch == .aarch64) {
        if (dma_guard_start != 0 and phys_addr >= dma_guard_start and phys_addr < dma_guard_start + dma_guard_pages * page_size) {
            klog.err("PMM TRAP: freePage DMA page 0x");
            klog.errHex(@as(u32, @truncate(phys_addr)));
            klog.err("\n");
        }
    }
    pmm_lock.lock();
    defer pmm_lock.unlock();
    const page = phys_addr / page_size;
    if (page < total_pages and !isFree(page)) {
        markFree(page);
        free_pages += 1;
    }
}

pub fn getTotalPages() usize {
    return usable_pages;
}

pub fn getFreePages() usize {
    return free_pages;
}

fn isFree(page: usize) bool {
    const byte = page / 8;
    const bit: u3 = @intCast(page % 8);
    return (bitmap[byte] & (@as(u8, 1) << bit)) == 0;
}

/// Check if a physical address is free in the bitmap (public, for diagnostics).
pub fn isFreeAddr(phys_addr: usize) bool {
    if (!initialized) return false;
    const page = phys_addr / page_size;
    if (page >= total_pages) return false;
    return isFree(page);
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
