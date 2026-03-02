/// Process lifecycle syscall handlers: exit, wait, getpid, spawn, exec,
/// rfork, clone, brk, setuid, getuid.
const process = @import("../process.zig");
const ipc = @import("../ipc.zig");
const elf = @import("../elf.zig");
const pmm = @import("../pmm.zig");
const mem = @import("../mem.zig");
const klog = @import("../klog.zig");
const namespace = @import("../namespace.zig");
const paging = switch (@import("builtin").cpu.arch) {
    .x86_64 => @import("../arch/x86_64/paging.zig"),
    .riscv64 => @import("../arch/riscv64/paging.zig"),
    .aarch64 => @import("../arch/aarch64/paging.zig"),
    else => struct {},
};
const root = @import("root.zig");

const ENOSYS = root.ENOSYS;
const EBADF = root.EBADF;
const EFAULT = root.EFAULT;
const ENOENT = root.ENOENT;
const EMFILE = root.EMFILE;
const EIO = root.EIO;
const ENOMEM = root.ENOMEM;
const EINVAL = root.EINVAL;
const writeU32LE = root.writeU32LE;
const writeU64LE = root.writeU64LE;
const sendToServer = root.sendToServer;
const FdMapping = root.FdMapping;

/// Static buffer for building argv layout (in .bss to avoid kernel stack use).
/// Max 4096 bytes — one page for argv data.
pub var argv_layout_buf: [4096]u8 linksection(".bss") = undefined;

/// Write data to a child process's virtual address by translating through its page tables.
/// The kernel runs under the parent's CR3, so we can't dereference child addresses directly.
pub fn writeToChildMem(child_pml4: *paging.PageTable, vaddr: u64, data: []const u8) bool {
    var offset: usize = 0;
    while (offset < data.len) {
        const page_offset = (vaddr + offset) & 0xFFF;
        const chunk = @min(data.len - offset, mem.PAGE_SIZE - page_offset);

        const phys = paging.translateVaddr(child_pml4, vaddr + offset) orelse return false;
        const dest: [*]u8 = paging.physPtr(phys & ~@as(u64, 0xFFF));
        @memcpy(dest[page_offset..][0..chunk], data[offset..][0..chunk]);
        offset += chunk;
    }
    return true;
}

/// Helper: set up argv layout in child process address space from wire format.
pub fn setupArgv(child_pml4: *paging.PageTable, argv_ptr: u64, child: *process.Process) void {
    const wire: [*]const u8 = @ptrFromInt(argv_ptr);
    const wire_argc = @as(u32, wire[0]) |
        (@as(u32, wire[1]) << 8) |
        (@as(u32, wire[2]) << 16) |
        (@as(u32, wire[3]) << 24);
    const wire_total = @as(u32, wire[4]) |
        (@as(u32, wire[5]) << 8) |
        (@as(u32, wire[6]) << 16) |
        (@as(u32, wire[7]) << 24);

    if (wire_argc > 0 and wire_argc <= 64 and wire_total > 0 and wire_total <= 3000) {
        const header_size: usize = 8 + @as(usize, wire_argc) * 8;
        const total_size = header_size + wire_total;

        if (total_size <= argv_layout_buf.len) {
            @memset(argv_layout_buf[0..total_size], 0);

            const argc64: u64 = wire_argc;
            argv_layout_buf[0] = @truncate(argc64);
            argv_layout_buf[1] = @truncate(argc64 >> 8);
            argv_layout_buf[2] = @truncate(argc64 >> 16);
            argv_layout_buf[3] = @truncate(argc64 >> 24);
            argv_layout_buf[4] = @truncate(argc64 >> 32);
            argv_layout_buf[5] = @truncate(argc64 >> 40);
            argv_layout_buf[6] = @truncate(argc64 >> 48);
            argv_layout_buf[7] = @truncate(argc64 >> 56);

            const strings_start: usize = header_size;
            @memcpy(argv_layout_buf[strings_start..][0..wire_total], wire[8..][0..wire_total]);

            var str_offset: usize = 0;
            var arg_i: usize = 0;
            while (arg_i < wire_argc and str_offset < wire_total) {
                const str_vaddr: u64 = mem.ARGV_BASE + strings_start + str_offset;
                const ptr_offset = 8 + arg_i * 8;
                argv_layout_buf[ptr_offset] = @truncate(str_vaddr);
                argv_layout_buf[ptr_offset + 1] = @truncate(str_vaddr >> 8);
                argv_layout_buf[ptr_offset + 2] = @truncate(str_vaddr >> 16);
                argv_layout_buf[ptr_offset + 3] = @truncate(str_vaddr >> 24);
                argv_layout_buf[ptr_offset + 4] = @truncate(str_vaddr >> 32);
                argv_layout_buf[ptr_offset + 5] = @truncate(str_vaddr >> 40);
                argv_layout_buf[ptr_offset + 6] = @truncate(str_vaddr >> 48);
                argv_layout_buf[ptr_offset + 7] = @truncate(str_vaddr >> 56);

                while (str_offset < wire_total and argv_layout_buf[strings_start + str_offset] != 0) {
                    str_offset += 1;
                }
                str_offset += 1;
                arg_i += 1;
            }

            _ = writeToChildMem(child_pml4, mem.ARGV_BASE, argv_layout_buf[0..total_size]);
        }
    }

    child.user_rsp = mem.ARGV_BASE - 8;

    // Set process name from argv[0] basename
    setNameFromArgv(argv_ptr, child);
}

/// Set process name from the basename of argv[0] in the wire argv format.
pub fn setNameFromArgv(argv_ptr: u64, child: *process.Process) void {
    if (argv_ptr != 0 and argv_ptr < 0x0000_8000_0000_0000) {
        const w: [*]const u8 = @ptrFromInt(argv_ptr);
        const wargc = @as(u32, w[0]) |
            (@as(u32, w[1]) << 8) |
            (@as(u32, w[2]) << 16) |
            (@as(u32, w[3]) << 24);
        const wtotal = @as(u32, w[4]) |
            (@as(u32, w[5]) << 8) |
            (@as(u32, w[6]) << 16) |
            (@as(u32, w[7]) << 24);
        if (wargc > 0 and wtotal > 0 and wtotal <= 3000) {
            const str = w[8..][0..wtotal];
            var str_end: usize = 0;
            while (str_end < str.len and str[str_end] != 0) : (str_end += 1) {}
            var base_start: usize = 0;
            for (0..str_end) |si| {
                if (str[si] == '/') base_start = si + 1;
            }
            const basename = str[base_start..str_end];
            const copy_len = @min(basename.len, 15);
            @memset(&child.name, 0);
            @memcpy(child.name[0..copy_len], basename[0..copy_len]);
        }
    }
}

