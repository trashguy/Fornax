/// Fornax Plan 9-inspired syscall interface.
///
/// Syscall numbers — NOT Linux-compatible. Fornax has its own ABI.
/// Convention: RAX=nr, RDI=a0, RSI=a1, RDX=a2, R10=a3, R8=a4
const std = @import("std");
const console = @import("console.zig");
const serial = @import("serial.zig");
const process = @import("process.zig");
const ipc = @import("ipc.zig");
const namespace = @import("namespace.zig");
const elf = @import("elf.zig");
const paging = switch (@import("builtin").cpu.arch) {
    .x86_64 => @import("arch/x86_64/paging.zig"),
    else => struct {},
};
const pmm = @import("pmm.zig");
const mem = @import("mem.zig");

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
        }
    }
}

/// Main syscall dispatch. Called from arch-specific entry point.
pub fn dispatch(nr: u64, arg0: u64, arg1: u64, arg2: u64, arg3: u64, _: u64) u64 {
    // Save user context to the current process at the start of every syscall.
    // This snapshots RIP/RSP/RFLAGS so blocking syscalls can schedule away.
    process.saveCurrentContext();

    const sys = std.meta.intToEnum(SYS, nr) catch {
        serial.puts("syscall: unknown nr=");
        serial.putDec(nr);
        serial.puts("\n");
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
        .stat, .seek, .remove => {
            serial.puts("syscall: unimplemented nr=");
            serial.putDec(nr);
            serial.puts("\n");
            return ENOSYS;
        },
        .exec => sysExec(arg0, arg1),
        .wait => sysWait(arg0),
        .spawn => sysSpawn(arg0, arg1, arg2, arg3),
        .mount, .bind, .unmount, .rfork, .pipe, .brk => {
            serial.puts("syscall: unimplemented nr=");
            serial.putDec(nr);
            serial.puts("\n");
            return ENOSYS;
        },
    };
}

/// write(fd, buf, count) → bytes_written
/// fd 1/2 → direct framebuffer console + serial (bootstrap path).
/// Other fds → IPC to file server via channel.
fn sysWrite(fd: u64, buf_ptr: u64, count: u64) u64 {
    // Console control (Plan 9 style: write to fd 0)
    if (fd == 0) {
        const keyboard = @import("keyboard.zig");
        if (buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
        if (count == 0) return 0;
        const buf: [*]const u8 = @ptrFromInt(buf_ptr);
        const len: usize = @intCast(@min(count, 64));
        keyboard.handleCtl(buf[0..len]);
        return len;
    }

    // Direct framebuffer path for stdout (1) and stderr (2)
    if (fd == 1 or fd == 2) {
        if (buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
        if (count == 0) return 0;
        const buf: [*]const u8 = @ptrFromInt(buf_ptr);
        const len: usize = @intCast(@min(count, 4096));
        console.puts(buf[0..len]);
        return len;
    }

    const proc = process.getCurrent() orelse return EBADF;
    const entry = proc.getFdEntry(@intCast(fd)) orelse return EBADF;

    if (buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    if (count == 0) return 0;

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

    serial.puts("[Process ");
    serial.putDec(proc.pid);
    serial.puts(" exited with status ");
    serial.putDec(status);
    serial.puts("]\n");

    proc.exit_status = @truncate(status);

    // Kill all children recursively (Fornax orphan policy)
    process.killChildren(proc.pid);

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
                        // Reap this zombie
                        const status: u64 = p.exit_status;
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
    serial.puts("[pid=");
    serial.putDec(proc.pid);
    serial.puts(" blocked in wait");
    if (wait_pid != 0) {
        serial.puts(" for pid=");
        serial.putDec(wait_pid);
    }
    serial.puts("]\n");
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
    if (fd == 0) {
        // Console read (stdin)
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
        const proc = process.getCurrent() orelse return EBADF;
        proc.pending_op = .console_read;
        proc.ipc_recv_buf_ptr = buf_ptr;
        proc.pending_fd = @intCast(@min(count, 4096)); // stash requested size
        keyboard.registerWaiter(@intCast(proc.pid), buf_ptr, @intCast(@min(count, 4096)));
        proc.state = .blocked;
        process.scheduleNext();
    }

    const proc = process.getCurrent() orelse return EBADF;
    const entry_ptr = proc.getFdEntryPtr(@intCast(fd)) orelse return EBADF;

    if (buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    if (count == 0) return 0;

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
        tcp.setReadWaiter(entry_ptr.net_conn, @intCast(proc.pid));
        proc.pending_op = .net_read;
        proc.pending_fd = @intCast(fd);
        proc.ipc_recv_buf_ptr = buf_ptr;
        // Stash count for when we wake up
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

/// close(fd) → 0 or error
fn sysClose(fd: u64) u64 {
    const proc = process.getCurrent() orelse return EBADF;
    if (fd >= 32) return EBADF;

    const entry = proc.getFdEntry(@intCast(fd)) orelse return EBADF;

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
                serial.puts("[ipc_reply .read: data_len=");
                serial.putDec(reply_data_len);
                serial.puts("]\n");
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
            client_proc.syscall_ret = if (is_ok) 0 else EIO;
        },
        .console_read, .net_read, .net_connect, .net_listen, .dns_query => {
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

    // For .read with deferred delivery, keep pending_op so switchTo knows
    // to do raw data copy instead of IpcMessage copy. switchTo clears it.
    if (client_proc.pending_op != .read or client_proc.ipc_pending_msg == null) {
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

    serial.puts("[exec: pid=");
    serial.putDec(proc.pid);
    serial.puts(" new entry=0x");
    serial.putHex(load_result.entry_point);
    serial.puts("]\n");

    process.scheduleNext(); // noreturn — process resumes with new image
}

/// Userspace FdMapping: which parent fd maps to which child fd.
const FdMapping = extern struct {
    child_fd: u32,
    parent_fd: u32,
};

fn sysSpawn(elf_ptr: u64, elf_len: u64, fd_map_ptr: u64, fd_map_len: u64) u64 {
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
    child.user_rsp = mem.USER_STACK_INIT;

    // Copy namespace from parent (Plan 9: children inherit namespace)
    parent.ns.cloneInto(&child.ns);

    // Copy fd mappings from parent to child
    if (fd_map_len > 0) {
        const fd_maps: [*]const FdMapping = @ptrFromInt(fd_map_ptr);
        for (0..@intCast(fd_map_len)) |i| {
            const m = fd_maps[i];
            if (m.parent_fd < process.MAX_FDS and m.child_fd < process.MAX_FDS) {
                if (parent.fds[m.parent_fd]) |fentry| {
                    child.fds[m.child_fd] = fentry;
                }
            }
        }
    }

    serial.puts("[spawn: parent=");
    serial.putDec(parent.pid);
    serial.puts(" child=");
    serial.putDec(child.pid);
    serial.puts(" entry=0x");
    serial.putHex(load_result.entry_point);
    serial.puts("]\n");

    return child.pid;
}
