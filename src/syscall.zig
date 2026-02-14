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
};

/// Error return values.
const ENOSYS: u64 = @bitCast(@as(i64, -1));
const EBADF: u64 = @bitCast(@as(i64, -9));
const EFAULT: u64 = @bitCast(@as(i64, -14));
const ENOENT: u64 = @bitCast(@as(i64, -2));
const EMFILE: u64 = @bitCast(@as(i64, -24));
const EIO: u64 = @bitCast(@as(i64, -5));

/// Main syscall dispatch. Called from arch-specific entry point.
pub fn dispatch(nr: u64, arg0: u64, arg1: u64, arg2: u64, _: u64, _: u64) u64 {
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
        .create, .stat, .seek, .remove => {
            serial.puts("syscall: unimplemented nr=");
            serial.putDec(nr);
            serial.puts("\n");
            return ENOSYS;
        },
        .mount, .bind, .unmount, .rfork, .exec, .wait, .pipe, .brk => {
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
    // Direct framebuffer path for stdout (1) and stderr (2)
    if (fd == 1 or fd == 2) {
        if (buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
        if (count == 0) return 0;
        const buf: [*]const u8 = @ptrFromInt(buf_ptr);
        const len: usize = @intCast(@min(count, 4096));
        console.puts(buf[0..len]);
        return len;
    }

    // IPC path: send T_WRITE message to the file server
    const proc = process.getCurrent() orelse return EBADF;
    const entry = proc.getFdEntry(@intCast(fd)) orelse return EBADF;

    if (buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    if (count == 0) return 0;

    const buf: [*]const u8 = @ptrFromInt(buf_ptr);
    const len: u32 = @intCast(@min(count, ipc.MAX_MSG_DATA));

    // Build T_WRITE message in the process's IPC buffer
    proc.ipc_msg = ipc.Message.init(.t_write);
    @memcpy(proc.ipc_msg.data_buf[0..len], buf[0..len]);
    proc.ipc_msg.data_len = len;

    // Put message in channel
    const chan = ipc.getChannel(entry.channel_id) orelse return EBADF;
    chan.client.pending_msg = &proc.ipc_msg;
    chan.client.send_waiting = true;
    chan.client.blocked_pid = proc.pid;

    // Check if server is blocked in recv — deliver directly
    if (chan.server.recv_waiting and chan.server.blocked_pid != 0) {
        if (process.getByPid(chan.server.blocked_pid)) |server_proc| {
            // Queue message for delivery when server resumes
            server_proc.ipc_pending_msg = &proc.ipc_msg;
            server_proc.state = .ready;
            server_proc.syscall_ret = 0; // ipc_recv returns 0 (success)
            chan.server.recv_waiting = false;
            chan.server.blocked_pid = 0;
        }
    }

    // Block client waiting for reply
    proc.state = .blocked;
    process.scheduleNext();
}

/// exit(status) — terminate the current process and schedule next.
fn sysExit(status: u64) noreturn {
    serial.puts("[Process ");
    if (process.getCurrent()) |proc| {
        serial.putDec(proc.pid);
        proc.state = .dead;
    }
    serial.puts(" exited with status ");
    serial.putDec(status);
    serial.puts("]\n");

    console.puts("[Process exited with status ");
    console.putDec(status);
    console.puts("]\n");

    process.scheduleNext();
}

/// open(path_ptr, path_len) → fd
/// Resolves path in the process's namespace, allocates an fd for the channel.
fn sysOpen(path_ptr: u64, path_len: u64) u64 {
    const proc = process.getCurrent() orelse return ENOSYS;
    if (path_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    if (path_len == 0 or path_len > 256) return ENOENT;

    const path: [*]const u8 = @ptrFromInt(path_ptr);
    const resolved = proc.ns.resolve(path[0..@intCast(path_len)]) orelse return ENOENT;

    // Allocate fd as a client end of the resolved channel
    const fd = proc.allocFd(resolved.channel_id, false) orelse return EMFILE;
    return fd;
}

/// read(fd, buf, count) → bytes_read
/// For IPC channels: sends T_READ to the server and blocks for reply.
fn sysRead(fd: u64, buf_ptr: u64, count: u64) u64 {
    if (fd == 0) return 0; // stdin: nothing to read for now

    const proc = process.getCurrent() orelse return EBADF;
    const entry = proc.getFdEntry(@intCast(fd)) orelse return EBADF;

    if (buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    if (count == 0) return 0;

    const len: u32 = @intCast(@min(count, ipc.MAX_MSG_DATA));

    // Build T_READ message
    proc.ipc_msg = ipc.Message.init(.t_read);
    proc.ipc_msg.data_len = len; // requested read size

    const chan = ipc.getChannel(entry.channel_id) orelse return EBADF;
    chan.client.pending_msg = &proc.ipc_msg;
    chan.client.send_waiting = true;
    chan.client.blocked_pid = proc.pid;

    // Check if server is blocked in recv
    if (chan.server.recv_waiting and chan.server.blocked_pid != 0) {
        if (process.getByPid(chan.server.blocked_pid)) |server_proc| {
            server_proc.ipc_pending_msg = &proc.ipc_msg;
            server_proc.state = .ready;
            server_proc.syscall_ret = 0;
            chan.server.recv_waiting = false;
            chan.server.blocked_pid = 0;
        }
    }

    // Block client waiting for reply (reply data will go into buf)
    // Store the user buffer so the reply can be copied there
    proc.ipc_recv_buf_ptr = buf_ptr;
    proc.state = .blocked;
    process.scheduleNext();
}

/// close(fd) → 0 or error
fn sysClose(fd: u64) u64 {
    const proc = process.getCurrent() orelse return EBADF;
    if (fd >= 32) return EBADF;
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

    // Find and wake the blocked client
    if (chan.client.send_waiting and chan.client.blocked_pid != 0) {
        if (process.getByPid(chan.client.blocked_pid)) |client_proc| {
            // Determine client return value based on reply tag
            if (reply_tag == @intFromEnum(ipc.Tag.r_ok)) {
                // For write: return bytes written (= original request data_len)
                // For read: need to copy reply data to client's buffer
                if (client_proc.ipc_recv_buf_ptr != 0 and reply_data_len > 0) {
                    // Client was doing a read — copy reply data to their buffer
                    // Build a temporary message to deliver
                    var delivery_msg = ipc.Message.init(.r_ok);
                    delivery_msg.data_len = reply_data_len;
                    @memcpy(delivery_msg.data_buf[0..reply_data_len], reply_data_ptr[0..reply_data_len]);
                    client_proc.ipc_pending_msg = null; // delivered inline below

                    // Store the data in client's ipc_msg for delivery
                    client_proc.ipc_msg = delivery_msg;
                    client_proc.ipc_pending_msg = &client_proc.ipc_msg;
                    client_proc.syscall_ret = reply_data_len;
                } else {
                    // Client was doing a write — return the data_len as bytes written
                    client_proc.syscall_ret = client_proc.ipc_msg.data_len;
                    client_proc.ipc_recv_buf_ptr = 0;
                }
            } else {
                // Error reply
                client_proc.syscall_ret = EIO;
                client_proc.ipc_recv_buf_ptr = 0;
            }
            client_proc.state = .ready;
            chan.client.send_waiting = false;
            chan.client.blocked_pid = 0;
        }
    }

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