/// Copy file descriptor table from parent to child, incrementing pipe refcounts.
fn copyFdTable(parent: *process.Process, child: *process.Process) void {
    const pipe_mod = @import("../pipe.zig");
    const ether_mod = @import("../ether.zig");
    const fds = process.thread_group.getFdSlice(parent);
    for (0..process.MAX_FDS) |i| {
        if (fds[i]) |fentry| {
            child.fds[i] = fentry;
            if (fentry.fd_type == .pipe) {
                if (fentry.pipe_is_read) {
                    pipe_mod.incrementReaders(fentry.pipe_id);
                } else {
                    pipe_mod.incrementWriters(fentry.pipe_id);
                }
            }
            if (fentry.fd_type == .dev_ether) {
                ether_mod.incRefClient(fentry.ether_client);
            }
        }
    }
}

/// exit(status) — terminate the current process and schedule next.
pub fn sysExit(status: u64) noreturn {
    const proc = process.getCurrent() orelse process.scheduleNext();

    @import("../trace.zig").trace(.process_exit, proc.pid);

    klog.debug("[Process ");
    klog.debugDec(proc.pid);
    klog.debug(" exited with status ");
    klog.debugDec(status);
    klog.debug("]\n");

    proc.exit_status = @truncate(status);

    // Check if this is a supervised service exiting
    _ = @import("../supervisor.zig").handleProcessExit(proc.pid);

    // Decrement process group count
    if (proc.group_id != 0xFF) {
        const pg = @import("../process_group.zig");
        if (pg.getById(proc.group_id)) |g| {
            pg.removeProcess(g);
        }
    }

    // Kill all children recursively (Fornax orphan policy)
    process.killChildren(proc.pid);

    // Exit group: kill all sibling threads in the same thread group
    if (proc.thread_group) |tg| {
        const futex_mod = @import("../futex.zig");
        const table = process.getProcessTable();
        for (table) |*p| {
            if (p != proc and p.thread_group == tg and p.state != .free) {
                // Handle CLONE_CHILD_CLEARTID for the sibling
                if (p.ctid_ptr != 0 and p.ctid_ptr < 0x0000_8000_0000_0000) {
                    const pml4_phys: u64 = if (tg.pml4) |pm| @intFromPtr(pm) else 0;
                    // Can't write to user memory here (wrong CR3), but wake futex
                    futex_mod.wakeOne(pml4_phys, p.ctid_ptr);
                    p.ctid_ptr = 0;
                }
                p.state = .dead;
                p.thread_group = null;
                p.pml4 = null; // Clear dangling shared address space pointer
                // Release the group ref for this sibling
                _ = process.thread_group.releaseGroup(tg, p);
            }
        }
    }

    // Close all pipe fds (decrement refcounts, wake blocked peers).
    // For threads: only close pipes if this is the last thread in the group
    // (otherwise sibling threads may still need the shared fds).
    const is_last_thread = if (proc.thread_group) |tg| blk: {
        tg.lock.lock();
        const last = tg.ref_count <= 1;
        tg.lock.unlock();
        break :blk last;
    } else true;

    if (is_last_thread) {
        const pipe_mod = @import("../pipe.zig");
        const ether_mod = @import("../ether.zig");
        const fds = process.thread_group.getFdSlice(proc);
        for (0..process.MAX_FDS) |i| {
            if (fds[i]) |entry| {
                if (entry.fd_type == .pipe) {
                    if (entry.pipe_is_read) {
                        pipe_mod.closeReadEnd(entry.pipe_id);
                    } else {
                        pipe_mod.closeWriteEnd(entry.pipe_id);
                    }
                    fds[i] = null;
                }
                if (entry.fd_type == .dev_ether) {
                    ether_mod.freeClient(entry.ether_client);
                    fds[i] = null;
                }
                // IPC (server-backed) fd: send fire-and-forget T_CLOSE so
                // the server frees its handle.  Only send if a server
                // worker is waiting (fast-path delivery), which avoids
                // pointer aliasing when multiple fds reuse proc.ipc_msg.
                // The server's reply targets a dead process — sysIpcReply
                // handles this gracefully (getByPid returns null → returns 0).
                // NOTE: We only send T_CLOSE for one fd per channel to avoid
                // pointer aliasing — sendToServer stores &proc.ipc_msg, so a
                // second send would overwrite the first message before the
                // server dequeues it.
                if (entry.server_handle > 0) {
                    if (ipc.getChannel(entry.channel_id)) |chan| {
                        chan.lock.lock();
                        const has_waiter = chan.client.server_waiter_count > 0 or
                            (chan.client.recv_waiting and chan.client.blocked_pid != 0);
                        const queue_empty = chan.client.pending_count == 0;
                        chan.lock.unlock();
                        if (has_waiter and queue_empty) {
                            proc.ipc_msg.reset(.t_close);
                            writeU32LE(proc.ipc_msg.data_buf[0..4], entry.server_handle);
                            proc.ipc_msg.data_len = 4;
                            sendToServer(chan, proc);
                        }
                    }
                    fds[i] = null;
                }
            }
        }
    }

    // CLONE_CHILD_CLEARTID: clear tid at user address and futex-wake joiners.
    // Must happen before freeUserMemory (user address space still active).
    if (proc.ctid_ptr != 0 and proc.ctid_ptr < 0x0000_8000_0000_0000) {
        const futex_mod = @import("../futex.zig");
        const ptr: *volatile u32 = @ptrFromInt(proc.ctid_ptr);
        ptr.* = 0;
        // Get PML4 physical address for futex identity
        const pml4_phys: u64 = if (proc.thread_group) |tg|
            (if (tg.pml4) |p| @intFromPtr(p) else 0)
        else
            (if (proc.pml4) |p| @intFromPtr(p) else 0);
        futex_mod.wakeOne(pml4_phys, proc.ctid_ptr);
        proc.ctid_ptr = 0;
    }

    // Free user address space (safe: we're on the kernel stack, not user memory)
    process.freeUserMemory(proc);

    // Kernel stack: deferred free — we're still running on it.
    // It gets freed when the parent reaps us (sysWait) or when the
    // process slot is reused.
    proc.needs_stack_free = true;

    // Check if parent exists and is waiting for us
    if (proc.parent_pid) |ppid| {
        if (process.getByPid(ppid)) |parent| {
            if (parent.state == .blocked) {
                if (parent.waiting_for_pid) |wait_pid| {
                    // Parent is waiting for us specifically, or any child (0)
                    if (wait_pid == proc.pid or wait_pid == 0) {
                        // Wake parent with POSIX-packed status:
                        // upper 32 bits = child pid, lower 32 bits = (exit_code << 8)
                        const child_pid: u64 = proc.pid;
                        parent.syscall_ret = (child_pid << 32) | ((status & 0xFF) << 8);
                        process.markReady(parent);
                        parent.waiting_for_pid = null;
                        // Parent already notified — orphan zombie.
                        // We can't set .free here because we're still on
                        // this process's kernel stack. process.create()
                        // reclaims orphan zombies (.zombie + null parent).
                        proc.state = .zombie;
                        proc.parent_pid = null;
                        process.scheduleNext();
                    }
                }
            }
            // Parent exists but is dead/free — orphan the zombie for reclamation
            if (parent.state == .dead or parent.state == .free or parent.state == .zombie) {
                proc.state = .zombie;
                proc.parent_pid = null;
                process.scheduleNext();
            }
            // Parent exists but not waiting — become zombie (parent will reap later)
            proc.state = .zombie;
            process.scheduleNext();
        }
    }

    // No parent (kernel-spawned or orphaned) — orphan zombie.
    // Same as above: can't set .free while on this kernel stack.
    proc.state = .zombie;
    proc.parent_pid = null;
    process.scheduleNext();
}

