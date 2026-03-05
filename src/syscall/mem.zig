/// Memory, fd duplication, and arch-specific syscall handlers.
const process = @import("../process.zig");
const pmm = @import("../pmm.zig");
const mem = @import("../mem.zig");
const klog = @import("../klog.zig");
const paging = switch (@import("builtin").cpu.arch) {
    .x86_64 => @import("../arch/x86_64/paging.zig"),
    .riscv64 => @import("../arch/riscv64/paging.zig"),
    .aarch64 => @import("../arch/aarch64/paging.zig"),
    else => struct {},
};
const root = @import("root.zig");

const ENOSYS = root.ENOSYS;
const EBADF = root.EBADF;
const EINVAL = root.EINVAL;
const ENOMEM = root.ENOMEM;
const EMFILE = root.EMFILE;
const EACCES = root.EACCES;
const ENOENT = root.ENOENT;

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
    const arch = @import("builtin").cpu.arch;
    const proc = process.getCurrent() orelse return ENOSYS;

    const ARCH_SET_FS: u64 = 0x1002;
    if (cmd == ARCH_SET_FS) {
        proc.fs_base = addr;
        if (arch == .x86_64) {
            const cpu = @import("../arch/x86_64/cpu.zig");
            cpu.wrmsr(0xC0000100, addr); // IA32_FS_BASE
        } else if (arch == .riscv64) {
            asm volatile ("mv tp, %[v]"
                :
                : [v] "r" (addr),
            );
        } else if (arch == .aarch64) {
            asm volatile ("msr tpidr_el0, %[v]"
                :
                : [v] "r" (addr),
            );
        } else {
            return ENOSYS;
        }
        return 0;
    }
    return EINVAL;
}

/// Create a shared memory segment. arg0 = size in bytes.
/// Returns shmem_id or ENOMEM.
pub fn sysShmemCreate(size: u64) u64 {
    const shmem = @import("../shmem.zig");
    const proc = process.getCurrent() orelse return EBADF;
    if (size == 0 or size > shmem.MAX_SHMEM_PAGES * 4096) return EINVAL;
    const id = shmem.create(@intCast(size), proc.pid) orelse return ENOMEM;
    return @as(u64, id);
}

/// Map a shared memory segment into the caller's address space.
/// arg0 = shmem_id. Returns virtual address or EINVAL.
pub fn sysShmemMap(shmem_id: u64) u64 {
    const shmem = @import("../shmem.zig");
    const proc = process.getCurrent() orelse return EBADF;
    const page_table = proc.pml4 orelse return EINVAL;
    const vaddr = shmem.map(@intCast(shmem_id), page_table, &proc.mmap_next) orelse return EINVAL;
    return vaddr;
}

/// Destroy a shared memory segment (creator only). arg0 = shmem_id.
/// Returns 0 on success, EINVAL on failure.
pub fn sysShmemDestroy(shmem_id: u64) u64 {
    const shmem = @import("../shmem.zig");
    const proc = process.getCurrent() orelse return EBADF;
    if (shmem.destroy(@intCast(shmem_id), proc.pid)) return 0;
    return EINVAL;
}

