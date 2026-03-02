/// Shared memory manager for cross-process zero-copy data transfer.
///
/// Provides create/map/unmap/destroy for shared memory segments backed by
/// physical pages. Used by the SPSC ring buffer for bulk IPC bypass.
const pmm = @import("pmm.zig");
const klog = @import("klog.zig");
const SpinLock = @import("spinlock.zig").SpinLock;

const paging = switch (@import("builtin").cpu.arch) {
    .x86_64 => @import("arch/x86_64/paging.zig"),
    .riscv64 => @import("arch/riscv64/paging.zig"),
    .aarch64 => @import("arch/aarch64/paging.zig"),
    else => struct {
        pub const PageTable = struct { entries: [512]u64 };
        pub fn mapPage(_: anytype, _: u64, _: u64, _: u64) ?void {}
        pub fn unmapPage(_: anytype, _: u64) void {}
        pub const Flags = struct {
            pub const PRESENT: u64 = 1;
            pub const WRITABLE: u64 = 2;
            pub const USER: u64 = 4;
            pub const EXEC: u64 = 0;
        };
    },
};

const PAGE_SIZE = 4096;

/// Maximum number of shared memory segments system-wide.
pub const MAX_SHMEM = 64;

/// Maximum pages per segment (128KB).
pub const MAX_SHMEM_PAGES = 32;

pub const Segment = struct {
    phys_pages: [MAX_SHMEM_PAGES]u64,
    page_count: u32,
    ref_count: u32,
    creator_pid: u32,
    size: u32,
    active: bool,
};

var segments: [MAX_SHMEM]Segment = [_]Segment{.{
    .phys_pages = [_]u64{0} ** MAX_SHMEM_PAGES,
    .page_count = 0,
    .ref_count = 0,
    .creator_pid = 0,
    .size = 0,
    .active = false,
}} ** MAX_SHMEM;

var lock: SpinLock = .{};

/// Create a shared memory segment. Returns shmem_id or null on failure.
pub fn create(size: u32, pid: u32) ?u32 {
    if (size == 0 or size > MAX_SHMEM_PAGES * PAGE_SIZE) return null;

    const page_count = (size + PAGE_SIZE - 1) / PAGE_SIZE;

    lock.lock();
    defer lock.unlock();

    // Find free slot
    var slot: ?u32 = null;
    for (&segments, 0..) |*seg, i| {
        if (!seg.active) {
            slot = @intCast(i);
            break;
        }
    }
    const id = slot orelse return null;

    // Allocate physical pages
    var seg = &segments[id];
    for (0..page_count) |i| {
        const phys = pmm.allocPage() orelse {
            // Free already allocated pages
            for (0..i) |j| {
                pmm.freePage(@intCast(seg.phys_pages[j]));
                seg.phys_pages[j] = 0;
            }
            return null;
        };
        seg.phys_pages[i] = @intCast(phys);
    }

    seg.page_count = @intCast(page_count);
    seg.ref_count = 1;
    seg.creator_pid = pid;
    seg.size = size;
    seg.active = true;

    return id;
}

/// Map a shared memory segment into a process's address space.
/// Returns the virtual address of the mapping, or null on failure.
pub fn map(shmem_id: u32, pml4: *paging.PageTable, mmap_next: *u64) ?u64 {
    if (shmem_id >= MAX_SHMEM) return null;

    lock.lock();
    defer lock.unlock();

    const seg = &segments[shmem_id];
    if (!seg.active) return null;

    const vaddr = mmap_next.*;
    const flags = paging.Flags.PRESENT | paging.Flags.WRITABLE | paging.Flags.USER;

    for (0..seg.page_count) |i| {
        const page_vaddr = vaddr + i * PAGE_SIZE;
        paging.mapPage(pml4, page_vaddr, seg.phys_pages[i], flags) orelse {
            // Unmap already mapped pages
            for (0..i) |j| {
                paging.unmapPage(pml4, vaddr + j * PAGE_SIZE);
            }
            return null;
        };
    }

    mmap_next.* += @as(u64, seg.page_count) * PAGE_SIZE;
    seg.ref_count += 1;

    return vaddr;
}

/// Decrement refcount. Free physical pages if refcount reaches 0.
pub fn unmap(shmem_id: u32) void {
    if (shmem_id >= MAX_SHMEM) return;

    lock.lock();
    defer lock.unlock();

    const seg = &segments[shmem_id];
    if (!seg.active) return;

    if (seg.ref_count > 0) seg.ref_count -= 1;
    if (seg.ref_count == 0) {
        freeSegment(seg);
    }
}

/// Destroy a segment (creator only). Marks for cleanup; actual free when refcount hits 0.
pub fn destroy(shmem_id: u32, pid: u32) bool {
    if (shmem_id >= MAX_SHMEM) return false;

    lock.lock();
    defer lock.unlock();

    const seg = &segments[shmem_id];
    if (!seg.active) return false;
    if (seg.creator_pid != pid) return false;

    if (seg.ref_count <= 1) {
        freeSegment(seg);
    } else {
        // Other mappers still using it; decrement creator's ref
        seg.ref_count -= 1;
    }
    return true;
}

fn freeSegment(seg: *Segment) void {
    for (0..seg.page_count) |i| {
        if (seg.phys_pages[i] != 0) {
            const phys: usize = @intCast(seg.phys_pages[i]);
            pmm.freePage(phys);
            seg.phys_pages[i] = 0;
        }
    }
    seg.page_count = 0;
    seg.ref_count = 0;
    seg.creator_pid = 0;
    seg.size = 0;
    seg.active = false;
}