/// Thread-only exit (syscall 41). Exits only the calling thread without
/// killing siblings in the thread group. This is the `exit()` counterpart
/// to the `exit_group()` semantics of sysExit.
pub fn sysThreadExit(status: u64) noreturn {
    const proc = process.getCurrent() orelse process.scheduleNext();

    klog.debug("[Thread ");
    klog.debugDec(proc.pid);
    klog.debug(" exited with status ");
    klog.debugDec(status);
    klog.debug("]\n");

    proc.exit_status = @truncate(status);

    // CLONE_CHILD_CLEARTID: clear tid at user address and futex-wake joiners.
    // Must happen before freeUserMemory (user address space still active).
    if (proc.ctid_ptr != 0 and proc.ctid_ptr < 0x0000_8000_0000_0000) {
        const futex_mod = @import("../futex.zig");
        const ptr: *volatile u32 = @ptrFromInt(proc.ctid_ptr);
        ptr.* = 0;
        const pml4_phys: u64 = if (proc.thread_group) |tg|
            (if (tg.pml4) |p| @intFromPtr(p) else 0)
        else
            (if (proc.pml4) |p| @intFromPtr(p) else 0);
        futex_mod.wakeOne(pml4_phys, proc.ctid_ptr);
        proc.ctid_ptr = 0;
    }

    // Close pipe/ether fds only if this is the last thread in the group
    // (otherwise sibling threads may still need the shared fds).
    const is_last_thread = if (proc.thread_group) |tg| blk: {
        tg.lock.lock();
        const last = tg.ref_count <= 1;
        tg.lock.unlock();
        break :blk last;
    } else true;

    if (is_last_thread) {
        const pipe_mod = @import("../pipe.zig");
        const ether_mod = @import("../ether.zig");
        const fds = process.thread_group.getFdSlice(proc);
        for (0..process.MAX_FDS) |i| {
            if (fds[i]) |entry| {
                if (entry.fd_type == .pipe) {
                    if (entry.pipe_is_read) {
                        pipe_mod.closeReadEnd(entry.pipe_id);
                    } else {
                        pipe_mod.closeWriteEnd(entry.pipe_id);
                    }
                    fds[i] = null;
                }
                if (entry.fd_type == .dev_ether) {
                    ether_mod.freeClient(entry.ether_client);
                    fds[i] = null;
                }
                if (entry.server_handle > 0) {
                    if (ipc.getChannel(entry.channel_id)) |chan| {
                        chan.lock.lock();
                        const has_waiter = chan.client.server_waiter_count > 0 or
                            (chan.client.recv_waiting and chan.client.blocked_pid != 0);
                        const queue_empty = chan.client.pending_count == 0;
                        chan.lock.unlock();
                        if (has_waiter and queue_empty) {
                            proc.ipc_msg.reset(.t_close);
                            writeU32LE(proc.ipc_msg.data_buf[0..4], entry.server_handle);
                            proc.ipc_msg.data_len = 4;
                            sendToServer(chan, proc);
                        }
                    }
                    fds[i] = null;
                }
            }
        }
    }

    // Free user address space (releases thread group ref; last thread frees address space)
    process.freeUserMemory(proc);

    // Kernel stack: deferred free — we're still running on it.
    proc.needs_stack_free = true;

    // Orphan zombie — no parent waking, no sibling killing.
    proc.state = .zombie;
    proc.parent_pid = null;
    process.scheduleNext();
}

/// brk(new_brk) — adjust program break (heap top).
/// If new_brk == 0, return current brk. Otherwise, expand heap by allocating
/// and mapping pages for the new region, checking quotas.
pub fn sysBrk(new_brk: u64) u64 {
    const proc = process.getCurrent() orelse return 0;

    // Lock thread group if threaded
    if (proc.thread_group) |tg| tg.lock.lock();
    defer if (proc.thread_group) |tg| tg.lock.unlock();

    const cur_brk = if (proc.thread_group) |tg| tg.brk else proc.brk;

    // Query current brk
    if (new_brk == 0) return cur_brk;

    // Only allow growing, not shrinking
    if (new_brk <= cur_brk) return cur_brk;

    // Validate: brk must stay in user space
    if (new_brk >= 0x0000_8000_0000_0000) return cur_brk;

    const page_size = mem.PAGE_SIZE;
    const old_brk_page = (cur_brk + page_size - 1) / page_size;
    const new_brk_page = (new_brk + page_size - 1) / page_size;

    const proc_pml4 = if (proc.thread_group) |tg| tg.pml4 else proc.pml4;
    const pml4 = proc_pml4 orelse return cur_brk;

    // Allocate and map new pages
    var page_idx = old_brk_page;
    while (page_idx < new_brk_page) : (page_idx += 1) {
        if (proc.pages_used >= proc.quotas.max_memory_pages) {
            klog.debug("[brk: quota exceeded]\n");
            return cur_brk; // return old brk on failure
        }
        const page = pmm.allocPage() orelse {
            klog.debug("[brk: out of memory]\n");
            return cur_brk;
        };
        const ptr: [*]u8 = paging.physPtr(page);
        @memset(ptr[0..page_size], 0);
        const vaddr = page_idx * page_size;
        paging.mapPage(pml4, vaddr, page, paging.Flags.WRITABLE | paging.Flags.USER) orelse {
            pmm.freePage(page);
            return cur_brk;
        };
        proc.pages_used += 1;
    }

    if (proc.thread_group) |tg| {
        tg.brk = new_brk;
    } else {
        proc.brk = new_brk;
    }
    return new_brk;
}

