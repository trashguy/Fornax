/// Fornax Plan 9-inspired syscall interface.
///
/// Syscall numbers — NOT Linux-compatible. Fornax has its own ABI.
/// Convention: RAX=nr, RDI=a0, RSI=a1, RDX=a2, R10=a3, R8=a4
const std = @import("std");
const console = @import("console.zig");
const process = @import("process.zig");
const ipc = @import("ipc.zig");
const namespace = @import("namespace.zig");
const elf = @import("elf.zig");
const paging = switch (@import("builtin").cpu.arch) {
    .x86_64 => @import("arch/x86_64/paging.zig"),
    .riscv64 => @import("arch/riscv64/paging.zig"),
    else => struct {},
};
const pmm = @import("pmm.zig");
const mem = @import("mem.zig");
const klog = @import("klog.zig");

pub const SYS = enum(u64) {
    open = 0,
    create = 1,
    read = 2,
    write = 3,
    close = 4,
    stat = 5,
    seek = 6,
    remove = 7,
    mount = 8,
    bind = 9,
    unmount = 10,
    rfork = 11,
    exec = 12,
    wait = 13,
    exit = 14,
    pipe = 15,
    brk = 16,
    ipc_recv = 17,
    ipc_reply = 18,
    spawn = 19,
    pread = 20,
    pwrite = 21,
    klog = 22,
    sysinfo = 23,
    sleep = 24,
    shutdown = 25,
};

/// Error return values.
const ENOSYS: u64 = @bitCast(@as(i64, -1));
const EBADF: u64 = @bitCast(@as(i64, -9));
const EFAULT: u64 = @bitCast(@as(i64, -14));
const ENOENT: u64 = @bitCast(@as(i64, -2));
const EMFILE: u64 = @bitCast(@as(i64, -24));
const EIO: u64 = @bitCast(@as(i64, -5));
const ENOMEM: u64 = @bitCast(@as(i64, -12));
const EINVAL: u64 = @bitCast(@as(i64, -22));

// --- Helpers ---

fn writeU32LE(buf: *[4]u8, val: u32) void {
    buf[0] = @truncate(val);
    buf[1] = @truncate(val >> 8);
    buf[2] = @truncate(val >> 16);
    buf[3] = @truncate(val >> 24);
}

fn readU32LE(buf: *const [4]u8) u32 {
    return @as(u32, buf[0]) |
        (@as(u32, buf[1]) << 8) |
        (@as(u32, buf[2]) << 16) |
        (@as(u32, buf[3]) << 24);
}

/// Send a client message on a channel and wake the server if it's blocked in recv.
fn sendToServer(chan: *ipc.Channel, proc: *process.Process) void {
    chan.client.pending_msg = &proc.ipc_msg;
    chan.client.send_waiting = true;
    chan.client.blocked_pid = proc.pid;

    if (chan.server.recv_waiting and chan.server.blocked_pid != 0) {
        if (process.getByPid(chan.server.blocked_pid)) |server_proc| {
            server_proc.ipc_pending_msg = &proc.ipc_msg;
            server_proc.state = .ready;
            server_proc.syscall_ret = 0;
            chan.server.recv_waiting = false;
            chan.server.blocked_pid = 0;
            // Message delivered via ipc_pending_msg — clear pending_msg so
            // the server's next sysIpcRecv doesn't re-deliver it.
            chan.client.pending_msg = null;
        }
    }
}

/// Main syscall dispatch. Called from arch-specific entry point.
pub fn dispatch(nr: u64, arg0: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64) u64 {
    // Save user context to the current process at the start of every syscall.
    // This snapshots RIP/RSP/RFLAGS so blocking syscalls can schedule away.
    process.saveCurrentContext();

    const sys = std.meta.intToEnum(SYS, nr) catch {
        klog.warn("syscall: unknown nr=");
        klog.warnDec(nr);
        klog.warn("\n");
        return ENOSYS;
    };

    return switch (sys) {
        .write => sysWrite(arg0, arg1, arg2),
        .exit => sysExit(arg0),
        .open => sysOpen(arg0, arg1),
        .read => sysRead(arg0, arg1, arg2),
        .close => sysClose(arg0),
        .ipc_recv => sysIpcRecv(arg0, arg1),
        .ipc_reply => sysIpcReply(arg0, arg1),
        .create => sysCreate(arg0, arg1, arg2),
        .stat => sysStat(arg0, arg1),
        .remove => sysRemove(arg0, arg1),
        .seek => {
            klog.warn("syscall: unimplemented nr=");
            klog.warnDec(nr);
            klog.warn("\n");
            return ENOSYS;
        },
        .exec => sysExec(arg0, arg1),
        .wait => sysWait(arg0),
        .spawn => sysSpawn(arg0, arg1, arg2, arg3, arg4),
        .brk => sysBrk(arg0),
        .pipe => sysPipe(arg0),
        .pread => sysPread(arg0, arg1, arg2, arg3),
        .pwrite => sysPwrite(arg0, arg1, arg2, arg3),
        .klog => sysKlog(arg0, arg1, arg2),
        .sysinfo => sysSysinfo(arg0),
        .sleep => sysSleep(arg0),
        .shutdown => sysShutdown(arg0),
        .mount, .bind, .unmount, .rfork => {
            klog.warn("syscall: unimplemented nr=");
            klog.warnDec(nr);
            klog.warn("\n");
            return ENOSYS;
        },
    };
}

