/// IPC and futex syscall handlers.
const process = @import("../process.zig");
const ipc = @import("../ipc.zig");
const root = @import("root.zig");

const ENOSYS = root.ENOSYS;
const EBADF = root.EBADF;
const EFAULT = root.EFAULT;
const EIO = root.EIO;
const ENOENT = root.ENOENT;
const ENOMEM = root.ENOMEM;
const EMFILE = root.EMFILE;
const EAGAIN: u64 = @bitCast(@as(i64, -11));
const readU32LE = root.readU32LE;
const writeU32LE = root.writeU32LE;
const sendToServer = root.sendToServer;

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

/// ipc_recv(fd, msg_buf_ptr) → 0 on success, negative on error.
/// Server-side: receive the next message on a channel.
/// Blocks if no message is pending.
pub fn sysIpcRecv(fd: u64, msg_buf_ptr: u64) u64 {
    const proc = process.getCurrent() orelse return ENOSYS;
    const entry = proc.getFdEntry(@intCast(fd)) orelse return EBADF;

    if (msg_buf_ptr >= 0x0000_8000_0000_0000 or msg_buf_ptr == 0) return EFAULT;

    const chan = ipc.getChannel(entry.channel_id) orelse return EBADF;

    chan.lock.lock();

    // Check for pending message from client ring buffer
    if (chan.client.dequeue()) |pending_entry| {
        // Message available — deliver directly to user buffer
        if (pending_entry.msg_ptr) |msg_ptr| {
            deliverToUserBuf(msg_ptr, msg_buf_ptr);
        }
        // Track which client we're serving so sysIpcReply knows who to wake
        proc.ipc_serving_client = pending_entry.pid;
        @import("../trace.zig").trace(.ipc_recv, pending_entry.pid);
        chan.lock.unlock();
        return 0;
    }

    // No message pending — add to server wait queue and block
    proc.ipc_recv_buf_ptr = msg_buf_ptr;
    if (chan.client.addServerWaiter(@intCast(proc.pid))) {
        // Successfully added to multi-server wait queue.
        // Do NOT set legacy recv_waiting/blocked_pid — those are only
        // for fallback when server_waiters is full.
    } else {
        // Queue full — use legacy single-waiter as fallback
        chan.client.recv_waiting = true;
        chan.client.blocked_pid = proc.pid;
    }
    proc.state = .blocked;

    chan.lock.unlock();
    process.scheduleNext();
}