/// SYS 47: mmap_device — Map physical device memory (MMIO/VRAM) into userspace.
/// Args: phys_addr, length, flags (bit 0 = write-combining, bit 1 = 2MB huge pages), prot (unused, reserved)
/// Returns: virtual address of mapping, or negative errno.
pub fn sysMmapDevice(phys_addr: u64, length: u64, flags: u64, prot: u64) u64 {
    _ = prot;
    const proc = process.getCurrent() orelse return ENOSYS;

    // Only root (uid 0) can map device memory
    if (proc.uid != 0) return EACCES;

    if (length == 0) return EINVAL;

    const use_huge = (flags & 0x2) != 0;
    const use_wc = (flags & 0x1) != 0;
    const HUGE_SIZE: u64 = 2 * 1024 * 1024; // 2MB

    // Validate alignment
    if (use_huge) {
        if (phys_addr & (HUGE_SIZE - 1) != 0) return EINVAL;
        if (length & (HUGE_SIZE - 1) != 0) return EINVAL;
    } else {
        if (phys_addr & (mem.PAGE_SIZE - 1) != 0) return EINVAL;
    }

    // Build mapping flags
    var map_flags: u64 = paging.Flags.WRITABLE | paging.Flags.USER | paging.Flags.NO_EXECUTE | paging.Flags.DEVICE_MAP;
    if (use_wc) {
        map_flags |= paging.Flags.WRITE_COMBINE;
    } else {
        map_flags |= paging.Flags.NO_CACHE;
    }

    // Get shared or local mmap_next and pml4
    const proc_pml4 = if (proc.thread_group) |tg| tg.pml4 else proc.pml4;
    const pml4 = proc_pml4 orelse return ENOMEM;

    // Lock thread group if threaded
    if (proc.thread_group) |tg| tg.lock.lock();
    defer if (proc.thread_group) |tg| tg.lock.unlock();

    var base = if (proc.thread_group) |tg| tg.mmap_next else proc.mmap_next;

    if (use_huge) {
        // Align base to 2MB boundary
        base = (base + HUGE_SIZE - 1) & ~(HUGE_SIZE - 1);
        const page_count = length / HUGE_SIZE;

        var i: u64 = 0;
        while (i < page_count) : (i += 1) {
            paging.mapHugePageUser(pml4, base + i * HUGE_SIZE, phys_addr + i * HUGE_SIZE, map_flags) orelse return ENOMEM;
        }

        const new_next = base + page_count * HUGE_SIZE;
        if (proc.thread_group) |tg| {
            tg.mmap_next = new_next;
        } else {
            proc.mmap_next = new_next;
        }
    } else {
        const page_count = (length + mem.PAGE_SIZE - 1) / mem.PAGE_SIZE;

        var i: u64 = 0;
        while (i < page_count) : (i += 1) {
            paging.mapPage(pml4, base + i * mem.PAGE_SIZE, phys_addr + i * mem.PAGE_SIZE, map_flags) orelse return ENOMEM;
        }

        const new_next = base + page_count * mem.PAGE_SIZE;
        if (proc.thread_group) |tg| {
            tg.mmap_next = new_next;
        } else {
            proc.mmap_next = new_next;
        }
    }

    return base;
}

/// SYS 48: irq_alloc — Allocate an MSI-X interrupt forward to userspace.
/// args: bus, devfn (slot<<3 | func), msix_entry_index
/// Returns fd number, or error.
pub fn sysIrqAlloc(bus_arg: u64, devfn_arg: u64, entry_arg: u64) u64 {
    const arch = @import("builtin").cpu.arch;
    if (arch != .x86_64) return ENOSYS;

    const pci = @import("../arch/x86_64/pci.zig");
    const irq_forward = @import("../irq_forward.zig");

    const proc = process.getCurrent() orelse return EBADF;

    // Only root can allocate IRQ forwards
    if (proc.uid != 0) return EACCES;

    const bus: u8 = @truncate(bus_arg);
    const devfn: u8 = @truncate(devfn_arg);
    const slot: u8 = devfn >> 3;
    const func: u8 = devfn & 7;
    const msix_entry: u16 = @truncate(entry_arg);

    // Find PCI device by BDF
    const devs = pci.getDevices();
    var dev_index: ?u16 = null;
    for (devs, 0..) |*d, i| {
        if (d.bus == bus and d.slot == slot and d.func == func) {
            dev_index = @intCast(i);
            break;
        }
    }
    const idx = dev_index orelse return ENOENT;

    // Validate MSI-X capability
    const dev = &devs[idx];
    const msix_cap = dev.msix orelse return EINVAL;
    if (msix_entry >= msix_cap.table_size) return EINVAL;

    // Allocate IRQ forward
    const result = irq_forward.alloc(idx, msix_entry, proc.pid) orelse return ENOMEM;

    // Allocate fd
    const fd_num = proc.allocDevFd(.dev_irq) orelse {
        irq_forward.free(result.slot);
        return EMFILE;
    };

    // Set irq_slot on the fd entry
    const entry_ptr = proc.getFdEntryPtr(fd_num) orelse {
        irq_forward.free(result.slot);
        return EMFILE;
    };
    entry_ptr.irq_slot = result.slot;

    klog.info("[irq_forward] Allocated vector ");
    klog.infoDec(result.vector);
    klog.info(" slot ");
    klog.infoDec(result.slot);
    klog.info(" fd ");
    klog.infoDec(fd_num);
    klog.info(" for pid ");
    klog.infoDec(proc.pid);
    klog.info("\n");

    return fd_num;
}