/// write(fd, buf, count) → bytes_written
/// fd 1/2 → direct framebuffer console + serial (bootstrap path).
/// Other fds → IPC to file server via channel.
fn sysWrite(fd: u64, buf_ptr: u64, count: u64) u64 {
    const pipe_mod = @import("pipe.zig");

    // For fd 0/1/2, check if process has an explicit FdEntry override.
    // If not, use the default console/keyboard path.
    if (fd <= 2) {
        const proc = process.getCurrent() orelse return EBADF;
        if (fd == 0 and proc.fds[0] == null) {
            // Default: keyboard control (Plan 9 style: write to fd 0)
            const keyboard = @import("keyboard.zig");
            if (buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
            if (count == 0) return 0;
            const buf: [*]const u8 = @ptrFromInt(buf_ptr);
            const len: usize = @intCast(@min(count, 64));
            keyboard.handleCtl(buf[0..len]);
            return len;
        }
        if ((fd == 1 or fd == 2) and proc.fds[fd] == null) {
            // Default: direct framebuffer console + serial
            if (buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
            if (count == 0) return 0;
            const buf: [*]const u8 = @ptrFromInt(buf_ptr);
            const len: usize = @intCast(@min(count, 4096));
            console.puts(buf[0..len]);
            return len;
        }
        // Fall through to normal fd table path below
    }

    const proc = process.getCurrent() orelse return EBADF;
    const entry = proc.getFdEntry(@intCast(fd)) orelse return EBADF;

    if (buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    if (count == 0) return 0;

    // Pipe fd: write to pipe buffer
    if (entry.fd_type == .pipe) {
        const buf: [*]const u8 = @ptrFromInt(buf_ptr);
        const n = @min(count, 4096);
        if (pipe_mod.pipeWrite(entry.pipe_id, buf[0..n])) |bytes| {
            return bytes;
        }
        // Block — pipe full
        pipe_mod.setWriteWaiter(entry.pipe_id, @intCast(proc.pid));
        proc.pending_op = .pipe_write;
        proc.pending_fd = @intCast(fd);
        proc.ipc_recv_buf_ptr = buf_ptr;
        proc.syscall_ret = n;
        proc.state = .blocked;
        process.scheduleNext();
    }

    // Net fd: dispatch to netfs
    if (entry.fd_type == .net) {
        const net = @import("net.zig");
        const netfs = net.netfs;
        const tcp = net.tcp;
        const dns = net.dns;

        const buf: [*]const u8 = @ptrFromInt(buf_ptr);
        const data_len: u16 = @intCast(@min(count, 4096));

        const result = netfs.netWrite(entry.net_kind, entry.net_conn, buf[0..data_len]);
        if (result) |n| {
            return n;
        }

        // null means block — depends on the kind
        if (entry.net_kind == .tcp_ctl) {
            // Block until connect completes
            tcp.setConnectWaiter(entry.net_conn, @intCast(proc.pid));
            proc.pending_op = .net_connect;
            proc.pending_fd = @intCast(fd);
            proc.syscall_ret = data_len;
            proc.state = .blocked;
            process.scheduleNext();
        } else if (entry.net_kind == .dns_query) {
            // Block until DNS response arrives
            dns.setWaiter(@intCast(proc.pid));
            proc.pending_op = .dns_query;
            proc.pending_fd = @intCast(fd);
            proc.syscall_ret = data_len;
            proc.state = .blocked;
            process.scheduleNext();
        }

        return 0;
    }

    const chan = ipc.getChannel(entry.channel_id) orelse return EBADF;
    const buf: [*]const u8 = @ptrFromInt(buf_ptr);

    // Server-backed fd: T_WRITE with [handle: u32][data...]
    if (entry.server_handle > 0) {
        const max_data = ipc.MAX_MSG_DATA - 4;
        const data_len: u32 = @intCast(@min(count, max_data));

        proc.ipc_msg = ipc.Message.init(.t_write);
        writeU32LE(proc.ipc_msg.data_buf[0..4], entry.server_handle);
        @memcpy(proc.ipc_msg.data_buf[4..][0..data_len], buf[0..data_len]);
        proc.ipc_msg.data_len = 4 + data_len;

        proc.pending_op = .write;
        proc.pending_fd = @intCast(fd);

        sendToServer(chan, proc);
        proc.state = .blocked;
        process.scheduleNext();
    }

    // Raw IPC write (existing behavior for non-server-backed channels)
    const len: u32 = @intCast(@min(count, ipc.MAX_MSG_DATA));

    proc.ipc_msg = ipc.Message.init(.t_write);
    @memcpy(proc.ipc_msg.data_buf[0..len], buf[0..len]);
    proc.ipc_msg.data_len = len;

    proc.pending_op = .none;
    sendToServer(chan, proc);
    proc.state = .blocked;
    process.scheduleNext();
}

/// exit(status) — terminate the current process and schedule next.
fn sysExit(status: u64) noreturn {
    const proc = process.getCurrent() orelse process.scheduleNext();

    klog.debug("[Process ");
    klog.debugDec(proc.pid);
    klog.debug(" exited with status ");
    klog.debugDec(status);
    klog.debug("]\n");

    proc.exit_status = @truncate(status);

    // Kill all children recursively (Fornax orphan policy)
    process.killChildren(proc.pid);

    // Close all pipe fds (decrement refcounts, wake blocked peers)
    {
        const pipe_mod = @import("pipe.zig");
        for (0..process.MAX_FDS) |i| {
            if (proc.fds[i]) |entry| {
                if (entry.fd_type == .pipe) {
                    if (entry.pipe_is_read) {
                        pipe_mod.closeReadEnd(entry.pipe_id);
                    } else {
                        pipe_mod.closeWriteEnd(entry.pipe_id);
                    }
                    proc.closeFd(@intCast(i));
                }
            }
        }
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
                        // Wake parent with our exit status
                        parent.syscall_ret = status;
                        parent.state = .ready;
                        parent.waiting_for_pid = null;
                        // Reaped immediately — go to free
                        proc.state = .free;
                        proc.parent_pid = null;
                        process.scheduleNext();
                    }
                }
            }
            // Parent exists but not waiting — become zombie
            proc.state = .zombie;
            process.scheduleNext();
        }
    }

    // No parent (kernel-spawned or orphaned) — free immediately
    proc.state = .free;
    proc.parent_pid = null;
    process.scheduleNext();
}

