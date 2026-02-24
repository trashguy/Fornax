/// Memory, fd duplication, and arch-specific syscall handlers.
const process = @import("../process.zig");
const pmm = @import("../pmm.zig");
const mem = @import("../mem.zig");
const klog = @import("../klog.zig");
const paging = switch (@import("builtin").cpu.arch) {
    .x86_64 => @import("../arch/x86_64/paging.zig"),
    .riscv64 => @import("../arch/riscv64/paging.zig"),
    else => struct {},
};
const root = @import("root.zig");

const ENOSYS = root.ENOSYS;
const EBADF = root.EBADF;
const EINVAL = root.EINVAL;
const ENOMEM = root.ENOMEM;
const EMFILE = root.EMFILE;

/// SYS 32: mmap — Anonymous memory mapping.
/// args: addr (hint, ignored), length, prot, flags
/// Returns virtual address of mapped region, or error.
pub fn sysMmap(addr_hint: u64, length: u64, prot: u64, flags: u64) u64 {
    _ = addr_hint;
    const proc = process.getCurrent() orelse return ENOSYS;

    if (length == 0) return EINVAL;

    // Only support MAP_ANONYMOUS | MAP_PRIVATE (flags bits 0x20 | 0x02)
    // Accept any combination that includes MAP_ANONYMOUS
    const MAP_ANONYMOUS: u64 = 0x20;
    if (flags & MAP_ANONYMOUS == 0) return EINVAL;

    // Round up to page boundary
    const page_count = (length + mem.PAGE_SIZE - 1) / mem.PAGE_SIZE;

    // Get shared or local mmap_next and pml4
    const proc_pml4 = if (proc.thread_group) |tg| tg.pml4 else proc.pml4;
    const pml4 = proc_pml4 orelse return ENOMEM;

    // Lock thread group if threaded
    if (proc.thread_group) |tg| tg.lock.lock();
    defer if (proc.thread_group) |tg| tg.lock.unlock();

    const base = if (proc.thread_group) |tg| tg.mmap_next else proc.mmap_next;

    var i: u64 = 0;
    while (i < page_count) : (i += 1) {
        const page = pmm.allocPage() orelse return ENOMEM;
        // Zero the page
        const ptr: [*]u8 = paging.physPtr(page);
        @memset(ptr[0..mem.PAGE_SIZE], 0);
        // Map with user + writable (+ exec based on prot)
        var map_flags: u64 = paging.Flags.WRITABLE | paging.Flags.USER;
        const PROT_EXEC: u64 = 0x4;
        if (prot & PROT_EXEC != 0) {
            map_flags |= paging.Flags.EXEC;
        }
        paging.mapPage(pml4, base + i * mem.PAGE_SIZE, page, map_flags) orelse return ENOMEM;
        proc.pages_used += 1;
    }

    const new_next = base + page_count * mem.PAGE_SIZE;
    if (proc.thread_group) |tg| {
        tg.mmap_next = new_next;
    } else {
        proc.mmap_next = new_next;
    }
    return base;
}

/// SYS 33: munmap — Unmap memory region.
/// Currently a no-op (acceptable leak for Phase 1000).
pub fn sysMunmap(addr: u64, length: u64) u64 {
    _ = addr;
    _ = length;
    // Don't free physical pages — acceptable for single-threaded POSIX programs.
    return 0;
}

/// SYS 34: dup — Duplicate file descriptor to lowest free slot.
pub fn sysDup(old_fd: u64) u64 {
    const proc = process.getCurrent() orelse return ENOSYS;
    if (old_fd >= process.MAX_FDS) return EBADF;
    const fds = process.thread_group.getFdSlice(proc);
    const entry = fds[@intCast(old_fd)] orelse return EBADF;

    // Find lowest free fd
    for (0..process.MAX_FDS) |i| {
        if (fds[i] == null) {
            fds[i] = entry;
            // Increment pipe refcounts if applicable
            if (entry.fd_type == .pipe) {
                const pipe_mod = @import("../pipe.zig");
                if (entry.pipe_is_read) {
                    pipe_mod.incrementReaders(entry.pipe_id);
                } else {
                    pipe_mod.incrementWriters(entry.pipe_id);
                }
            }
            if (entry.fd_type == .dev_ether) {
                @import("../ether.zig").incRefClient(entry.ether_client);
            }
            return @intCast(i);
        }
    }
    return EMFILE;
}

/// SYS 35: dup2 — Duplicate old_fd to new_fd (closing new_fd first if open).
pub fn sysDup2(old_fd: u64, new_fd: u64) u64 {
    const proc = process.getCurrent() orelse return ENOSYS;
    if (old_fd >= process.MAX_FDS or new_fd >= process.MAX_FDS) return EBADF;
    const fds = process.thread_group.getFdSlice(proc);
    const entry = fds[@intCast(old_fd)] orelse return EBADF;

    // If same fd, just return it
    if (old_fd == new_fd) return new_fd;

    // Close new_fd if open
    if (fds[@intCast(new_fd)]) |existing| {
        if (existing.fd_type == .pipe) {
            const pipe_mod2 = @import("../pipe.zig");
            if (existing.pipe_is_read) {
                pipe_mod2.closeReadEnd(existing.pipe_id);
            } else {
                pipe_mod2.closeWriteEnd(existing.pipe_id);
            }
        }
        if (existing.fd_type == .dev_ether) {
            @import("../ether.zig").freeClient(existing.ether_client);
        }
        fds[@intCast(new_fd)] = null;
    }

    fds[@intCast(new_fd)] = entry;
    // Increment pipe refcounts
    if (entry.fd_type == .pipe) {
        const pipe_mod2 = @import("../pipe.zig");
        if (entry.pipe_is_read) {
            pipe_mod2.incrementReaders(entry.pipe_id);
        } else {
            pipe_mod2.incrementWriters(entry.pipe_id);
        }
    }
    if (entry.fd_type == .dev_ether) {
        @import("../ether.zig").incRefClient(entry.ether_client);
    }
    return new_fd;
}

/// SYS 36: arch_prctl — Set/get architecture-specific thread state.
/// cmd: ARCH_SET_FS (0x1002) to set FS base for TLS.
pub fn sysArchPrctl(cmd: u64, addr: u64) u64 {
    if (@import("builtin").cpu.arch != .x86_64) return ENOSYS;
    const cpu = @import("../arch/x86_64/cpu.zig");
    const proc = process.getCurrent() orelse return ENOSYS;

    const ARCH_SET_FS: u64 = 0x1002;
    if (cmd == ARCH_SET_FS) {
        proc.fs_base = addr;
        cpu.wrmsr(0xC0000100, addr); // IA32_FS_BASE
        return 0;
    }
    return EINVAL;
}