pub fn sysWait(pid_arg: u64, flags_arg: u64) u64 {
    const proc = process.getCurrent() orelse return ENOSYS;
    const wait_pid: u32 = @truncate(pid_arg);
    const wnohang = (flags_arg & 1) != 0;

    // Treat pid==-1 (0xFFFFFFFF truncated) as "any child" like pid==0
    const effective_pid: u32 = if (wait_pid == 0xFFFFFFFF) 0 else wait_pid;

    // Check for an already-exited (zombie or dead) child first.
    // .zombie = normal exit via sysExit; .dead = killed by fault handler.
    var found_child = false;
    const processes_slice = process.getProcessTable();
    for (processes_slice) |*p| {
        if (p.parent_pid) |ppid| {
            if (ppid == proc.pid) {
                found_child = true;
                if (p.state == .zombie or p.state == .dead) {
                    if (effective_pid == 0 or p.pid == effective_pid) {
                        // Reap this child — free deferred kernel stack
                        const exit_code: u64 = p.exit_status;
                        if (p.needs_stack_free) {
                            process.freeKernelStack(p);
                            p.needs_stack_free = false;
                        }
                        p.state = .free;
                        const child_pid: u64 = p.pid;
                        p.parent_pid = null;
                        // POSIX-style packed return: upper 32 = child pid, lower 32 = status word
                        return (child_pid << 32) | ((exit_code & 0xFF) << 8);
                    }
                }
            }
        }
    }

    // If waiting for a specific child, verify it exists and belongs to us
    if (effective_pid != 0) {
        if (process.getByPid(effective_pid)) |child| {
            if (child.parent_pid) |ppid| {
                if (ppid != proc.pid) return EINVAL; // not our child
            } else {
                return EINVAL; // no parent — not our child
            }
        } else {
            return EINVAL; // no such process
        }
    } else if (!found_child) {
        return EINVAL; // no children at all
    }

    // WNOHANG: return 0 immediately if no zombie ready
    if (wnohang) return 0;

    // No zombie found — block until a child exits
    proc.state = .blocked;
    proc.waiting_for_pid = effective_pid;
    klog.debug("[pid=");
    klog.debugDec(proc.pid);
    klog.debug(" blocked in wait");
    if (effective_pid != 0) {
        klog.debug(" for pid=");
        klog.debugDec(effective_pid);
    }
    klog.debug("]\n");
    process.scheduleNext();
}

pub fn sysGetpid(which: u64) u64 {
    const proc = process.getCurrent() orelse return ENOSYS;
    if (which == 1) {
        // getppid
        return if (proc.parent_pid) |ppid| ppid else 0;
    }
    return proc.pid;
}

/// setuid(uid, gid) — set process uid and gid. Only root (uid 0) can call this.
pub fn sysSetuid(uid: u64, gid: u64) u64 {
    const proc = process.getCurrent() orelse return ENOSYS;
    if (proc.uid != 0) return EINVAL;
    proc.uid = @truncate(uid);
    proc.gid = @truncate(gid);
    return 0;
}

/// getuid() — returns uid in low 16 bits, gid in bits 16-31.
pub fn sysGetuid() u64 {
    const proc = process.getCurrent() orelse return ENOSYS;
    return @as(u64, proc.uid) | (@as(u64, proc.gid) << 16);
}

/// clone(stack_top, tls, ctid_ptr, ptid_ptr, flags) → child tid (or error)
///
/// Creates a new thread sharing the parent's address space via ThreadGroup.
/// The child resumes at the same RIP as the parent (the instruction after syscall),
/// but with RAX=0, RSP=stack_top, and FS_BASE=tls.
///
/// musl's __clone asm pushes func+arg onto the new stack before calling clone.
/// The child pops them off and calls func(arg) — we just set up the register state.
pub fn sysClone(stack_top: u64, tls: u64, ctid_ptr: u64, ptid_ptr: u64, flags: u64) u64 {
    _ = flags;
    const parent = process.getCurrent() orelse return ENOSYS;

    const child = process.createThread(parent) orelse return ENOMEM;

    // Child resumes at instruction after the syscall.
    // On x86_64, user_rip already points past SYSCALL (hardware sets RCX = next RIP).
    // On aarch64, hardware sets ELR_EL1 past SVC (preferred return address), same as x86_64.
    // On riscv64, SEPC points AT the ecall instruction, so add 4 to skip it.
    child.user_rip = parent.user_rip + switch (@import("builtin").cpu.arch) {
        .riscv64 => 4,
        else => 0,
    };
    child.user_rsp = stack_top;
    child.user_rflags = parent.user_rflags;
    child.syscall_ret = 0; // child sees RAX=0
    child.saved_kernel_rsp = 0; // first-run via IRETQ
    child.fs_base = tls; // new thread's TLS (CLONE_SETTLS)

    // CLONE_CHILD_CLEARTID: store ctid_ptr for futex wake on exit
    if (ctid_ptr != 0) {
        child.ctid_ptr = ctid_ptr;
    }

    // CLONE_PARENT_SETTID: write child PID to parent's ptid_ptr
    if (ptid_ptr != 0 and ptid_ptr < 0x0000_8000_0000_0000) {
        const ptr: *u32 = @ptrFromInt(ptid_ptr);
        ptr.* = child.pid;
    }

    klog.debug("[clone: parent=");
    klog.debugDec(parent.pid);
    klog.debug(" child=");
    klog.debugDec(child.pid);
    klog.debug(" stack=");
    klog.debugHex(stack_top);
    klog.debug(" tls=");
    klog.debugHex(tls);
    klog.debug("]\n");

    // Thread is fully initialized — now safe for another core to schedule it.
    process.markReady(child);

    return child.pid;
}