/// brk(new_brk) — adjust program break (heap top).
/// If new_brk == 0, return current brk. Otherwise, expand heap by allocating
/// and mapping pages for the new region, checking quotas.
fn sysBrk(new_brk: u64) u64 {
    const proc = process.getCurrent() orelse return 0;

    // Query current brk
    if (new_brk == 0) return proc.brk;

    // Only allow growing, not shrinking
    if (new_brk <= proc.brk) return proc.brk;

    // Validate: brk must stay in user space
    if (new_brk >= 0x0000_8000_0000_0000) return proc.brk;

    const page_size = mem.PAGE_SIZE;
    const old_brk_page = (proc.brk + page_size - 1) / page_size;
    const new_brk_page = (new_brk + page_size - 1) / page_size;

    const proc_pml4 = proc.pml4 orelse return proc.brk;

    // Allocate and map new pages
    var page_idx = old_brk_page;
    while (page_idx < new_brk_page) : (page_idx += 1) {
        if (proc.pages_used >= proc.quotas.max_memory_pages) {
            klog.debug("[brk: quota exceeded]\n");
            return proc.brk; // return old brk on failure
        }
        const page = pmm.allocPage() orelse {
            klog.debug("[brk: out of memory]\n");
            return proc.brk;
        };
        const ptr: [*]u8 = paging.physPtr(page);
        @memset(ptr[0..page_size], 0);
        const vaddr = page_idx * page_size;
        paging.mapPage(proc_pml4, vaddr, page, paging.Flags.WRITABLE | paging.Flags.USER) orelse {
            pmm.freePage(page);
            return proc.brk;
        };
        proc.pages_used += 1;
    }

    proc.brk = new_brk;
    return new_brk;
}