/// ipc_reply(fd, msg_buf_ptr) → 0 on success, negative on error.
/// Server-side: send a reply to the blocked client.
/// Dispatches based on client's pending_op to handle server-backed file operations.
pub fn sysIpcReply(fd: u64, reply_msg_ptr: u64) u64 {
    const proc = process.getCurrent() orelse return ENOSYS;
    const entry = proc.getFdEntry(@intCast(fd)) orelse return EBADF;

    if (reply_msg_ptr >= 0x0000_8000_0000_0000 or reply_msg_ptr == 0) return EFAULT;

    _ = ipc.getChannel(entry.channel_id) orelse return EBADF;

    // Read reply from server's user space
    const reply_tag_ptr: *align(1) const u32 = @ptrFromInt(reply_msg_ptr);
    const reply_len_ptr: *align(1) const u32 = @ptrFromInt(reply_msg_ptr + 4);
    const reply_data_ptr: [*]const u8 = @ptrFromInt(reply_msg_ptr + 8);

    const reply_tag = reply_tag_ptr.*;
    const reply_data_len = @min(reply_len_ptr.*, ipc.effective_max_data);

    // Find the client being served by this server thread
    const serving_pid = proc.ipc_serving_client;
    @import("../trace.zig").trace(.ipc_reply, serving_pid);
    if (serving_pid == 0) return 0;
    const client_proc = process.getByPid(serving_pid) orelse {
        proc.ipc_serving_client = 0;
        return 0;
    };

    const is_ok = reply_tag == @intFromEnum(ipc.Tag.r_ok);
    const is_again = reply_tag == @intFromEnum(ipc.Tag.r_again);

    // Debug: log all IPC replies for compat processes (skip r_again, it's normal)
    if (client_proc.compat == 1 and !is_ok and !is_again) {
        const klog2 = @import("../klog.zig");
        klog2.err("[ipc] FAIL pid=");
        klog2.errDec(client_proc.pid);
        klog2.err(" op=");
        klog2.errDec(@intFromEnum(client_proc.pending_op));
        klog2.err(" fd=");
        klog2.errDec(client_proc.pending_fd);
        klog2.err(" tag=");
        klog2.errDec(reply_tag);
        klog2.err("\n");
    }

    switch (client_proc.pending_op) {
        .open, .create => {
            if (is_ok and reply_data_len >= 4) {
                const handle = readU32LE(reply_data_ptr[0..4]);
                if (client_proc.getFdEntryPtr(client_proc.pending_fd)) |fd_entry| {
                    fd_entry.server_handle = handle;
                }
            } else {
                if (client_proc.compat == 1) {
                    const klog2 = @import("../klog.zig");
                    klog2.err("[ipc] async open FAIL pid=");
                    klog2.errDec(client_proc.pid);
                    klog2.err(" fd=");
                    klog2.errDec(client_proc.pending_fd);
                    klog2.err("\n");
                }
                client_proc.closeFd(client_proc.pending_fd);
                client_proc.syscall_ret = ENOENT;
            }
        },
        .read => {
            if (is_again) {
                // Server says "no data yet, try again".
                // Always retry — blocking reads must wait for data.
                // The data thread handles timing independently;
                // when it finishes, the server sends a response on
                // the control socket, breaking the R_AGAIN loop.
                const client_entry = client_proc.getFdEntry(client_proc.pending_fd);
                if (client_entry) |ce| {
                    if (ipc.getChannel(ce.channel_id)) |chan| {
                        // Rebuild T_READ message with same parameters
                        const read_count: u32 = @intCast(@min(
                            if (client_proc.ipc_msg.data_len >= 12)
                                readU32LE(client_proc.ipc_msg.data_buf[8..12])
                            else
                                ipc.effective_max_data,
                            ipc.effective_max_data,
                        ));
                        client_proc.ipc_msg.reset(.t_read);
                        writeU32LE(client_proc.ipc_msg.data_buf[0..4], ce.server_handle);
                        writeU32LE(client_proc.ipc_msg.data_buf[4..8], ce.read_offset);
                        writeU32LE(client_proc.ipc_msg.data_buf[8..12], read_count);
                        client_proc.ipc_msg.data_len = 12;
                        sendToServer(chan, client_proc);
                        proc.ipc_serving_client = 0;
                        return 0; // Don't markReady — still blocked
                    }
                }
                // Can't retry (fd/channel gone) — return 0 (EOF)
                client_proc.syscall_ret = 0;
                client_proc.ipc_recv_buf_ptr = 0;
            } else if (is_ok) {
                if (reply_data_len > 0 and client_proc.ipc_recv_buf_ptr != 0) {
                    client_proc.ipc_msg.reset(.r_ok);
                    client_proc.ipc_msg.data_len = reply_data_len;
                    @memcpy(client_proc.ipc_msg.data_buf[0..reply_data_len], reply_data_ptr[0..reply_data_len]);
                    client_proc.ipc_pending_msg = &client_proc.ipc_msg;
                }
                client_proc.syscall_ret = reply_data_len;
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
                client_proc.ipc_msg.reset(.r_ok);
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
        .remove, .rename => {
            client_proc.syscall_ret = if (is_ok) 0 else ENOENT;
        },
        .truncate, .wstat => {
            client_proc.syscall_ret = if (is_ok) 0 else EIO;
        },
        .linux_stat_open => {
            // Linux compat multi-step stat: open phase completed.
            if (is_ok and reply_data_len >= 4) {
                const handle = readU32LE(reply_data_ptr[0..4]);
                if (client_proc.getFdEntryPtr(client_proc.pending_fd)) |fd_entry| {
                    fd_entry.server_handle = handle;
                }
                client_proc.ipc_msg.reset(.t_stat);
                writeU32LE(client_proc.ipc_msg.data_buf[0..4], handle);
                client_proc.ipc_msg.data_len = 4;
                client_proc.pending_op = .linux_stat_done;
                client_proc.ipc_recv_buf_ptr = client_proc.linux_stat_buf;
                client_proc.linux_stat_fd = client_proc.pending_fd;
                if (client_proc.getFdEntry(client_proc.pending_fd)) |fd_entry| {
                    if (ipc.getChannel(fd_entry.channel_id)) |stat_chan| {
                        sendToServer(stat_chan, client_proc);
                        proc.ipc_serving_client = 0;
                        return 0;
                    }
                }
                client_proc.closeFd(client_proc.pending_fd);
                client_proc.linux_stat_buf = 0;
                client_proc.linux_stat_fd = 0;
                client_proc.syscall_ret = EIO;
            } else {
                client_proc.closeFd(client_proc.pending_fd);
                client_proc.linux_stat_buf = 0;
                client_proc.syscall_ret = ENOENT;
            }
        },
        .linux_stat_done => {
            // Linux compat multi-step stat: stat phase completed. Translate + close.
            if (is_ok and reply_data_len > 0 and client_proc.ipc_recv_buf_ptr != 0) {
                client_proc.ipc_msg.reset(.r_ok);
                const copy_len = @min(reply_data_len, 64);
                client_proc.ipc_msg.data_len = copy_len;
                @memcpy(client_proc.ipc_msg.data_buf[0..copy_len], reply_data_ptr[0..copy_len]);
                client_proc.ipc_pending_msg = &client_proc.ipc_msg;
                // Set pending_op to .stat so switchTo delivers raw data + translates
                client_proc.pending_op = .stat;
                client_proc.syscall_ret = 0;
            } else {
                client_proc.syscall_ret = if (is_ok) 0 else EIO;
                client_proc.ipc_recv_buf_ptr = 0;
            }
            // Close the temp fd
            if (client_proc.linux_stat_fd > 0) {
                client_proc.closeFd(client_proc.linux_stat_fd);
            }
            client_proc.linux_stat_fd = 0;
            client_proc.linux_stat_buf = 0;
        },
        .linux_sock_step => {
            if (comptime @import("build_options").containers) {
                const linux_socket = @import("../linux_socket.zig");
                const still_blocked = linux_socket.handleResume(client_proc, is_ok, reply_data_ptr, reply_data_len);
                if (still_blocked) {
                    proc.ipc_serving_client = 0;
                    return 0; // Don't markReady — still blocked
                }
            }
            // Fall through to markReady
        },
        .linux_exec_wait => {
            // linuxd replied — it already replaced image via OP_EXEC + OP_SETARGV.
            client_proc.closeFd(client_proc.pending_fd);
            if (!is_ok) {
                client_proc.syscall_ret = ENOENT;
            }
            // syscall_ret and saved_kernel_rsp already set by OP_EXEC
        },
        .console_read, .pipe_read, .pipe_write, .sleep, .ether_read, .poll_wait, .irq_read => {},
        .none => {
            if (is_ok) {
                if (client_proc.ipc_recv_buf_ptr != 0 and reply_data_len > 0) {
                    client_proc.ipc_msg.reset(.r_ok);
                    client_proc.ipc_msg.data_len = reply_data_len;
                    @memcpy(client_proc.ipc_msg.data_buf[0..reply_data_len], reply_data_ptr[0..reply_data_len]);
                    client_proc.ipc_pending_msg = &client_proc.ipc_msg;
                    client_proc.syscall_ret = reply_data_len;
                } else {
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
    process.markReady(client_proc);
    proc.ipc_serving_client = 0;

    // Track IPC activity for supervisor health probes
    @import("../supervisor.zig").updateActivity(proc.pid);

    return 0;
}

/// ipc_pair(result_ptr) → 0 on success, negative on error.
/// Creates an IPC channel pair and returns two fds: [server_fd, client_fd].
pub fn sysIpcPair(result_ptr: u64) u64 {
    const thread_group = @import("../thread_group.zig");
    const proc = process.getCurrent() orelse return ENOSYS;
    if (result_ptr == 0 or result_ptr >= 0x0000_8000_0000_0000) return EFAULT;

    const chan = ipc.channelCreate() catch return ENOMEM;

    // Find two free fd slots
    const fds = thread_group.getFdSlice(proc);
    var server_fd: ?u32 = null;
    var client_fd: ?u32 = null;
    for (3..process.MAX_FDS) |i| {
        if (fds[i] == null) {
            if (server_fd == null) {
                server_fd = @intCast(i);
            } else {
                client_fd = @intCast(i);
                break;
            }
        }
    }

    const s_fd = server_fd orelse return EMFILE;
    const c_fd = client_fd orelse return EMFILE;

    proc.setFd(s_fd, chan.server, true);
    proc.setFd(c_fd, chan.client, false);

    // Write [server_fd, client_fd] as two i32 values
    const result: [*]align(1) i32 = @ptrFromInt(result_ptr);
    result[0] = @intCast(s_fd);
    result[1] = @intCast(c_fd);

    return 0;
}

/// futex(addr, op, val, timeout) — futex wait/wake operations
pub fn sysFutex(addr: u64, op: u64, val: u64, timeout: u64) u64 {
    _ = timeout;
    const futex_mod = @import("../futex.zig");
    const proc = process.getCurrent() orelse return ENOSYS;

    const FUTEX_WAIT: u64 = 0;
    const FUTEX_WAKE: u64 = 1;
    const FUTEX_PRIVATE_FLAG: u64 = 128;

    const raw_op = op & ~FUTEX_PRIVATE_FLAG;

    if (raw_op == FUTEX_WAIT) {
        return futex_mod.wait(proc, addr, @truncate(val));
    } else if (raw_op == FUTEX_WAKE) {
        return futex_mod.wake(proc, addr, @truncate(val));
    }
    return ENOSYS;
}