/// SYS 11: rfork — Resource fork (Plan 9 process control).
pub fn sysRfork(flags: u64) u64 {
    const RFPROC: u64 = 0x01;
    const RFCFDG: u64 = 0x04;
    const RFNAMEG: u64 = 0x08;
    const RFMEM: u64 = 0x10;

    const parent = process.getCurrent() orelse return ENOSYS;

    if (flags & RFPROC != 0) {
        // --- Create a new process (fork) ---

        // Find a free process slot
        const child = blk: {
            process.table_lock.lock();
            defer process.table_lock.unlock();
            for (process.getProcessTable()) |*p| {
                if (p.state == .free) {
                    p.state = .blocked; // claim slot
                    break :blk p;
                }
            }
            break :blk null;
        } orelse return ENOMEM;

        // Free deferred kernel stack from previous incarnation
        if (child.needs_stack_free) {
            process.freeKernelStack(child);
            child.needs_stack_free = false;
        }

        // Allocate kernel stack (contiguous — higher-half is direct phys→virt)
        const stack_base: u64 = pmm.allocContiguousPages(process.KERNEL_STACK_PAGES) orelse return ENOMEM;
        const stack_virt = if (paging.isInitialized()) stack_base + mem.KERNEL_VIRT_BASE else stack_base;

        // Address space: deep-copy or share
        if (flags & RFMEM != 0) {
            // Share address space (vfork-like)
            child.pml4 = parent.pml4;
        } else {
            // Full deep copy (fork)
            child.pml4 = paging.deepCopyAddressSpace(parent.pml4.?) orelse return ENOMEM;
        }

        // Set up child process state
        child.pid = @atomicRmw(u32, &process.next_pid, .Add, 1, .monotonic);
        child.kernel_stack_top = stack_virt + process.KERNEL_STACK_PAGES * mem.PAGE_SIZE;
        child.user_rip = parent.user_rip;
        child.user_rsp = parent.user_rsp;
        child.user_rflags = parent.user_rflags;
        child.saved_kernel_rsp = 0; // Force IRETQ path (first run)
        child.syscall_ret = 0; // Child sees 0 from fork
        child.brk = parent.brk;
        child.mmap_next = parent.mmap_next;
        child.fs_base = parent.fs_base;
        child.uid = parent.uid;
        child.gid = parent.gid;
        child.vt = parent.vt;
        child.parent_pid = parent.pid;
        child.exit_status = 0;
        child.waiting_for_pid = null;
        child.pending_op = .none;
        child.pending_fd = 0;
        child.needs_stack_free = false;
        child.sleep_until = 0;
        child.pages_used = 0;
        child.quotas = .{};
        child.ipc_recv_buf_ptr = 0;
        child.ipc_pending_msg = null;
        child.thread_group = null;
        child.ctid_ptr = 0;
        child.ipc_msg.reset(.t_open);

        // File descriptor table
        if (flags & RFCFDG != 0) {
            // Clean fd table
            child.fds = [_]?process.FdEntry{null} ** process.MAX_FDS;
        } else {
            // Copy fd table (default, or RFFDG explicitly)
            copyFdTable(parent, child);
        }

        // Namespace
        if (flags & RFNAMEG != 0) {
            namespace.getRootNamespace().cloneInto(&child.ns);
        } else {
            parent.getNs().cloneInto(&child.ns);
        }

        // Assign to least-loaded core
        child.assigned_core = process.leastLoadedCore();
        child.core_affinity = -1;
        child.cores_ran_on = 0;

        // Mark ready — child will be scheduled
        process.markReady(child);

        klog.debug("[rfork: parent=");
        klog.debugDec(parent.pid);
        klog.debug(" child=");
        klog.debugDec(child.pid);
        klog.debug(" flags=");
        klog.debugHex(flags);
        klog.debug("]\n");

        // Parent gets child pid
        return child.pid;
    }

    // No RFPROC — modify current process
    if (flags & RFNAMEG != 0) {
        // Namespace isolation (existing behavior)
        return 0;
    }

    klog.warn("syscall: rfork unimplemented flags=");
    klog.warnDec(flags);
    klog.warn("\n");
    return ENOSYS;
}