fn sysWait(pid_arg: u64) u64 {
    const proc = process.getCurrent() orelse return ENOSYS;
    const wait_pid: u32 = @truncate(pid_arg);

    // Check for an already-exited (zombie) child first
    var found_child = false;
    const processes_slice = process.getProcessTable();
    for (processes_slice) |*p| {
        if (p.parent_pid) |ppid| {
            if (ppid == proc.pid) {
                found_child = true;
                if (p.state == .zombie) {
                    if (wait_pid == 0 or p.pid == wait_pid) {
                        // Reap this zombie — free deferred kernel stack
                        const status: u64 = p.exit_status;
                        if (p.needs_stack_free) {
                            process.freeKernelStack(p);
                            p.needs_stack_free = false;
                        }
                        p.state = .free;
                        p.parent_pid = null;
                        return status;
                    }
                }
            }
        }
    }

    // If waiting for a specific child, verify it exists and belongs to us
    if (wait_pid != 0) {
        if (process.getByPid(wait_pid)) |child| {
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

    // No zombie found — block until a child exits
    proc.state = .blocked;
    proc.waiting_for_pid = wait_pid;
    klog.debug("[pid=");
    klog.debugDec(proc.pid);
    klog.debug(" blocked in wait");
    if (wait_pid != 0) {
        klog.debug(" for pid=");
        klog.debugDec(wait_pid);
    }
    klog.debug("]\n");
    process.scheduleNext();
}

/// open(path_ptr, path_len) → fd
/// Resolves path in the process's namespace. For kernel-backed channels (initrd),
/// allocates fd directly. For server channels, sends T_OPEN and blocks for reply.
/// Paths starting with /net/ are intercepted for kernel TCP/DNS.
fn sysOpen(path_ptr: u64, path_len: u64) u64 {
    const proc = process.getCurrent() orelse return ENOSYS;
    if (path_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    if (path_len == 0 or path_len > 256) return ENOENT;

    const path: [*]const u8 = @ptrFromInt(path_ptr);
    const path_slice = path[0..@intCast(path_len)];

    // Intercept /dev/blk0 for block device
    if (path_len == 9 and path_slice[0] == '/' and path_slice[1] == 'd' and
        path_slice[2] == 'e' and path_slice[3] == 'v' and path_slice[4] == '/' and
        path_slice[5] == 'b' and path_slice[6] == 'l' and path_slice[7] == 'k' and
        path_slice[8] == '0')
    {
        const virtio_blk = @import("virtio_blk.zig");
        if (!virtio_blk.isInitialized()) return ENOENT;
        return proc.allocBlkFd() orelse return EMFILE;
    }

    // Intercept /net/* paths for kernel TCP/DNS
    if (path_len > 5 and path_slice[0] == '/' and path_slice[1] == 'n' and
        path_slice[2] == 'e' and path_slice[3] == 't' and path_slice[4] == '/')
    {
        const net = @import("net.zig");
        const netfs = net.netfs;

        const result = netfs.netOpen(path_slice[5..]) orelse return ENOENT;
        const fd = proc.allocNetFd(result.kind, result.conn) orelse return EMFILE;

        // For tcp/N/listen, block until a connection arrives
        if (result.kind == .tcp_listen) {
            const tcp = net.tcp;
            tcp.setListenWaiter(result.conn, @intCast(proc.pid));
            proc.pending_op = .net_listen;
            proc.pending_fd = fd;
            proc.syscall_ret = fd;
            proc.state = .blocked;
            process.scheduleNext();
        }

        return fd;
    }

    const resolved = proc.ns.resolve(path_slice) orelse return ENOENT;

    const chan = ipc.getChannel(resolved.channel_id) orelse return ENOENT;

    // Kernel-backed channel (initrd): just allocate fd, no IPC needed
    if (chan.kernel_data != null) {
        return proc.allocFd(resolved.channel_id, false) orelse return EMFILE;
    }

    // Server channel: send T_OPEN with path suffix
    const fd = proc.allocFd(resolved.channel_id, false) orelse return EMFILE;

    proc.pending_op = .open;
    proc.pending_fd = fd;

    // Build T_OPEN: data = [suffix bytes]
    proc.ipc_msg = ipc.Message.init(.t_open);
    const suffix = resolved.suffix;
    const suffix_len: u32 = @intCast(suffix.len);
    if (suffix_len > 0) {
        @memcpy(proc.ipc_msg.data_buf[0..suffix_len], suffix);
    }
    proc.ipc_msg.data_len = suffix_len;

    // Pre-set return value (overridden on error in reply handler)
    proc.syscall_ret = fd;

    sendToServer(chan, proc);
    proc.state = .blocked;
    process.scheduleNext();
}

/// create(path_ptr, path_len, flags) → fd
/// Like open but creates the file if it doesn't exist.
/// flags bit 0 = directory.
fn sysCreate(path_ptr: u64, path_len: u64, flags: u64) u64 {
    const proc = process.getCurrent() orelse return ENOSYS;
    if (path_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    if (path_len == 0 or path_len > 256) return ENOENT;

    const path: [*]const u8 = @ptrFromInt(path_ptr);
    const resolved = proc.ns.resolve(path[0..@intCast(path_len)]) orelse return ENOENT;

    const chan = ipc.getChannel(resolved.channel_id) orelse return ENOENT;

    // Can't create on kernel-backed channels
    if (chan.kernel_data != null) return ENOSYS;

    const fd = proc.allocFd(resolved.channel_id, false) orelse return EMFILE;

    proc.pending_op = .create;
    proc.pending_fd = fd;

    // Build T_CREATE: [flags: u32][suffix bytes]
    proc.ipc_msg = ipc.Message.init(.t_create);
    writeU32LE(proc.ipc_msg.data_buf[0..4], @truncate(flags));
    const suffix = resolved.suffix;
    const suffix_len: u32 = @intCast(suffix.len);
    if (suffix_len > 0) {
        @memcpy(proc.ipc_msg.data_buf[4..][0..suffix_len], suffix);
    }
    proc.ipc_msg.data_len = 4 + suffix_len;

    proc.syscall_ret = fd;

    sendToServer(chan, proc);
    proc.state = .blocked;
    process.scheduleNext();
}

/// read(fd, buf, count) → bytes_read
/// For IPC channels: sends T_READ to the server and blocks for reply.
fn sysRead(fd: u64, buf_ptr: u64, count: u64) u64 {
    const pipe_mod = @import("pipe.zig");

    // For fd 0, check if process has an explicit FdEntry override.
    // If not, use the default keyboard/console read path.
    if (fd == 0) {
        const proc0 = process.getCurrent() orelse return EBADF;
        if (proc0.fds[0] == null) {
            // Default: console read (stdin from keyboard)
            const keyboard = @import("keyboard.zig");
            if (buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
            if (count == 0) return 0;

            // Check if data is already available
            if (keyboard.dataAvailable()) {
                const dest: [*]u8 = @ptrFromInt(buf_ptr);
                const n = keyboard.read(dest, @intCast(@min(count, 4096)));
                return n;
            }

            // No data — block and wait for keyboard input
            proc0.pending_op = .console_read;
            proc0.ipc_recv_buf_ptr = buf_ptr;
            proc0.pending_fd = @intCast(@min(count, 4096)); // stash requested size
            keyboard.registerWaiter(@intCast(proc0.pid), buf_ptr, @intCast(@min(count, 4096)));
            proc0.state = .blocked;
            process.scheduleNext();
        }
        // Fall through to normal fd table path below
    }

    const proc = process.getCurrent() orelse return EBADF;
    const entry_ptr = proc.getFdEntryPtr(@intCast(fd)) orelse return EBADF;

    if (buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    if (count == 0) return 0;

    // Pipe fd: read from pipe buffer
    if (entry_ptr.fd_type == .pipe) {
        const dest: [*]u8 = @ptrFromInt(buf_ptr);
        const n = @min(count, 4096);
        if (pipe_mod.pipeRead(entry_ptr.pipe_id, dest[0..n])) |bytes| {
            return bytes;
        }
        // Block — no data available yet
        pipe_mod.setReadWaiter(entry_ptr.pipe_id, @intCast(proc.pid));
        proc.pending_op = .pipe_read;
        proc.pending_fd = @intCast(fd);
        proc.ipc_recv_buf_ptr = buf_ptr;
        proc.syscall_ret = n;
        proc.state = .blocked;
        process.scheduleNext();
    }

    // Net fd: dispatch to netfs
    if (entry_ptr.fd_type == .net) {
        const net = @import("net.zig");
        const netfs = net.netfs;
        const tcp = net.tcp;

        const dest: [*]u8 = @ptrFromInt(buf_ptr);
        const buf_size: u16 = @intCast(@min(count, 4096));

        const result = netfs.netRead(entry_ptr.net_kind, entry_ptr.net_conn, dest[0..buf_size], &entry_ptr.net_read_done);
        if (result) |n| {
            return n;
        }

        // null means block — register waiter and block
        if (entry_ptr.net_kind == .icmp_data) {
            const icmp_mod = net.icmp;
            icmp_mod.setReadWaiter(entry_ptr.net_conn, @intCast(proc.pid));
            proc.pending_op = .icmp_read;
        } else {
            tcp.setReadWaiter(entry_ptr.net_conn, @intCast(proc.pid));
            proc.pending_op = .net_read;
        }
        proc.pending_fd = @intCast(fd);
        proc.ipc_recv_buf_ptr = buf_ptr;
        proc.syscall_ret = count;
        proc.state = .blocked;
        process.scheduleNext();
    }

    const chan = ipc.getChannel(entry_ptr.channel_id) orelse return EBADF;

    // Kernel-backed channel (initrd file server): serve directly, no IPC
    if (chan.kernel_data) |data| {
        const offset: usize = entry_ptr.read_offset;
        if (offset >= data.len) return 0; // EOF

        const available = data.len - offset;
        const to_copy: usize = @min(@min(count, available), 4096);
        const dest: [*]u8 = @ptrFromInt(buf_ptr);
        @memcpy(dest[0..to_copy], data[offset..][0..to_copy]);
        entry_ptr.read_offset += @intCast(to_copy);
        return to_copy;
    }

    // Server-backed fd: T_READ with [handle: u32][offset: u32][count: u32]
    if (entry_ptr.server_handle > 0) {
        const read_count: u32 = @intCast(@min(count, ipc.MAX_MSG_DATA));

        proc.ipc_msg = ipc.Message.init(.t_read);
        writeU32LE(proc.ipc_msg.data_buf[0..4], entry_ptr.server_handle);
        writeU32LE(proc.ipc_msg.data_buf[4..8], entry_ptr.read_offset);
        writeU32LE(proc.ipc_msg.data_buf[8..12], read_count);
        proc.ipc_msg.data_len = 12;

        proc.pending_op = .read;
        proc.pending_fd = @intCast(fd);
        proc.ipc_recv_buf_ptr = buf_ptr;

        sendToServer(chan, proc);
        proc.state = .blocked;
        process.scheduleNext();
    }

    // Raw IPC read (existing behavior)
    const len: u32 = @intCast(@min(count, ipc.MAX_MSG_DATA));

    proc.ipc_msg = ipc.Message.init(.t_read);
    proc.ipc_msg.data_len = len; // requested read size

    proc.pending_op = .none;
    proc.ipc_recv_buf_ptr = buf_ptr;

    sendToServer(chan, proc);
    proc.state = .blocked;
    process.scheduleNext();
}

fn sysPread(fd: u64, buf_ptr: u64, count: u64, offset: u64) u64 {
    const virtio_blk = @import("virtio_blk.zig");

    const proc = process.getCurrent() orelse return EBADF;
    const entry_ptr = proc.getFdEntryPtr(@intCast(fd)) orelse return EBADF;

    if (buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    if (count == 0) return 0;

    if (entry_ptr.fd_type != .blk) return EBADF;

    // Bounds check: if blk_size set, cap read at partition boundary
    var actual_count = count;
    if (entry_ptr.blk_size > 0) {
        if (offset >= entry_ptr.blk_size) return 0; // EOF
        actual_count = @min(count, entry_ptr.blk_size - offset);
    }

    // Apply partition offset
    const real_offset = offset + entry_ptr.blk_offset;

    // Block device: offset and count must be 4096-aligned
    if (real_offset % 4096 != 0 or actual_count % 4096 != 0) return EINVAL;

    const block_start = real_offset / 4096;
    const block_count = actual_count / 4096;
    var bytes_read: u64 = 0;
    var i: u64 = 0;

    while (i < block_count) : (i += 1) {
        const dest: [*]u8 = @ptrFromInt(buf_ptr + i * 4096);
        const buf: *[4096]u8 = @ptrCast(dest);
        if (!virtio_blk.readBlock(block_start + i, buf)) {
            if (bytes_read > 0) return bytes_read;
            return EIO;
        }
        bytes_read += 4096;
    }

    return bytes_read;
}

fn sysPwrite(fd: u64, buf_ptr: u64, count: u64, offset: u64) u64 {
    const virtio_blk = @import("virtio_blk.zig");

    const proc = process.getCurrent() orelse return EBADF;
    const entry_ptr = proc.getFdEntryPtr(@intCast(fd)) orelse return EBADF;

    if (buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    if (count == 0) return 0;

    if (entry_ptr.fd_type != .blk) return EBADF;

    // Bounds check: if blk_size set, cap write at partition boundary
    var actual_count = count;
    if (entry_ptr.blk_size > 0) {
        if (offset >= entry_ptr.blk_size) return 0;
        actual_count = @min(count, entry_ptr.blk_size - offset);
    }

    // Apply partition offset
    const real_offset = offset + entry_ptr.blk_offset;

    // Block device: offset and count must be 4096-aligned
    if (real_offset % 4096 != 0 or actual_count % 4096 != 0) return EINVAL;

    const block_start = real_offset / 4096;
    const block_count = actual_count / 4096;
    var bytes_written: u64 = 0;
    var i: u64 = 0;

    while (i < block_count) : (i += 1) {
        const src: [*]const u8 = @ptrFromInt(buf_ptr + i * 4096);
        const buf: *const [4096]u8 = @ptrCast(src);
        if (!virtio_blk.writeBlock(block_start + i, buf)) {
            if (bytes_written > 0) return bytes_written;
            return EIO;
        }
        bytes_written += 4096;
    }

    return bytes_written;
}

fn sysKlog(buf_ptr: u64, buf_len: u64, offset: u64) u64 {
    if (buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    if (buf_len == 0) return 0;

    const dest: [*]u8 = @ptrFromInt(buf_ptr);
    const n = @min(buf_len, 4096);

    return klog.read(dest[0..n], offset);
}

/// sysinfo(info_ptr) → 0 or error
/// Writes SysInfo struct { total_pages: u64, free_pages: u64, page_size: u64 } to user buffer.
fn sysSysinfo(info_ptr: u64) u64 {
    if (info_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    if (info_ptr % 8 != 0) return EFAULT;

    const ptr: *[3]u64 = @ptrFromInt(info_ptr);
    ptr[0] = pmm.getTotalPages();
    ptr[1] = pmm.getFreePages();
    ptr[2] = 4096;
    return 0;
}

fn sysSleep(ms: u64) u64 {
    const timer = @import("timer.zig");
    const proc = process.getCurrent() orelse return EFAULT;

    // At least 1 tick, even for small ms values
    const ticks_to_sleep: u32 = @intCast(@max(1, ms * timer.TICKS_PER_SEC / 1000));
    proc.sleep_until = timer.getTicks() +% ticks_to_sleep;
    proc.pending_op = .sleep;
    proc.state = .blocked;
    process.scheduleNext();
}

fn sysShutdown(flags: u64) noreturn {
    const cpu = switch (@import("builtin").cpu.arch) {
        .x86_64 => @import("arch/x86_64/cpu.zig"),
        .riscv64 => @import("arch/riscv64/cpu.zig"),
        else => @compileError("unsupported arch for shutdown"),
    };
    if (flags == 1) {
        klog.warn("syscall: reboot requested\n");
        cpu.resetSystem();
    } else {
        klog.warn("syscall: shutdown requested\n");
        cpu.acpiShutdown();
    }
}

/// close(fd) → 0 or error
fn sysClose(fd: u64) u64 {
    const proc = process.getCurrent() orelse return EBADF;
    if (fd >= 32) return EBADF;

    const entry = proc.getFdEntry(@intCast(fd)) orelse return EBADF;

    // Pipe fd: close the appropriate end
    if (entry.fd_type == .pipe) {
        const pipe_mod = @import("pipe.zig");
        if (entry.pipe_is_read) {
            pipe_mod.closeReadEnd(entry.pipe_id);
        } else {
            pipe_mod.closeWriteEnd(entry.pipe_id);
        }
        proc.closeFd(@intCast(fd));
        return 0;
    }

    // Net fd: dispatch to netfs
    if (entry.fd_type == .net) {
        const net = @import("net.zig");
        net.netfs.netClose(entry.net_kind, entry.net_conn);
        proc.closeFd(@intCast(fd));
        return 0;
    }

    // Server-backed fd: send T_CLOSE to server before closing locally
    if (entry.server_handle > 0) {
        const chan = ipc.getChannel(entry.channel_id) orelse {
            proc.closeFd(@intCast(fd));
            return 0;
        };

        proc.ipc_msg = ipc.Message.init(.t_close);
        writeU32LE(proc.ipc_msg.data_buf[0..4], entry.server_handle);
        proc.ipc_msg.data_len = 4;

        proc.pending_op = .close;
        proc.pending_fd = @intCast(fd);

        sendToServer(chan, proc);
        proc.state = .blocked;
        process.scheduleNext();
    }

    // Non-server fd: just close locally
    proc.closeFd(@intCast(fd));
    return 0;
}

/// pipe(result_ptr) → 0 on success, negative on error.
/// Creates a pipe and writes [read_fd: u32, write_fd: u32] to result_ptr.
fn sysPipe(result_ptr: u64) u64 {
    if (result_ptr == 0 or result_ptr >= 0x0000_8000_0000_0000) return EFAULT;

    const proc = process.getCurrent() orelse return EBADF;
    const pipe_mod = @import("pipe.zig");

    const pipe_id = pipe_mod.alloc() orelse return ENOMEM;

    const read_fd = proc.allocPipeFd(pipe_id, true) orelse {
        pipe_mod.free(pipe_id);
        return EMFILE;
    };
    const write_fd = proc.allocPipeFd(pipe_id, false) orelse {
        proc.closeFd(read_fd);
        pipe_mod.free(pipe_id);
        return EMFILE;
    };

    // Write [read_fd, write_fd] as two u32 to user pointer
    const dest: [*]u8 = @ptrFromInt(result_ptr);
    dest[0] = @truncate(read_fd);
    dest[1] = @truncate(read_fd >> 8);
    dest[2] = @truncate(read_fd >> 16);
    dest[3] = @truncate(read_fd >> 24);
    dest[4] = @truncate(write_fd);
    dest[5] = @truncate(write_fd >> 8);
    dest[6] = @truncate(write_fd >> 16);
    dest[7] = @truncate(write_fd >> 24);

    return 0;
}

/// stat(fd, stat_buf_ptr) → 0 on success, negative on error.
/// Returns file metadata (size, type) into user-provided Stat buffer.
fn sysStat(fd: u64, stat_buf_ptr: u64) u64 {
    const proc = process.getCurrent() orelse return ENOSYS;
    if (stat_buf_ptr >= 0x0000_8000_0000_0000 or stat_buf_ptr == 0) return EFAULT;
    if (fd >= 32) return EBADF;

    const entry = proc.getFdEntry(@intCast(fd)) orelse return EBADF;

    // Net fds: synthetic stat (size=0, type=file)
    if (entry.fd_type == .net) {
        const stat_ptr: *align(1) [64]u8 = @ptrFromInt(stat_buf_ptr);
        @memset(stat_ptr, 0);
        return 0;
    }

    const chan = ipc.getChannel(entry.channel_id) orelse return EBADF;

    // Kernel-backed channel (initrd): stat from kernel data length
    if (chan.kernel_data) |data| {
        const stat_ptr: *align(1) [64]u8 = @ptrFromInt(stat_buf_ptr);
        @memset(stat_ptr, 0);
        // size at offset 0
        const size: u32 = @intCast(data.len);
        writeU32LE(@ptrCast(stat_ptr[0..4]), size);
        // file_type at offset 4: 0 = file
        return 0;
    }

    // Server-backed fd: send T_STAT with [handle: u32], block for reply
    if (entry.server_handle > 0) {
        proc.ipc_msg = ipc.Message.init(.t_stat);
        writeU32LE(proc.ipc_msg.data_buf[0..4], entry.server_handle);
        proc.ipc_msg.data_len = 4;

        proc.pending_op = .stat;
        proc.pending_fd = @intCast(fd);
        proc.ipc_recv_buf_ptr = stat_buf_ptr;

        sendToServer(chan, proc);
        proc.state = .blocked;
        process.scheduleNext();
    }

    return EBADF;
}

/// remove(path_ptr, path_len) → 0 or negative error.
/// Resolve path in namespace, send T_REMOVE to the server.
fn sysRemove(path_ptr: u64, path_len: u64) u64 {
    const proc = process.getCurrent() orelse return ENOSYS;
    if (path_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    if (path_len == 0 or path_len > 256) return ENOENT;

    const path: [*]const u8 = @ptrFromInt(path_ptr);
    const path_slice = path[0..@intCast(path_len)];

    const resolved = proc.ns.resolve(path_slice) orelse return ENOENT;

    const chan = ipc.getChannel(resolved.channel_id) orelse return ENOENT;

    // Cannot remove on kernel-backed channels
    if (chan.kernel_data != null) return ENOSYS;

    // Send T_REMOVE with path suffix
    proc.ipc_msg = ipc.Message.init(.t_remove);
    const suffix = resolved.suffix;
    const suffix_len: u32 = @intCast(suffix.len);
    if (suffix_len > 0) {
        @memcpy(proc.ipc_msg.data_buf[0..suffix_len], suffix);
    }
    proc.ipc_msg.data_len = suffix_len;

    proc.pending_op = .remove;
    proc.pending_fd = 0;
    proc.syscall_ret = 0;

    sendToServer(chan, proc);
    proc.state = .blocked;
    process.scheduleNext();
}

/// ipc_recv(fd, msg_buf_ptr) → 0 on success, negative on error.
/// Server-side: receive the next message on a channel.
/// Blocks if no message is pending.
fn sysIpcRecv(fd: u64, msg_buf_ptr: u64) u64 {
    const proc = process.getCurrent() orelse return ENOSYS;
    const entry = proc.getFdEntry(@intCast(fd)) orelse return EBADF;

    if (msg_buf_ptr >= 0x0000_8000_0000_0000 or msg_buf_ptr == 0) return EFAULT;

    const chan = ipc.getChannel(entry.channel_id) orelse return EBADF;

    // Check for pending message from client
    if (chan.client.pending_msg) |msg| {
        // Message available — deliver directly to user buffer
        // (We're in the server's address space, so user pointers are valid)
        deliverToUserBuf(msg, msg_buf_ptr);
        chan.client.pending_msg = null;
        return 0;
    }

    // No message pending — block waiting for one
    proc.ipc_recv_buf_ptr = msg_buf_ptr;
    chan.server.recv_waiting = true;
    chan.server.blocked_pid = proc.pid;
    proc.state = .blocked;
    process.scheduleNext();
}

/// ipc_reply(fd, msg_buf_ptr) → 0 on success, negative on error.
/// Server-side: send a reply to the blocked client.
/// Dispatches based on client's pending_op to handle server-backed file operations.
fn sysIpcReply(fd: u64, reply_msg_ptr: u64) u64 {
    const proc = process.getCurrent() orelse return ENOSYS;
    const entry = proc.getFdEntry(@intCast(fd)) orelse return EBADF;

    if (reply_msg_ptr >= 0x0000_8000_0000_0000 or reply_msg_ptr == 0) return EFAULT;

    const chan = ipc.getChannel(entry.channel_id) orelse return EBADF;

    // Read reply from server's user space
    const reply_tag_ptr: *align(1) const u32 = @ptrFromInt(reply_msg_ptr);
    const reply_len_ptr: *align(1) const u32 = @ptrFromInt(reply_msg_ptr + 4);
    const reply_data_ptr: [*]const u8 = @ptrFromInt(reply_msg_ptr + 8);

    const reply_tag = reply_tag_ptr.*;
    const reply_data_len = @min(reply_len_ptr.*, ipc.MAX_MSG_DATA);

    // Find the blocked client
    if (!chan.client.send_waiting or chan.client.blocked_pid == 0) return 0;
    const client_proc = process.getByPid(chan.client.blocked_pid) orelse return 0;

    const is_ok = reply_tag == @intFromEnum(ipc.Tag.r_ok);

    switch (client_proc.pending_op) {
        .open, .create => {
            if (is_ok and reply_data_len >= 4) {
                // Extract handle from reply, store in fd entry
                const handle = readU32LE(reply_data_ptr[0..4]);
                if (client_proc.getFdEntryPtr(client_proc.pending_fd)) |fd_entry| {
                    fd_entry.server_handle = handle;
                }
                // syscall_ret already set to fd in sysOpen/sysCreate
            } else {
                // Error: deallocate the pre-allocated fd
                client_proc.closeFd(client_proc.pending_fd);
                client_proc.syscall_ret = ENOENT;
            }
        },
        .read => {
            if (is_ok) {
                if (reply_data_len > 0 and client_proc.ipc_recv_buf_ptr != 0) {
                    // Copy reply data to client's buffer via deferred delivery
                    client_proc.ipc_msg = ipc.Message.init(.r_ok);
                    client_proc.ipc_msg.data_len = reply_data_len;
                    @memcpy(client_proc.ipc_msg.data_buf[0..reply_data_len], reply_data_ptr[0..reply_data_len]);
                    client_proc.ipc_pending_msg = &client_proc.ipc_msg;
                }
                client_proc.syscall_ret = reply_data_len;
                // Update read_offset in fd entry
                if (client_proc.getFdEntryPtr(client_proc.pending_fd)) |fd_entry| {
                    fd_entry.read_offset += reply_data_len;
                }
            } else {
                client_proc.syscall_ret = EIO;
                client_proc.ipc_recv_buf_ptr = 0;
            }
        },
        .write => {
            if (is_ok and reply_data_len >= 4) {
                client_proc.syscall_ret = readU32LE(reply_data_ptr[0..4]);
            } else if (is_ok) {
                // Server replied OK but no explicit length — derive from request
                client_proc.syscall_ret = if (client_proc.ipc_msg.data_len > 4)
                    client_proc.ipc_msg.data_len - 4
                else
                    0;
            } else {
                client_proc.syscall_ret = EIO;
            }
        },
        .close => {
            client_proc.closeFd(client_proc.pending_fd);
            client_proc.syscall_ret = 0;
        },
        .stat => {
            if (is_ok and reply_data_len > 0 and client_proc.ipc_recv_buf_ptr != 0) {
                // Copy stat data to client's buffer via deferred delivery
                client_proc.ipc_msg = ipc.Message.init(.r_ok);
                const copy_len = @min(reply_data_len, 64);
                client_proc.ipc_msg.data_len = copy_len;
                @memcpy(client_proc.ipc_msg.data_buf[0..copy_len], reply_data_ptr[0..copy_len]);
                client_proc.ipc_pending_msg = &client_proc.ipc_msg;
                client_proc.syscall_ret = 0;
            } else {
                client_proc.syscall_ret = if (is_ok) 0 else EIO;
                client_proc.ipc_recv_buf_ptr = 0;
            }
        },
        .remove => {
            client_proc.syscall_ret = if (is_ok) 0 else ENOENT;
        },
        .console_read, .net_read, .net_connect, .net_listen, .dns_query, .icmp_read, .pipe_read, .pipe_write, .sleep => {
            // These don't go through IPC — should not happen here
        },
        .none => {
            // Raw IPC (existing behavior for servers using ipc_recv/ipc_reply directly)
            if (is_ok) {
                if (client_proc.ipc_recv_buf_ptr != 0 and reply_data_len > 0) {
                    // Client was doing a raw read — copy reply data
                    client_proc.ipc_msg = ipc.Message.init(.r_ok);
                    client_proc.ipc_msg.data_len = reply_data_len;
                    @memcpy(client_proc.ipc_msg.data_buf[0..reply_data_len], reply_data_ptr[0..reply_data_len]);
                    client_proc.ipc_pending_msg = &client_proc.ipc_msg;
                    client_proc.syscall_ret = reply_data_len;
                } else {
                    // Client was doing a raw write — return data_len as bytes written
                    client_proc.syscall_ret = client_proc.ipc_msg.data_len;
                    client_proc.ipc_recv_buf_ptr = 0;
                }
            } else {
                client_proc.syscall_ret = EIO;
                client_proc.ipc_recv_buf_ptr = 0;
            }
        },
    }

    // For .read/.stat with deferred delivery, keep pending_op so switchTo knows
    // to do raw data copy instead of IpcMessage copy. switchTo clears it.
    if ((client_proc.pending_op != .read and client_proc.pending_op != .stat) or client_proc.ipc_pending_msg == null) {
        client_proc.pending_op = .none;
    }
    client_proc.state = .ready;
    chan.client.send_waiting = false;
    chan.client.blocked_pid = 0;

    return 0;
}

/// Copy an IPC message to a user-space IpcMessage buffer.
fn deliverToUserBuf(msg: *const ipc.Message, user_buf_ptr: u64) void {
    if (user_buf_ptr == 0 or user_buf_ptr >= 0x0000_8000_0000_0000) return;

    const tag_ptr: *align(1) u32 = @ptrFromInt(user_buf_ptr);
    const len_ptr: *align(1) u32 = @ptrFromInt(user_buf_ptr + 4);
    const data_ptr: [*]u8 = @ptrFromInt(user_buf_ptr + 8);

    tag_ptr.* = @intFromEnum(msg.tag);
    len_ptr.* = msg.data_len;
    if (msg.data_len > 0) {
        @memcpy(data_ptr[0..msg.data_len], msg.data_buf[0..msg.data_len]);
    }
}

fn sysExec(elf_ptr: u64, elf_len: u64) u64 {
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

    // === Point of no return: swap to new address space ===
    // Old PML4 + user pages leaked (cleanup is future work)
    proc.pml4 = new_pml4;
    proc.user_rip = load_result.entry_point;
    proc.user_rsp = stack_top;
    proc.user_rflags = 0x202; // IF=1, reserved bit 1
    proc.brk = load_result.brk;
    proc.pages_used = 0;
    proc.saved_kernel_rsp = 0; // Force IRETQ path in switchTo
    proc.syscall_ret = 0;

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

/// Userspace FdMapping: which parent fd maps to which child fd.
const FdMapping = extern struct {
    child_fd: u32,
    parent_fd: u32,
};

/// Write data to a child process's virtual address by translating through its page tables.
/// The kernel runs under the parent's CR3, so we can't dereference child addresses directly.
fn writeToChildMem(child_pml4: *paging.PageTable, vaddr: u64, data: []const u8) bool {
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

/// Static buffer for building argv layout (in .bss to avoid kernel stack use).
/// Max 4096 bytes — one page for argv data.
var argv_layout_buf: [4096]u8 linksection(".bss") = undefined;

fn sysSpawn(elf_ptr: u64, elf_len: u64, fd_map_ptr: u64, fd_map_len: u64, argv_ptr: u64) u64 {
    const parent = process.getCurrent() orelse return ENOSYS;

    // Validate ELF pointer
    if (elf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    if (elf_len == 0 or elf_len > 4 * 1024 * 1024) return EINVAL;

    // Validate fd map pointer
    if (fd_map_len > process.MAX_FDS) return EINVAL;
    if (fd_map_len > 0 and fd_map_ptr >= 0x0000_8000_0000_0000) return EFAULT;

    const elf_data: []const u8 = @as([*]const u8, @ptrFromInt(elf_ptr))[0..@intCast(elf_len)];

    // Create child process
    const child = process.create() orelse return ENOMEM;

    // Load ELF into child's address space
    const load_result = elf.load(child.pml4.?, elf_data) catch {
        child.state = .dead;
        return ENOMEM;
    };
    child.user_rip = load_result.entry_point;
    child.brk = load_result.brk;

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
    if (argv_ptr != 0 and argv_ptr < 0x0000_8000_0000_0000) {
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

    // Copy namespace from parent (Plan 9: children inherit namespace)
    parent.ns.cloneInto(&child.ns);

    // Copy fd mappings from parent to child
    if (fd_map_len > 0) {
        const pipe_mod = @import("pipe.zig");
        const fd_maps: [*]const FdMapping = @ptrFromInt(fd_map_ptr);
        for (0..@intCast(fd_map_len)) |i| {
            const m = fd_maps[i];
            if (m.parent_fd < process.MAX_FDS and m.child_fd < process.MAX_FDS) {
                if (parent.fds[m.parent_fd]) |fentry| {
                    child.fds[m.child_fd] = fentry;
                    // Increment pipe refcount for duplicated pipe fds
                    if (fentry.fd_type == .pipe) {
                        if (fentry.pipe_is_read) {
                            pipe_mod.incrementReaders(fentry.pipe_id);
                        } else {
                            pipe_mod.incrementWriters(fentry.pipe_id);
                        }
                    }
                }
            }
        }
    }

    klog.debug("[spawn: parent=");
    klog.debugDec(parent.pid);
    klog.debug(" child=");
    klog.debugDec(child.pid);
    klog.debug(" entry=");
    klog.debugHex(load_result.entry_point);
    klog.debug("]\n");

    return child.pid;
}