pub fn sysExec(elf_ptr: u64, elf_len: u64, argv_ptr: u64) u64 {
    const proc = process.getCurrent() orelse return ENOSYS;

    // Validate pointer not in kernel space
    if (elf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    if (elf_len == 0 or elf_len > 4 * 1024 * 1024) return EINVAL;

    const elf_data: []const u8 = @as([*]const u8, @ptrFromInt(elf_ptr))[0..@intCast(elf_len)];

    // Create fresh address space (kernel mappings + identity map)
    const new_pml4 = paging.createAddressSpace() orelse return ENOMEM;

    // Load ELF into new address space
    // CR3 still has old PML4, so elf_data (user ptr) is readable
    const load_result = elf.load(new_pml4, elf_data) catch {
        // New PML4 + any partially allocated pages leaked (future cleanup)
        proc.state = .dead;
        process.scheduleNext(); // noreturn
    };

    // Allocate user stack in new address space
    const stack_top = mem.USER_STACK_TOP;
    for (0..process.USER_STACK_PAGES) |i| {
        const page = pmm.allocPage() orelse {
            proc.state = .dead;
            process.scheduleNext();
        };
        const page_ptr: [*]u8 = paging.physPtr(page);
        @memset(page_ptr[0..mem.PAGE_SIZE], 0);
        const vaddr = stack_top - (process.USER_STACK_PAGES - i) * mem.PAGE_SIZE;
        paging.mapPage(new_pml4, vaddr, page, paging.Flags.WRITABLE | paging.Flags.USER) orelse {
            proc.state = .dead;
            process.scheduleNext();
        };
    }

    // Handle argv if provided (wire format from parent's old address space)
    if (argv_ptr != 0 and argv_ptr < 0x0000_8000_0000_0000) {
        const wire: [*]const u8 = @ptrFromInt(argv_ptr);
        const wire_argc = @as(u32, wire[0]) |
            (@as(u32, wire[1]) << 8) |
            (@as(u32, wire[2]) << 16) |
            (@as(u32, wire[3]) << 24);
        const wire_total = @as(u32, wire[4]) |
            (@as(u32, wire[5]) << 8) |
            (@as(u32, wire[6]) << 16) |
            (@as(u32, wire[7]) << 24);

        if (wire_argc > 0 and wire_argc <= 64 and wire_total > 0 and wire_total <= 3000) {
            const header_size: usize = 8 + @as(usize, wire_argc) * 8;
            const total_size = header_size + wire_total;

            if (total_size <= argv_layout_buf.len) {
                @memset(argv_layout_buf[0..total_size], 0);

                // Write argc as u64
                const argc64: u64 = wire_argc;
                argv_layout_buf[0] = @truncate(argc64);
                argv_layout_buf[1] = @truncate(argc64 >> 8);
                argv_layout_buf[2] = @truncate(argc64 >> 16);
                argv_layout_buf[3] = @truncate(argc64 >> 24);
                argv_layout_buf[4] = @truncate(argc64 >> 32);
                argv_layout_buf[5] = @truncate(argc64 >> 40);
                argv_layout_buf[6] = @truncate(argc64 >> 48);
                argv_layout_buf[7] = @truncate(argc64 >> 56);

                // Copy string data from wire format
                const strings_start: usize = header_size;
                @memcpy(argv_layout_buf[strings_start..][0..wire_total], wire[8..][0..wire_total]);

                // Build pointer array
                var str_offset: usize = 0;
                var arg_i: usize = 0;
                while (arg_i < wire_argc and str_offset < wire_total) {
                    const str_vaddr: u64 = mem.ARGV_BASE + strings_start + str_offset;
                    const ptr_offset = 8 + arg_i * 8;
                    argv_layout_buf[ptr_offset] = @truncate(str_vaddr);
                    argv_layout_buf[ptr_offset + 1] = @truncate(str_vaddr >> 8);
                    argv_layout_buf[ptr_offset + 2] = @truncate(str_vaddr >> 16);
                    argv_layout_buf[ptr_offset + 3] = @truncate(str_vaddr >> 24);
                    argv_layout_buf[ptr_offset + 4] = @truncate(str_vaddr >> 32);
                    argv_layout_buf[ptr_offset + 5] = @truncate(str_vaddr >> 40);
                    argv_layout_buf[ptr_offset + 6] = @truncate(str_vaddr >> 48);
                    argv_layout_buf[ptr_offset + 7] = @truncate(str_vaddr >> 56);

                    while (str_offset < wire_total and argv_layout_buf[strings_start + str_offset] != 0) {
                        str_offset += 1;
                    }
                    str_offset += 1;
                    arg_i += 1;
                }

                _ = writeToChildMem(new_pml4, mem.ARGV_BASE, argv_layout_buf[0..total_size]);
            }
        }
    } else {
        // No argv: write argc=0 at ARGV_BASE
        @memset(argv_layout_buf[0..8], 0);
        _ = writeToChildMem(new_pml4, mem.ARGV_BASE, argv_layout_buf[0..8]);
    }

    // Write auxv for POSIX/musl programs
    {
        const AUXV_BASE: u64 = mem.ARGV_BASE - mem.PAGE_SIZE;
        const auxv_page = pmm.allocPage() orelse {
            proc.state = .dead;
            process.scheduleNext();
        };
        const auxv_phys_ptr: [*]u8 = paging.physPtr(auxv_page);
        @memset(auxv_phys_ptr[0..mem.PAGE_SIZE], 0);
        paging.mapPage(new_pml4, AUXV_BASE, auxv_page, paging.Flags.WRITABLE | paging.Flags.USER) orelse {
            proc.state = .dead;
            process.scheduleNext();
        };

        var auxv_buf: [96]u8 = @splat(0);
        var off: usize = 0;
        writeU64LE(auxv_buf[off..][0..8], 3); off += 8; // AT_PHDR
        writeU64LE(auxv_buf[off..][0..8], load_result.phdr_vaddr); off += 8;
        writeU64LE(auxv_buf[off..][0..8], 5); off += 8; // AT_PHNUM
        writeU64LE(auxv_buf[off..][0..8], load_result.phnum); off += 8;
        writeU64LE(auxv_buf[off..][0..8], 4); off += 8; // AT_PHENT
        writeU64LE(auxv_buf[off..][0..8], load_result.phentsize); off += 8;
        writeU64LE(auxv_buf[off..][0..8], 9); off += 8; // AT_ENTRY
        writeU64LE(auxv_buf[off..][0..8], load_result.entry_point); off += 8;
        writeU64LE(auxv_buf[off..][0..8], 6); off += 8; // AT_PAGESZ
        writeU64LE(auxv_buf[off..][0..8], mem.PAGE_SIZE); off += 8;
        writeU64LE(auxv_buf[off..][0..8], 0); off += 8; // AT_NULL
        writeU64LE(auxv_buf[off..][0..8], 0); off += 8;
        _ = writeToChildMem(new_pml4, AUXV_BASE, auxv_buf[0..off]);
    }

    // === Point of no return: swap to new address space ===
    // Old PML4 + user pages freed
    if (proc.pml4) |old_pml4| {
        paging.freeAddressSpace(old_pml4);
    }
    proc.pml4 = new_pml4;
    proc.user_rip = load_result.entry_point;
    proc.user_rsp = mem.ARGV_BASE - 8;
    proc.user_rflags = switch (@import("builtin").cpu.arch) {
        .riscv64 => @import("../arch/riscv64/cpu.zig").SSTATUS_SPIE | @import("../arch/riscv64/cpu.zig").SSTATUS_SUM,
        .aarch64 => 0x0, // SPSR for EL0t — all interrupts unmasked
        else => 0x202, // IF=1
    };
    proc.brk = load_result.brk;
    proc.pages_used = 0;
    proc.saved_kernel_rsp = 0; // Force IRETQ path in switchTo
    proc.syscall_ret = 0;
    proc.mmap_next = 0x0000_4000_0000_0000;

    // Clear IPC state (old user buffers are gone)
    proc.ipc_pending_msg = null;
    proc.ipc_recv_buf_ptr = 0;

    // FDs and namespace inherited (Plan 9)

    klog.debug("[exec: pid=");
    klog.debugDec(proc.pid);
    klog.debug(" new entry=");
    klog.debugHex(load_result.entry_point);
    klog.debug("]\n");

    process.scheduleNext(); // noreturn — process resumes with new image
}

/// Flag: bit 31 of fd_map_len means "spawn blocked" — process stays in .blocked
/// state and is not made runnable.  Caller must use proc_setup(READY) to start it.
pub const SPAWN_BLOCKED: u64 = 0x8000_0000;

pub fn sysSpawn(elf_ptr: u64, elf_len: u64, fd_map_ptr: u64, fd_map_len_raw: u64, argv_ptr: u64) u64 {
    const initrd = @import("../initrd.zig");
    const parent = process.getCurrent() orelse return ENOSYS;

    // Extract blocked flag and actual fd_map count
    const blocked = (fd_map_len_raw & SPAWN_BLOCKED) != 0;
    const fd_map_len = fd_map_len_raw & ~SPAWN_BLOCKED;

    // Validate ELF pointer
    if (elf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    if (elf_len == 0 or elf_len > 4 * 1024 * 1024) return EINVAL;

    // Validate fd map pointer
    if (fd_map_len > process.MAX_FDS) return EINVAL;
    if (fd_map_len > 0 and fd_map_ptr >= 0x0000_8000_0000_0000) return EFAULT;

    const elf_data: []const u8 = @as([*]const u8, @ptrFromInt(elf_ptr))[0..@intCast(elf_len)];

    // Process group quota check
    if (parent.group_id != 0xFF) {
        const pg = @import("../process_group.zig");
        if (pg.getById(parent.group_id)) |g| {
            if (!pg.canSpawnProcess(g)) return ENOMEM;
        }
    }

    // Create child process
    const child = process.create() orelse {
        klog.warn("[spawn: process.create() failed]\n");
        return ENOMEM;
    };

    // Load ELF into child's address space
    const load_result = elf.load(child.pml4.?, elf_data) catch |e| {
        klog.warn("[spawn: elf.load failed: ");
        klog.warn(@errorName(e));
        klog.warn(" elf_len=");
        klog.warnDec(@intCast(elf_len));
        klog.warn("]\n");
        child.state = .dead;
        return ENOMEM;
    };
    child.user_rip = load_result.entry_point;
    child.brk = load_result.brk;

    // Handle PT_INTERP: load interpreter from initrd and redirect entry
    if (load_result.interp_path) |interp_raw| {
        // Strip leading path components (e.g., "/lib/posix-realm" → "posix-realm")
        var interp_name = interp_raw;
        if (interp_name.len > 0) {
            var last_slash: usize = 0;
            var found_slash = false;
            for (interp_name, 0..) |c, idx| {
                if (c == '/') {
                    last_slash = idx;
                    found_slash = true;
                }
            }
            if (found_slash) {
                interp_name = interp_name[last_slash + 1 ..];
            }
        }

        const interp_data = initrd.findFile(interp_name) orelse {
            klog.warn("[spawn: interpreter not found: ");
            for (interp_name) |c| {
                const buf: [1]u8 = .{c};
                klog.warn(&buf);
            }
            klog.warn("]\n");
            child.state = .dead;
            return ENOENT;
        };

        // Load interpreter into child's address space (at its own image_base, e.g., 0x20000000)
        const interp_result = elf.load(child.pml4.?, interp_data) catch {
            child.state = .dead;
            return ENOMEM;
        };

        // Interpreter runs first; pass program entry via initial RAX (syscall_ret)
        child.user_rip = interp_result.entry_point;
        child.syscall_ret = load_result.entry_point;

        // Use program's brk (higher address), not interpreter's
        if (load_result.brk > interp_result.brk) {
            child.brk = load_result.brk;
        }
    }

    // Allocate user stack
    for (0..process.USER_STACK_PAGES) |i| {
        const page = pmm.allocPage() orelse {
            child.state = .dead;
            return ENOMEM;
        };
        const ptr: [*]u8 = paging.physPtr(page);
        @memset(ptr[0..mem.PAGE_SIZE], 0);
        const vaddr = mem.USER_STACK_TOP - (process.USER_STACK_PAGES - i) * mem.PAGE_SIZE;
        paging.mapPage(child.pml4.?, vaddr, page, paging.Flags.WRITABLE | paging.Flags.USER) orelse {
            child.state = .dead;
            return ENOMEM;
        };
    }
    // Set up argv layout at ARGV_BASE in child's address space.
    // Layout: [argc: u64][argv[0]: ptr][argv[1]: ptr]...[str0\0str1\0...]
    // Stack pointer is set to ARGV_BASE - 8 (aligned for x86_64 ABI).
    const child_pml4 = child.pml4.?;
    if (blocked) {
        // Blocked mode: skip argv setup, caller will use proc_setup(SETARGV).
        // Set a default RSP pointing to top of user stack.
        child.user_rsp = mem.USER_STACK_INIT;
    } else if (argv_ptr != 0 and argv_ptr < 0x0000_8000_0000_0000) {
        // Read wire format from parent's memory: [argc: u32][total: u32][str0\0str1\0...]
        const wire: [*]const u8 = @ptrFromInt(argv_ptr);
        const wire_argc = @as(u32, wire[0]) |
            (@as(u32, wire[1]) << 8) |
            (@as(u32, wire[2]) << 16) |
            (@as(u32, wire[3]) << 24);
        const wire_total = @as(u32, wire[4]) |
            (@as(u32, wire[5]) << 8) |
            (@as(u32, wire[6]) << 16) |
            (@as(u32, wire[7]) << 24);

        if (wire_argc > 0 and wire_argc <= 64 and wire_total > 0 and wire_total <= 3000) {
            // Build structured layout in static buffer:
            //   [argc: u64]                        8 bytes
            //   [argv[0]: u64] ... [argv[N-1]: u64]  argc * 8 bytes
            //   [str0\0str1\0...]                  wire_total bytes
            const header_size: usize = 8 + @as(usize, wire_argc) * 8;
            const total_size = header_size + wire_total;

            if (total_size <= argv_layout_buf.len) {
                // Zero the buffer
                @memset(argv_layout_buf[0..total_size], 0);

                // Write argc as u64
                const argc64: u64 = wire_argc;
                argv_layout_buf[0] = @truncate(argc64);
                argv_layout_buf[1] = @truncate(argc64 >> 8);
                argv_layout_buf[2] = @truncate(argc64 >> 16);
                argv_layout_buf[3] = @truncate(argc64 >> 24);
                argv_layout_buf[4] = @truncate(argc64 >> 32);
                argv_layout_buf[5] = @truncate(argc64 >> 40);
                argv_layout_buf[6] = @truncate(argc64 >> 48);
                argv_layout_buf[7] = @truncate(argc64 >> 56);

                // Copy string data from wire format
                const strings_start: usize = header_size;
                @memcpy(argv_layout_buf[strings_start..][0..wire_total], wire[8..][0..wire_total]);

                // Build pointer array: each argv[i] points to ARGV_BASE + strings_start + offset_of_string_i
                var str_offset: usize = 0;
                var arg_i: usize = 0;
                while (arg_i < wire_argc and str_offset < wire_total) {
                    const str_vaddr: u64 = mem.ARGV_BASE + strings_start + str_offset;
                    const ptr_offset = 8 + arg_i * 8;
                    argv_layout_buf[ptr_offset] = @truncate(str_vaddr);
                    argv_layout_buf[ptr_offset + 1] = @truncate(str_vaddr >> 8);
                    argv_layout_buf[ptr_offset + 2] = @truncate(str_vaddr >> 16);
                    argv_layout_buf[ptr_offset + 3] = @truncate(str_vaddr >> 24);
                    argv_layout_buf[ptr_offset + 4] = @truncate(str_vaddr >> 32);
                    argv_layout_buf[ptr_offset + 5] = @truncate(str_vaddr >> 40);
                    argv_layout_buf[ptr_offset + 6] = @truncate(str_vaddr >> 48);
                    argv_layout_buf[ptr_offset + 7] = @truncate(str_vaddr >> 56);

                    // Skip to next null terminator
                    while (str_offset < wire_total and argv_layout_buf[strings_start + str_offset] != 0) {
                        str_offset += 1;
                    }
                    str_offset += 1; // skip the null
                    arg_i += 1;
                }

                // Write layout to child's ARGV_BASE page
                _ = writeToChildMem(child_pml4, mem.ARGV_BASE, argv_layout_buf[0..total_size]);
            }
        }

        // Set RSP below the argv page (aligned for x86_64 ABI)
        child.user_rsp = mem.ARGV_BASE - 8;
    } else {
        // No argv: write argc=0 at ARGV_BASE, set RSP below
        @memset(argv_layout_buf[0..8], 0);
        _ = writeToChildMem(child_pml4, mem.ARGV_BASE, argv_layout_buf[0..8]);
        child.user_rsp = mem.ARGV_BASE - 8;
    }

    // Write auxiliary vector (auxv) for all programs. POSIX/musl programs need
    // AT_PHDR for TLS init. Cost: 1 page per process (negligible).
    // AUXV_BASE = ARGV_BASE - PAGE_SIZE
    {
        const AUXV_BASE: u64 = mem.ARGV_BASE - mem.PAGE_SIZE;
        // Allocate a page for auxv
        const auxv_page = pmm.allocPage() orelse {
            child.state = .dead;
            return ENOMEM;
        };
        const auxv_ptr2: [*]u8 = paging.physPtr(auxv_page);
        @memset(auxv_ptr2[0..mem.PAGE_SIZE], 0);
        paging.mapPage(child_pml4, AUXV_BASE, auxv_page, paging.Flags.WRITABLE | paging.Flags.USER) orelse {
            child.state = .dead;
            return ENOMEM;
        };

        // Write auxv entries as [key: u64, value: u64] pairs
        var auxv_buf: [96]u8 = @splat(0); // 6 entries * 16 bytes = 96
        var off: usize = 0;

        // AT_PHDR (3) = phdr_vaddr
        writeU64LE(auxv_buf[off..][0..8], 3); off += 8;
        writeU64LE(auxv_buf[off..][0..8], load_result.phdr_vaddr); off += 8;

        // AT_PHNUM (5) = phnum
        writeU64LE(auxv_buf[off..][0..8], 5); off += 8;
        writeU64LE(auxv_buf[off..][0..8], load_result.phnum); off += 8;

        // AT_PHENT (4) = phentsize
        writeU64LE(auxv_buf[off..][0..8], 4); off += 8;
        writeU64LE(auxv_buf[off..][0..8], load_result.phentsize); off += 8;

        // AT_ENTRY (9) = program entry point
        writeU64LE(auxv_buf[off..][0..8], 9); off += 8;
        writeU64LE(auxv_buf[off..][0..8], load_result.entry_point); off += 8;

        // AT_PAGESZ (6) = 4096
        writeU64LE(auxv_buf[off..][0..8], 6); off += 8;
        writeU64LE(auxv_buf[off..][0..8], mem.PAGE_SIZE); off += 8;

        // AT_NULL (0) = terminator
        writeU64LE(auxv_buf[off..][0..8], 0); off += 8;
        writeU64LE(auxv_buf[off..][0..8], 0); off += 8;

        _ = writeToChildMem(child_pml4, AUXV_BASE, auxv_buf[0..off]);
    }

    // In blocked mode, skip namespace/group inheritance — caller configures via proc_setup.
    if (!blocked) {
        // Copy namespace from parent (Plan 9: children inherit namespace)
        parent.getNs().cloneInto(&child.ns);
        child.uid = parent.uid;
        child.gid = parent.gid;

        // Inherit process group association
        child.group_id = parent.group_id;
        child.compat = parent.compat;
        if (child.group_id != 0xFF) {
            const pg = @import("../process_group.zig");
            if (pg.getById(child.group_id)) |g| {
                pg.addProcess(g);
            }
        }
    }

    // Copy fd mappings from parent to child
    if (fd_map_len > 0) {
        const pipe_mod = @import("../pipe.zig");
        const parent_fds = process.thread_group.getFdSlice(parent);
        const fd_maps: [*]const FdMapping = @ptrFromInt(fd_map_ptr);
        const ether_mod2 = @import("../ether.zig");
        for (0..@intCast(fd_map_len)) |i| {
            const m = fd_maps[i];
            if (m.parent_fd < process.MAX_FDS and m.child_fd < process.MAX_FDS) {
                if (parent_fds[m.parent_fd]) |fentry| {
                    child.fds[m.child_fd] = fentry;
                    // Increment pipe refcount for duplicated pipe fds
                    if (fentry.fd_type == .pipe) {
                        if (fentry.pipe_is_read) {
                            pipe_mod.incrementReaders(fentry.pipe_id);
                        } else {
                            pipe_mod.incrementWriters(fentry.pipe_id);
                        }
                    }
                    if (fentry.fd_type == .dev_ether) {
                        ether_mod2.incRefClient(fentry.ether_client);
                    }
                }
            }
        }
    }

    // Set process name from argv[0] basename (skip in blocked mode)
    if (!blocked and argv_ptr != 0 and argv_ptr < 0x0000_8000_0000_0000) {
        const wire: [*]const u8 = @ptrFromInt(argv_ptr);
        const wire_argc = @as(u32, wire[0]) |
            (@as(u32, wire[1]) << 8) |
            (@as(u32, wire[2]) << 16) |
            (@as(u32, wire[3]) << 24);
        const wire_total = @as(u32, wire[4]) |
            (@as(u32, wire[5]) << 8) |
            (@as(u32, wire[6]) << 16) |
            (@as(u32, wire[7]) << 24);
        if (wire_argc > 0 and wire_total > 0 and wire_total <= 3000) {
            // argv[0] starts at wire[8]
            const str = wire[8..][0..wire_total];
            // Find end of first string (null-terminated)
            var str_end: usize = 0;
            while (str_end < str.len and str[str_end] != 0) : (str_end += 1) {}
            // Find basename (last '/')
            var base_start: usize = 0;
            for (0..str_end) |si| {
                if (str[si] == '/') base_start = si + 1;
            }
            const basename = str[base_start..str_end];
            const copy_len = @min(basename.len, 15);
            @memset(&child.name, 0);
            @memcpy(child.name[0..copy_len], basename[0..copy_len]);
        }
    }

    klog.debug("[spawn: parent=");
    klog.debugDec(parent.pid);
    klog.debug(" child=");
    klog.debugDec(child.pid);
    klog.debug(" entry=");
    klog.debugHex(child.user_rip);
    if (load_result.interp_path != null) {
        klog.debug(" interp=");
        klog.debugHex(load_result.entry_point);
    }
    klog.debug("]\n");

    // In blocked mode, leave process in .blocked state for proc_setup configuration.
    // Caller must call proc_setup(READY, pid) to make it runnable.
    if (!blocked) {
        process.markReady(child);
    }

    return child.pid;
}
