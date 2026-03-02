/// Linux socket syscall emulation for containers.
///
/// Translates BSD socket API calls (socket/connect/bind/listen/accept/send/recv/poll)
/// into Plan 9 /net/tcp/* file operations via IPC, routed through the process's namespace.
/// This ensures container processes use their container IP (via netd) rather than the host IP.
const process = @import("process.zig");
const syscall = @import("syscall.zig");
const timer = @import("timer.zig");
const ipc = @import("ipc.zig");
const namespace = @import("namespace.zig");
const serial = @import("serial.zig");
const klog = @import("klog.zig");

const syscall_root = @import("syscall/root.zig");
const sendToServer = syscall_root.sendToServer;
const readU32LE = syscall_root.readU32LE;
const writeU32LE = syscall_root.writeU32LE;

// ── Linux error constants (negative errno) ─────────────────────────────
const ENOSYS: u64 = @bitCast(@as(i64, -38));
const EFAULT: u64 = @bitCast(@as(i64, -14));
const EBADF: u64 = @bitCast(@as(i64, -9));
const EINVAL: u64 = @bitCast(@as(i64, -22));
const ENOMEM: u64 = @bitCast(@as(i64, -12));
const EAFNOSUPPORT: u64 = @bitCast(@as(i64, -97));
const ECONNREFUSED: u64 = @bitCast(@as(i64, -111));
const ENOTCONN: u64 = @bitCast(@as(i64, -107));
const ENOPROTOOPT: u64 = @bitCast(@as(i64, -92));
const EMFILE: u64 = @bitCast(@as(i64, -24));
const EAGAIN: u64 = @bitCast(@as(i64, -11));
const EIO: u64 = @bitCast(@as(i64, -5));

// ── Linux constants ────────────────────────────────────────────────────
const AF_INET: u64 = 2;
const SOCK_STREAM: u64 = 1;
const SOCK_TYPE_MASK: u64 = 0xFF;

// Poll event bits
const POLLIN: i16 = 0x0001;
const POLLOUT: i16 = 0x0004;
const POLLHUP: i16 = 0x0010;
const POLLNVAL: i16 = 0x0020;

// Socket option levels / names (stubs)
const SOL_SOCKET: u64 = 1;
const SO_ERROR: u64 = 4;
const SO_REUSEADDR: u64 = 2;
const SO_KEEPALIVE: u64 = 9;
const SO_REUSEPORT: u64 = 15;
const IPPROTO_TCP: u64 = 6;
const TCP_NODELAY: u64 = 1;

// ── Socket operation types (encoded in linux_stat_buf bits 8-15) ──────
const OP_CONNECT: u64 = 0;
const OP_LISTEN: u64 = 1;
const OP_ACCEPT: u64 = 2;

const MAX_SOCKETS: usize = 64;

// ── Per-connection socket metadata ─────────────────────────────────────
// Tracks state that the Plan 9 model doesn't need but BSD sockets do.
const SocketMeta = struct {
    in_use: bool = false,
    pid: u32 = 0, // owning process pid
    sock_fd: u8 = 0, // Fornax fd returned to Linux app
    bound_port: u16 = 0,
    listening: bool = false,
    conn_num: u16 = 0, // /net/tcp/N connection number
    ipc_ctl_fd: u8 = 0, // fd for /net/tcp/N/ctl (kept for lifecycle)
    remote_ip: [4]u8 = .{ 0, 0, 0, 0 },
    remote_port: u16 = 0,
};
var socket_meta: [MAX_SOCKETS]SocketMeta = [_]SocketMeta{.{}} ** MAX_SOCKETS;

fn findMeta(pid: u32, fd: u32) ?*SocketMeta {
    for (&socket_meta) |*m| {
        if (m.in_use and m.pid == pid and m.sock_fd == @as(u8, @intCast(fd))) return m;
    }
    return null;
}

fn allocMeta(pid: u32, fd: u32) ?*SocketMeta {
    for (&socket_meta) |*m| {
        if (!m.in_use) {
            m.* = .{ .in_use = true, .pid = pid, .sock_fd = @intCast(fd) };
            return m;
        }
    }
    return null;
}

fn freeMeta(pid: u32, fd: u32) void {
    for (&socket_meta) |*m| {
        if (m.in_use and m.pid == pid and m.sock_fd == @as(u8, @intCast(fd))) {
            m.* = .{};
            return;
        }
    }
}

fn metaIndex(m: *SocketMeta) u8 {
    const base = @intFromPtr(&socket_meta[0]);
    const ptr = @intFromPtr(m);
    return @intCast((ptr - base) / @sizeOf(SocketMeta));
}

// ── sockaddr_in parsing helpers ────────────────────────────────────────

fn parseSockaddrIn(addr_ptr: u64, addr_len: u64) ?struct { ip: [4]u8, port: u16 } {
    if (addr_len < 8) return null;
    const ptr: [*]const u8 = @ptrFromInt(addr_ptr);

    // sa_family at offset 0 (u16 LE) — must be AF_INET (2)
    const family = @as(u16, ptr[0]) | (@as(u16, ptr[1]) << 8);
    if (family != AF_INET) return null;

    // sin_port at offset 2 (big-endian)
    const port: u16 = @as(u16, ptr[2]) << 8 | ptr[3];

    // sin_addr at offset 4 (network byte order = [4]u8)
    const ip = [4]u8{ ptr[4], ptr[5], ptr[6], ptr[7] };

    return .{ .ip = ip, .port = port };
}

fn writeSockaddrIn(addr_ptr: u64, addr_len_ptr: u64, ip: [4]u8, port: u16) void {
    if (addr_ptr == 0) return;
    const ptr: [*]u8 = @ptrFromInt(addr_ptr);

    ptr[0] = 2; // AF_INET (LE)
    ptr[1] = 0;
    ptr[2] = @truncate(port >> 8); // sin_port (big-endian)
    ptr[3] = @truncate(port);
    ptr[4] = ip[0]; // sin_addr (network order)
    ptr[5] = ip[1];
    ptr[6] = ip[2];
    ptr[7] = ip[3];
    @memset(ptr[8..16], 0); // sin_zero

    if (addr_len_ptr != 0) {
        const len_ptr: *u32 = @ptrFromInt(addr_len_ptr);
        len_ptr.* = 16;
    }
}

// ── Path formatting helpers ───────────────────────────────────────────

/// Format a /net/tcp/N/suffix path into buf. Returns slice of formatted path.
fn fmtConnPath(buf: []u8, conn_num: u16, suffix: []const u8) []const u8 {
    const prefix = "tcp/";
    var pos: usize = 0;

    // Copy prefix
    if (pos + prefix.len > buf.len) return buf[0..0];
    @memcpy(buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;

    // Write connection number as decimal
    if (conn_num == 0) {
        buf[pos] = '0';
        pos += 1;
    } else {
        var tmp: [5]u8 = undefined;
        var tmp_len: usize = 0;
        var n = conn_num;
        while (n > 0) {
            tmp[tmp_len] = @intCast((n % 10) + '0');
            tmp_len += 1;
            n /= 10;
        }
        // Reverse
        var i: usize = 0;
        while (i < tmp_len) : (i += 1) {
            buf[pos] = tmp[tmp_len - 1 - i];
            pos += 1;
        }
    }

    // Copy suffix (e.g. "/ctl", "/data", "/listen")
    if (suffix.len > 0) {
        if (pos + suffix.len > buf.len) return buf[0..0];
        @memcpy(buf[pos..][0..suffix.len], suffix);
        pos += suffix.len;
    }

    return buf[0..pos];
}

/// Format "connect ip!port\n" command string.
fn fmtConnectCmd(buf: []u8, ip: [4]u8, port: u16) []const u8 {
    const cmd = "connect ";
    var pos: usize = 0;

    @memcpy(buf[pos..][0..cmd.len], cmd);
    pos += cmd.len;

    // Format IP
    for (ip, 0..) |octet, idx| {
        if (idx > 0) {
            buf[pos] = '.';
            pos += 1;
        }
        pos += fmtDecimal(buf[pos..], octet);
    }

    buf[pos] = '!';
    pos += 1;

    // Format port
    pos += fmtDecimal16(buf[pos..], port);

    buf[pos] = '\n';
    pos += 1;

    return buf[0..pos];
}

/// Format "announce port\n" command string.
fn fmtAnnounceCmd(buf: []u8, port: u16) []const u8 {
    const cmd = "announce ";
    var pos: usize = 0;

    @memcpy(buf[pos..][0..cmd.len], cmd);
    pos += cmd.len;

    pos += fmtDecimal16(buf[pos..], port);

    buf[pos] = '\n';
    pos += 1;

    return buf[0..pos];
}

fn fmtDecimal(buf: []u8, val: u8) usize {
    if (val >= 100) {
        buf[0] = @intCast(val / 100 + '0');
        buf[1] = @intCast((val / 10) % 10 + '0');
        buf[2] = @intCast(val % 10 + '0');
        return 3;
    } else if (val >= 10) {
        buf[0] = @intCast(val / 10 + '0');
        buf[1] = @intCast(val % 10 + '0');
        return 2;
    } else {
        buf[0] = @intCast(val + '0');
        return 1;
    }
}

fn fmtDecimal16(buf: []u8, val: u16) usize {
    var tmp: [5]u8 = undefined;
    var tmp_len: usize = 0;
    var n = val;
    if (n == 0) {
        buf[0] = '0';
        return 1;
    }
    while (n > 0) {
        tmp[tmp_len] = @intCast((n % 10) + '0');
        tmp_len += 1;
        n /= 10;
    }
    var i: usize = 0;
    while (i < tmp_len) : (i += 1) {
        buf[i] = tmp[tmp_len - 1 - i];
    }
    return tmp_len;
}

/// Parse a decimal number from a byte slice (e.g. "3\n" → 3).
fn parseDecimal(data: []const u8) ?u16 {
    var result: u16 = 0;
    var found = false;
    for (data) |c| {
        if (c >= '0' and c <= '9') {
            result = result * 10 + @as(u16, c - '0');
            found = true;
        } else if (c == '\n' or c == ' ' or c == 0) {
            break;
        } else {
            return null; // invalid character
        }
    }
    return if (found) result else null;
}

// ── IPC open helper ───────────────────────────────────────────────────

/// Open a path via the process's namespace. Allocates a temp fd, builds T_OPEN,
/// sends to server. The process is left blocked with pending_op = .linux_sock_step.
/// Returns true on success (message sent), false on error (caller should set syscall_ret).
fn openNetPath(proc: *process.Process, path: []const u8) bool {
    const ns = proc.getNs();
    const resolved = ns.resolve(path) orelse return false;
    const chan = ipc.getChannel(resolved.channel_id) orelse return false;

    // Kernel-backed channels have no server — shouldn't happen for /net/
    if (chan.kernel_data != null) return false;

    const fd_val = proc.allocFd(resolved.channel_id, false) orelse return false;

    proc.pending_fd = fd_val;

    // Build T_OPEN: data = [prefix][suffix]
    proc.ipc_msg.reset(.t_open);
    const prefix = resolved.prefix;
    const suffix = resolved.suffix;
    const prefix_len: u32 = @intCast(prefix.len);
    const suffix_len: u32 = @intCast(suffix.len);
    if (prefix_len > 0) {
        @memcpy(proc.ipc_msg.data_buf[0..prefix_len], prefix);
    }
    if (suffix_len > 0) {
        @memcpy(proc.ipc_msg.data_buf[prefix_len..][0..suffix_len], suffix);
    }
    proc.ipc_msg.data_len = prefix_len + suffix_len;

    proc.state = .blocked;
    sendToServer(chan, proc);
    return true;
}

/// Send a T_READ on the current pending_fd. Returns true on success.
fn sendRead(proc: *process.Process) bool {
    const fd_entry = proc.getFdEntry(proc.pending_fd) orelse return false;
    const chan = ipc.getChannel(fd_entry.channel_id) orelse return false;

    proc.ipc_msg.reset(.t_read);
    writeU32LE(proc.ipc_msg.data_buf[0..4], fd_entry.server_handle);
    writeU32LE(proc.ipc_msg.data_buf[4..8], 0); // offset
    writeU32LE(proc.ipc_msg.data_buf[8..12], 256); // count
    proc.ipc_msg.data_len = 12;

    sendToServer(chan, proc);
    return true;
}

/// Send a T_WRITE with text data on the current pending_fd. Returns true on success.
fn sendWrite(proc: *process.Process, data: []const u8) bool {
    const fd_entry = proc.getFdEntry(proc.pending_fd) orelse return false;
    const chan = ipc.getChannel(fd_entry.channel_id) orelse return false;

    proc.ipc_msg.reset(.t_write);
    writeU32LE(proc.ipc_msg.data_buf[0..4], fd_entry.server_handle);
    const data_len: u32 = @intCast(@min(data.len, ipc.effective_max_data - 4));
    @memcpy(proc.ipc_msg.data_buf[4..][0..data_len], data[0..data_len]);
    proc.ipc_msg.data_len = 4 + data_len;

    sendToServer(chan, proc);
    return true;
}

// ── Stash encoding helpers ────────────────────────────────────────────
// linux_stat_buf: bits 0-7 = SocketMeta index, bits 8-15 = op type
// linux_stat_fd: step counter (0..4)

fn encodeStash(meta_idx: u8, op: u64) u64 {
    return @as(u64, meta_idx) | (op << 8);
}

fn stashMetaIdx(proc: *process.Process) u8 {
    return @truncate(proc.linux_stat_buf);
}

fn stashOp(proc: *process.Process) u64 {
    return (proc.linux_stat_buf >> 8) & 0xFF;
}

fn stashStep(proc: *process.Process) u32 {
    return proc.linux_stat_fd;
}

fn getMeta(idx: u8) *SocketMeta {
    return &socket_meta[idx];
}

// ── Socket syscall implementations ─────────────────────────────────────

/// socket(domain, type, protocol) → fd
/// Allocates a bare IPC fd placeholder. Actual server connection happens in connect/listen.
pub fn linuxSocket(domain: u64, sock_type: u64, _: u64) u64 {
    if (domain != AF_INET) return EAFNOSUPPORT;
    if (sock_type & SOCK_TYPE_MASK != SOCK_STREAM) return EAFNOSUPPORT;

    const proc = process.getCurrent() orelse return EFAULT;

    // Allocate a placeholder fd with channel_id=0 (will be filled in during connect/listen)
    const fd = proc.allocFd(0, false) orelse return EMFILE;

    const meta = allocMeta(proc.pid, fd) orelse {
        proc.closeFd(fd);
        return EMFILE;
    };
    _ = meta;

    return fd;
}

/// connect(fd, addr, addrlen) → 0 or error
/// Initiates a 5-step IPC state machine to open /net/tcp/clone, read conn number,
/// open ctl, write "connect ip!port", then open data.
pub fn linuxConnect(fd_arg: u64, addr_ptr: u64, addr_len: u64) u64 {
    const proc = process.getCurrent() orelse return EFAULT;
    const fd: u32 = @intCast(fd_arg);

    const addr = parseSockaddrIn(addr_ptr, addr_len) orelse return EINVAL;

    const meta = findMeta(proc.pid, fd) orelse return EBADF;
    meta.remote_ip = addr.ip;
    meta.remote_port = addr.port;

    const mi = metaIndex(meta);

    // Step 0: Open /net/tcp/clone
    proc.pending_op = .linux_sock_step;
    proc.linux_stat_buf = encodeStash(mi, OP_CONNECT);
    proc.linux_stat_fd = 0; // step 0

    if (!openNetPath(proc, "/net/tcp/clone")) {
        proc.pending_op = .none;
        return ECONNREFUSED;
    }

    process.scheduleNext();
}

/// bind(fd, addr, addrlen) → 0 or error
pub fn linuxBind(fd: u64, addr_ptr: u64, addr_len: u64) u64 {
    const proc = process.getCurrent() orelse return EFAULT;

    const addr = parseSockaddrIn(addr_ptr, addr_len) orelse return EINVAL;
    const meta = findMeta(proc.pid, @intCast(fd)) orelse return EBADF;
    meta.bound_port = addr.port;
    return 0;
}

/// listen(fd, backlog) → 0 or error
/// Initiates a 4-step IPC state machine: clone, read N, open ctl, write "announce port".
pub fn linuxListen(fd_arg: u64, _: u64) u64 {
    const proc = process.getCurrent() orelse return EFAULT;
    const fd: u32 = @intCast(fd_arg);

    const meta = findMeta(proc.pid, fd) orelse return EBADF;
    if (meta.bound_port == 0) return EINVAL;

    const mi = metaIndex(meta);

    // Step 0: Open /net/tcp/clone
    proc.pending_op = .linux_sock_step;
    proc.linux_stat_buf = encodeStash(mi, OP_LISTEN);
    proc.linux_stat_fd = 0; // step 0

    if (!openNetPath(proc, "/net/tcp/clone")) {
        proc.pending_op = .none;
        return EINVAL;
    }

    process.scheduleNext();
}

/// accept(fd, addr, addrlen) → new_fd or error
/// Initiates a 3-step IPC state machine: open listen, read child N, open child data.
pub fn linuxAccept(fd_arg: u64, addr_ptr: u64, addr_len_ptr: u64) u64 {
    const proc = process.getCurrent() orelse return EFAULT;
    const fd: u32 = @intCast(fd_arg);

    const meta = findMeta(proc.pid, fd) orelse return EBADF;
    if (!meta.listening) return EINVAL;

    const mi = metaIndex(meta);

    // Stash user pointers for accept result delivery
    proc.ipc_recv_buf_ptr = addr_ptr;
    proc.syscall_ret = addr_len_ptr;

    // Step 0: Open /net/tcp/N/listen (blocks in server until connection arrives)
    proc.pending_op = .linux_sock_step;
    proc.linux_stat_buf = encodeStash(mi, OP_ACCEPT);
    proc.linux_stat_fd = 0; // step 0

    var path_buf: [64]u8 = undefined;
    const path = fmtConnPath(&path_buf, meta.conn_num, "/listen");
    // Build full path with /net/ prefix
    var full_buf: [80]u8 = undefined;
    const full_prefix = "/net/";
    @memcpy(full_buf[0..full_prefix.len], full_prefix);
    @memcpy(full_buf[full_prefix.len..][0..path.len], path);
    const full_path = full_buf[0 .. full_prefix.len + path.len];

    if (!openNetPath(proc, full_path)) {
        proc.pending_op = .none;
        return EAGAIN;
    }

    process.scheduleNext();
}

/// setsockopt — stub, return success for all options.
pub fn linuxSetsockopt(_: u64, _: u64, _: u64, _: u64, _: u64) u64 {
    return 0;
}

/// getsockopt — return sensible defaults for common options.
pub fn linuxGetsockopt(_: u64, level: u64, optname: u64, optval: u64, optlen: u64) u64 {
    if (optval == 0 or optlen == 0) return 0;
    const val_ptr: *u32 = @ptrFromInt(optval);
    const len_ptr: *u32 = @ptrFromInt(optlen);

    if (level == SOL_SOCKET) {
        if (optname == SO_ERROR or optname == SO_REUSEADDR or
            optname == SO_KEEPALIVE or optname == SO_REUSEPORT)
        {
            val_ptr.* = 0;
            len_ptr.* = 4;
            return 0;
        }
        // SO_SNDBUF(7) / SO_RCVBUF(8): report kernel buffer sizes
        if (optname == 7 or optname == 8) {
            val_ptr.* = 65536;
            len_ptr.* = 4;
            return 0;
        }
    }
    if (level == IPPROTO_TCP) {
        if (optname == TCP_NODELAY) {
            val_ptr.* = 1; // we always send immediately
            len_ptr.* = 4;
            return 0;
        }
        // TCP_MAXSEG (2): report standard MSS
        if (optname == 2) {
            val_ptr.* = 1460;
            len_ptr.* = 4;
            return 0;
        }
    }
    // Unknown options: return success with zero value rather than error
    val_ptr.* = 0;
    len_ptr.* = 4;
    return 0;
}

/// shutdown(fd, how) → 0
pub fn linuxShutdown(fd: u64, _: u64) u64 {
    // Just close the data fd — the server handles TCP teardown
    return syscall.sysClose(fd);
}

/// getpeername(fd, addr, addrlen) → 0 or error
/// Returns stashed remote_ip/remote_port from SocketMeta.
pub fn linuxGetpeername(fd: u64, addr_ptr: u64, addr_len_ptr: u64) u64 {
    const proc = process.getCurrent() orelse return EFAULT;
    const meta = findMeta(proc.pid, @intCast(fd)) orelse return ENOTCONN;
    if (meta.remote_port == 0) return ENOTCONN;
    writeSockaddrIn(addr_ptr, addr_len_ptr, meta.remote_ip, meta.remote_port);
    return 0;
}

/// getsockname(fd, addr, addrlen) → 0 or error
/// Returns bound_port from SocketMeta + 0.0.0.0.
pub fn linuxGetsockname(fd: u64, addr_ptr: u64, addr_len_ptr: u64) u64 {
    const proc = process.getCurrent() orelse return EFAULT;
    const meta = findMeta(proc.pid, @intCast(fd)) orelse return EINVAL;
    writeSockaddrIn(addr_ptr, addr_len_ptr, .{ 0, 0, 0, 0 }, meta.bound_port);
    return 0;
}

/// sendto(fd, buf, len, flags, dest_addr, addrlen) → bytes_sent or error
/// After connect/accept, the socket fd IS a server-backed IPC fd,
/// so we delegate to sysWrite which handles T_WRITE for server-backed fds.
pub fn linuxSendto(fd: u64, buf_ptr: u64, len: u64, _: u64, _: u64) u64 {
    return syscall.sysWrite(fd, buf_ptr, len);
}

/// recvfrom(fd, buf, len, flags, src_addr, addrlen) → bytes_read or error
/// Delegates to sysRead which handles T_READ for server-backed fds.
pub fn linuxRecvfrom(fd: u64, buf_ptr: u64, len: u64, _: u64, _: u64) u64 {
    return syscall.sysRead(fd, buf_ptr, len);
}

/// close(fd) → 0 or error
/// Cleans up SocketMeta and closes the ctl fd, then delegates to sysClose for the data fd.
pub fn linuxClose(fd_arg: u64) u64 {
    const proc = process.getCurrent() orelse return EBADF;
    const fd: u32 = @intCast(fd_arg);

    if (findMeta(proc.pid, fd)) |meta| {
        // Close the ctl fd locally if we have one
        if (meta.ipc_ctl_fd > 0) {
            proc.closeFd(meta.ipc_ctl_fd);
        }
        freeMeta(proc.pid, fd);
    }

    // Close the data channel fd (sends T_CLOSE to netd if server-backed)
    return syscall.sysClose(fd_arg);
}

// ── Poll/Select — optimistic reporting ────────────────────────────────
// Without kernel TCP state access, socket fds report POLLIN|POLLOUT
// conservatively. The app's subsequent read/write discovers the actual state.

/// poll(fds, nfds, timeout_ms) → ready count or 0 (timeout)
pub fn linuxPoll(fds_ptr: u64, nfds: u64, timeout: u64) u64 {
    const proc = process.getCurrent() orelse return EFAULT;

    if (nfds == 0) return 0;
    if (nfds > 256) return EINVAL;

    const ready = pollScan(proc, fds_ptr, @intCast(nfds));
    if (ready > 0) return ready;

    // Non-blocking check (timeout == 0)
    const timeout_signed: i64 = @bitCast(timeout);
    if (timeout_signed == 0) return 0;

    // Calculate deadline in ticks
    const now = timer.getTicks();
    const deadline: u32 = if (timeout_signed < 0)
        now +% (30 * timer.TICKS_PER_SEC) // 30s for "infinite"
    else blk: {
        const ms: u64 = @intCast(timeout_signed);
        const t: u32 = @intCast(@min(ms * timer.TICKS_PER_SEC / 1000, 0x7FFF_FFFF));
        break :blk now +% @max(1, t);
    };

    // Stash state for resume handler: discriminator 0 = poll
    proc.ipc_recv_buf_ptr = fds_ptr;
    proc.pending_fd = @intCast(nfds);
    proc.linux_stat_buf = deadline;
    proc.linux_stat_fd = 0;
    proc.syscall_ret = 0;
    proc.sleep_until = now +% 1; // wake on next tick
    proc.pending_op = .poll_wait;
    proc.state = .blocked;
    process.scheduleNext();
}

/// select(nfds, readfds, writefds, exceptfds, timeout) → count or 0
pub fn linuxSelect(nfds: u64, readfds_ptr: u64, writefds_ptr: u64, _: u64, timeout_ptr: u64) u64 {
    const proc = process.getCurrent() orelse return EFAULT;

    const max_fd: usize = @intCast(@min(nfds, 1024));

    // Quick check without modifying fd_sets
    const ready = selectCheck(proc, max_fd, readfds_ptr, writefds_ptr);
    if (ready > 0) return selectScan(proc, max_fd, readfds_ptr, writefds_ptr);

    // Parse timeout: struct timeval { tv_sec: i64, tv_usec: i64 }
    const timeout_ms: i64 = if (timeout_ptr == 0)
        -1 // NULL = wait forever
    else blk: {
        const tv: [*]const u8 = @ptrFromInt(timeout_ptr);
        const sec = @as(i64, @bitCast(readLeU64(tv[0..8])));
        const usec = @as(i64, @bitCast(readLeU64(tv[8..16])));
        break :blk sec * 1000 + @divTrunc(usec, 1000);
    };

    if (timeout_ms == 0) return 0;

    // Calculate deadline
    const now = timer.getTicks();
    const is_infinite = timeout_ms < 0;
    const deadline: u32 = if (is_infinite)
        now +% (1 * timer.TICKS_PER_SEC) // 1s cap for "infinite" — enables IPC handshake
    else blk: {
        const ms: u64 = @intCast(timeout_ms);
        const t: u32 = @intCast(@min(ms * timer.TICKS_PER_SEC / 1000, 0x7FFF_FFFF));
        break :blk now +% @max(1, t);
    };

    // Stash state for resume handler
    // linux_stat_fd discriminator: 0=poll, 1=select(finite), 2=select(infinite/capped)
    proc.ipc_recv_buf_ptr = readfds_ptr;
    proc.syscall_ret = writefds_ptr;
    proc.pending_fd = @intCast(max_fd);
    proc.linux_stat_buf = deadline;
    proc.linux_stat_fd = if (is_infinite) 2 else 1;
    proc.sleep_until = now +% 1; // wake on next tick
    proc.pending_op = .poll_wait;
    proc.state = .blocked;
    process.scheduleNext();
}

// ── Poll/Select scan helpers ──────────────────────────────────────────

/// Scan pollfds and write revents. Returns count of ready fds.
/// For IPC-backed socket fds, optimistically report POLLIN|POLLOUT.
fn pollScan(proc: *process.Process, fds_ptr: u64, n: usize) u64 {
    const pipe_mod = @import("pipe.zig");
    const fds: [*]u8 = @ptrFromInt(fds_ptr);
    const POLLFD_SIZE: usize = 8;
    var ready_count: u64 = 0;

    for (0..n) |i| {
        const base = fds + i * POLLFD_SIZE;
        const poll_fd_raw: i32 = @bitCast(@as(u32, base[0]) | (@as(u32, base[1]) << 8) |
            (@as(u32, base[2]) << 16) | (@as(u32, base[3]) << 24));
        const events: i16 = @bitCast(@as(u16, base[4]) | (@as(u16, base[5]) << 8));

        base[6] = 0;
        base[7] = 0;
        if (poll_fd_raw < 0) continue;

        const poll_fd: u32 = @intCast(poll_fd_raw);
        var revents: i16 = 0;

        const entry = proc.getFdEntry(poll_fd);
        if (entry == null) {
            if (poll_fd <= 2) {
                // Console fds (stdin/stdout/stderr): writable, not readable
                if (poll_fd >= 1 and events & POLLOUT != 0) revents |= POLLOUT;
            } else {
                revents = POLLNVAL;
            }
        } else {
            const e = entry.?;
            if (events & POLLIN != 0) {
                const readable = switch (e.fd_type) {
                    .pipe => pipe_mod.hasDataOrEof(e.pipe_id),
                    .ipc => true, // Optimistic: read() handles blocking via R_AGAIN
                    else => true, // dev_* fds are always readable
                };
                if (readable) revents |= POLLIN;
            }
            if (events & POLLOUT != 0) revents |= POLLOUT;
        }

        if (revents != 0) {
            const rev_u16: u16 = @bitCast(revents);
            base[6] = @truncate(rev_u16);
            base[7] = @truncate(rev_u16 >> 8);
            ready_count += 1;
        }
    }
    return ready_count;
}

/// Read-only check: count ready fds in fd_sets without modifying them.
fn selectCheck(proc: *process.Process, max_fd: usize, readfds_ptr: u64, writefds_ptr: u64) u64 {
    const pipe_mod = @import("pipe.zig");
    var ready_count: u64 = 0;
    for (0..max_fd) |fd_i| {
        const fd: u32 = @intCast(fd_i);
        const word_idx = fd_i / 64;
        const bit_idx: u6 = @intCast(fd_i % 64);
        const bit_mask: u64 = @as(u64, 1) << bit_idx;

        const in_read = if (readfds_ptr != 0) fdSetTest(readfds_ptr, word_idx, bit_mask) else false;
        const in_write = if (writefds_ptr != 0) fdSetTest(writefds_ptr, word_idx, bit_mask) else false;
        if (!in_read and !in_write) continue;

        const entry = proc.getFdEntry(fd) orelse {
            // Console fds (0-2): stdout/stderr are writable
            if (fd <= 2 and fd >= 1 and in_write) {
                ready_count += 1;
            }
            continue;
        };

        var fd_ready = false;
        if (in_read) {
            fd_ready = fd_ready or switch (entry.fd_type) {
                .pipe => pipe_mod.hasDataOrEof(entry.pipe_id),
                .ipc => true, // Optimistic: read() handles blocking via R_AGAIN
                else => true, // dev_* fds are always readable
            };
        }
        if (in_write) {
            // Writes are always considered ready
            fd_ready = true;
        }
        if (fd_ready) ready_count += 1;
    }
    return ready_count;
}

/// Scan fd_sets, clear bits for non-ready fds, return count of ready fds.
fn selectScan(proc: *process.Process, max_fd: usize, readfds_ptr: u64, writefds_ptr: u64) u64 {
    const pipe_mod = @import("pipe.zig");
    var ready_count: u64 = 0;
    for (0..max_fd) |fd_i| {
        const fd: u32 = @intCast(fd_i);
        const word_idx = fd_i / 64;
        const bit_idx: u6 = @intCast(fd_i % 64);
        const bit_mask: u64 = @as(u64, 1) << bit_idx;

        const in_read = if (readfds_ptr != 0) fdSetTest(readfds_ptr, word_idx, bit_mask) else false;
        const in_write = if (writefds_ptr != 0) fdSetTest(writefds_ptr, word_idx, bit_mask) else false;
        if (!in_read and !in_write) continue;

        const entry = proc.getFdEntry(fd) orelse {
            // Console fds (0-2): stdout/stderr are writable, stdin not readable
            if (fd <= 2) {
                if (in_read) fdSetClear(readfds_ptr, word_idx, bit_mask);
                if (fd >= 1 and in_write) {
                    ready_count += 1;
                } else {
                    if (in_write) fdSetClear(writefds_ptr, word_idx, bit_mask);
                }
            } else {
                if (in_read) fdSetClear(readfds_ptr, word_idx, bit_mask);
                if (in_write) fdSetClear(writefds_ptr, word_idx, bit_mask);
            }
            continue;
        };

        var read_ready = false;
        var write_ready = false;

        if (in_read) {
            read_ready = switch (entry.fd_type) {
                .pipe => pipe_mod.hasDataOrEof(entry.pipe_id),
                .ipc => true, // Optimistic: read() handles blocking via R_AGAIN
                else => true, // dev_* fds are always readable
            };
            if (!read_ready) fdSetClear(readfds_ptr, word_idx, bit_mask);
        }
        if (in_write) {
            write_ready = true;
        }

        if (read_ready or write_ready) {
            ready_count += 1;
        } else {
            // Neither read nor write ready — clear both bits
            if (in_read) fdSetClear(readfds_ptr, word_idx, bit_mask);
            if (in_write) fdSetClear(writefds_ptr, word_idx, bit_mask);
        }
    }
    return ready_count;
}

/// Like selectScan but treats ALL fds as optimistically ready (including IPC reads).
/// Used when infinite-timeout select expires — enables handshake/result reads.
fn selectScanOptimistic(proc: *process.Process, max_fd: usize, readfds_ptr: u64, writefds_ptr: u64) u64 {
    var ready_count: u64 = 0;
    for (0..max_fd) |fd_i| {
        const fd: u32 = @intCast(fd_i);
        const word_idx = fd_i / 64;
        const bit_idx: u6 = @intCast(fd_i % 64);
        const bit_mask: u64 = @as(u64, 1) << bit_idx;

        const in_read = if (readfds_ptr != 0) fdSetTest(readfds_ptr, word_idx, bit_mask) else false;
        const in_write = if (writefds_ptr != 0) fdSetTest(writefds_ptr, word_idx, bit_mask) else false;
        if (!in_read and !in_write) continue;

        _ = proc.getFdEntry(fd) orelse {
            // Console fds (0-2): stdout/stderr are writable
            if (fd <= 2 and fd >= 1 and in_write) {
                if (in_read) fdSetClear(readfds_ptr, word_idx, bit_mask);
                ready_count += 1;
            } else {
                if (in_read) fdSetClear(readfds_ptr, word_idx, bit_mask);
                if (in_write) fdSetClear(writefds_ptr, word_idx, bit_mask);
            }
            continue;
        };

        // All fds optimistically ready
        if (in_read or in_write) ready_count += 1;
    }
    return ready_count;
}

/// Resume handler for poll_wait. Called from process.zig when woken by timer.
/// Returns true if done (syscall_ret set), false if should re-block.
pub fn handlePollResume(proc: *process.Process) bool {
    const now = timer.getTicks();
    const deadline: u32 = @truncate(proc.linux_stat_buf);

    if (proc.linux_stat_fd == 0) {
        // Poll: re-scan pollfds
        const ready = pollScan(proc, proc.ipc_recv_buf_ptr, proc.pending_fd);
        if (ready > 0) {
            proc.syscall_ret = ready;
            return true;
        }
    } else {
        // Select: read-only check first
        const readfds = proc.ipc_recv_buf_ptr;
        const writefds = proc.syscall_ret;
        const nfds: usize = proc.pending_fd;
        const ready = selectCheck(proc, nfds, readfds, writefds);
        if (ready > 0) {
            // Modify fd_sets and return count
            proc.syscall_ret = selectScan(proc, nfds, readfds, writefds);
            return true;
        }
    }

    // Check if deadline has passed (wrapping comparison)
    if ((now -% deadline) < 0x8000_0000) {
        if (proc.linux_stat_fd == 2) {
            // Infinite-timeout select: deadline passed → report IPC reads as
            // optimistically ready. This enables handshake reads where data
            // is already available but can't be detected via IPC peek.
            const readfds = proc.ipc_recv_buf_ptr;
            const writefds = proc.syscall_ret;
            const nfds: usize = proc.pending_fd;
            // Do a scan that treats ALL fds as ready (original optimistic behavior)
            proc.syscall_ret = selectScanOptimistic(proc, nfds, readfds, writefds);
            return true;
        }
        // Finite-timeout select or poll: return 0 (timeout) — lets timers fire
        if (proc.linux_stat_fd == 1) {
            // Select: clear all fd_set bits (nothing ready)
            _ = selectScan(proc, proc.pending_fd, proc.ipc_recv_buf_ptr, proc.syscall_ret);
        }
        proc.syscall_ret = 0;
        return true;
    }

    // Not ready and not timed out — schedule another check
    proc.sleep_until = now +% 1;
    return false;
}

/// nanosleep(req, rem) → 0 or error
pub fn linuxNanosleep(req_ptr: u64, _: u64) u64 {
    if (req_ptr == 0) return EFAULT;

    const ts: [*]const u8 = @ptrFromInt(req_ptr);
    const sec = readLeU64(ts[0..8]);
    const nsec = readLeU64(ts[8..16]);

    const ms: u64 = sec * 1000 + nsec / 1_000_000;
    if (ms == 0) return 0;

    return syscall.sysSleep(ms);
}

// ── Multi-step IPC state machine resume handler ───────────────────────

/// Called from sysIpcReply when a reply arrives for a process with pending_op = .linux_sock_step.
/// Advances the state machine for connect/listen/accept.
/// Returns true if the process should remain blocked (more steps), false if done.
pub fn handleResume(
    client_proc: *process.Process,
    is_ok: bool,
    reply_data_ptr: [*]const u8,
    reply_data_len: u32,
) bool {
    const op = stashOp(client_proc);
    const step = stashStep(client_proc);
    const mi = stashMetaIdx(client_proc);
    const meta = getMeta(mi);

    return switch (op) {
        OP_CONNECT => resumeConnect(client_proc, meta, step, is_ok, reply_data_ptr, reply_data_len),
        OP_LISTEN => resumeListen(client_proc, meta, step, is_ok, reply_data_ptr, reply_data_len),
        OP_ACCEPT => resumeAccept(client_proc, meta, step, is_ok, reply_data_ptr, reply_data_len),
        else => {
            client_proc.syscall_ret = EIO;
            return false;
        },
    };
}

// ── Connect state machine (5 steps: 0-4) ─────────────────────────────

fn resumeConnect(
    proc: *process.Process,
    meta: *SocketMeta,
    step: u32,
    is_ok: bool,
    reply_data_ptr: [*]const u8,
    reply_data_len: u32,
) bool {
    switch (step) {
        0 => {
            // Reply from clone T_OPEN: save server_handle, then T_READ clone
            if (!is_ok or reply_data_len < 4) {
                failConnect(proc);
                return false;
            }
            const handle = readU32LE(reply_data_ptr[0..4]);
            if (proc.getFdEntryPtr(proc.pending_fd)) |fd_entry| {
                fd_entry.server_handle = handle;
            }
            // Step 1: T_READ the clone fd to get connection number
            proc.linux_stat_fd = 1;
            if (!sendRead(proc)) {
                failConnect(proc);
                return false;
            }
            return true;
        },
        1 => {
            // Reply from clone T_READ: parse conn number N, close clone, open /net/tcp/N/ctl
            if (!is_ok or reply_data_len == 0) {
                failCloneAndConnect(proc);
                return false;
            }
            const conn_num = parseDecimal(reply_data_ptr[0..reply_data_len]) orelse {
                failCloneAndConnect(proc);
                return false;
            };
            meta.conn_num = conn_num;

            // Close clone fd locally
            proc.closeFd(proc.pending_fd);

            // Step 2: Open /net/tcp/N/ctl
            proc.linux_stat_fd = 2;
            var path_buf: [64]u8 = undefined;
            const sub = fmtConnPath(&path_buf, conn_num, "/ctl");
            var full_buf: [80]u8 = undefined;
            const fp = "/net/";
            @memcpy(full_buf[0..fp.len], fp);
            @memcpy(full_buf[fp.len..][0..sub.len], sub);

            if (!openNetPath(proc, full_buf[0 .. fp.len + sub.len])) {
                proc.syscall_ret = ECONNREFUSED;
                proc.pending_op = .none;
                return false;
            }
            return true;
        },
        2 => {
            // Reply from ctl T_OPEN: save handle, store ctl fd, write "connect ip!port"
            if (!is_ok or reply_data_len < 4) {
                failConnect(proc);
                return false;
            }
            const handle = readU32LE(reply_data_ptr[0..4]);
            if (proc.getFdEntryPtr(proc.pending_fd)) |fd_entry| {
                fd_entry.server_handle = handle;
            }
            meta.ipc_ctl_fd = @intCast(proc.pending_fd);

            // Step 3: T_WRITE "connect ip!port\n" to ctl
            proc.linux_stat_fd = 3;
            var cmd_buf: [64]u8 = undefined;
            const cmd = fmtConnectCmd(&cmd_buf, meta.remote_ip, meta.remote_port);
            if (!sendWrite(proc, cmd)) {
                failConnect(proc);
                return false;
            }
            return true;
        },
        3 => {
            // Reply from ctl T_WRITE: connect acknowledged, open /net/tcp/N/data
            if (!is_ok) {
                failConnect(proc);
                return false;
            }

            // Step 4: Open /net/tcp/N/data
            proc.linux_stat_fd = 4;
            var path_buf: [64]u8 = undefined;
            const sub = fmtConnPath(&path_buf, meta.conn_num, "/data");
            var full_buf: [80]u8 = undefined;
            const fp = "/net/";
            @memcpy(full_buf[0..fp.len], fp);
            @memcpy(full_buf[fp.len..][0..sub.len], sub);

            if (!openNetPath(proc, full_buf[0 .. fp.len + sub.len])) {
                failConnect(proc);
                return false;
            }
            return true;
        },
        4 => {
            // Reply from data T_OPEN: copy channel_id + server_handle to original socket fd
            if (!is_ok or reply_data_len < 4) {
                failConnect(proc);
                return false;
            }
            const handle = readU32LE(reply_data_ptr[0..4]);
            const data_fd = proc.pending_fd;

            // Get channel_id from the data fd we just opened
            const data_entry = proc.getFdEntry(data_fd) orelse {
                failConnect(proc);
                return false;
            };
            const data_channel = data_entry.channel_id;

            // Copy channel_id + server_handle to the original socket fd
            if (proc.getFdEntryPtr(meta.sock_fd)) |sock_entry| {
                sock_entry.channel_id = data_channel;
                sock_entry.server_handle = handle;
            }

            // Free the temp data fd (don't send T_CLOSE — we're transferring ownership)
            proc.closeFd(data_fd);

            proc.syscall_ret = 0;
            proc.pending_op = .none;
            return false;
        },
        else => {
            failConnect(proc);
            return false;
        },
    }
}

fn failConnect(proc: *process.Process) void {
    klog.err("[sock] connect FAIL for pid=");
    klog.errDec(proc.pid);
    klog.err(" step=");
    klog.errDec(stashStep(proc));
    klog.err("\n");
    proc.syscall_ret = ECONNREFUSED;
    proc.pending_op = .none;
}

fn failCloneAndConnect(proc: *process.Process) void {
    proc.closeFd(proc.pending_fd);
    proc.syscall_ret = ECONNREFUSED;
    proc.pending_op = .none;
}

// ── Listen state machine (4 steps: 0-3) ──────────────────────────────

fn resumeListen(
    proc: *process.Process,
    meta: *SocketMeta,
    step: u32,
    is_ok: bool,
    reply_data_ptr: [*]const u8,
    reply_data_len: u32,
) bool {
    switch (step) {
        0 => {
            // Reply from clone T_OPEN: save handle, T_READ clone
            if (!is_ok or reply_data_len < 4) {
                failListen(proc);
                return false;
            }
            const handle = readU32LE(reply_data_ptr[0..4]);
            if (proc.getFdEntryPtr(proc.pending_fd)) |fd_entry| {
                fd_entry.server_handle = handle;
            }
            proc.linux_stat_fd = 1;
            if (!sendRead(proc)) {
                failListen(proc);
                return false;
            }
            return true;
        },
        1 => {
            // Reply from clone T_READ: parse N, close clone, open /net/tcp/N/ctl
            if (!is_ok or reply_data_len == 0) {
                proc.closeFd(proc.pending_fd);
                failListen(proc);
                return false;
            }
            const conn_num = parseDecimal(reply_data_ptr[0..reply_data_len]) orelse {
                proc.closeFd(proc.pending_fd);
                failListen(proc);
                return false;
            };
            meta.conn_num = conn_num;
            proc.closeFd(proc.pending_fd);

            proc.linux_stat_fd = 2;
            var path_buf: [64]u8 = undefined;
            const sub = fmtConnPath(&path_buf, conn_num, "/ctl");
            var full_buf: [80]u8 = undefined;
            const fp = "/net/";
            @memcpy(full_buf[0..fp.len], fp);
            @memcpy(full_buf[fp.len..][0..sub.len], sub);

            if (!openNetPath(proc, full_buf[0 .. fp.len + sub.len])) {
                failListen(proc);
                return false;
            }
            return true;
        },
        2 => {
            // Reply from ctl T_OPEN: save handle, write "announce port"
            if (!is_ok or reply_data_len < 4) {
                failListen(proc);
                return false;
            }
            const handle = readU32LE(reply_data_ptr[0..4]);
            if (proc.getFdEntryPtr(proc.pending_fd)) |fd_entry| {
                fd_entry.server_handle = handle;
            }
            meta.ipc_ctl_fd = @intCast(proc.pending_fd);

            proc.linux_stat_fd = 3;
            var cmd_buf: [64]u8 = undefined;
            const cmd = fmtAnnounceCmd(&cmd_buf, meta.bound_port);
            if (!sendWrite(proc, cmd)) {
                failListen(proc);
                return false;
            }
            return true;
        },
        3 => {
            // Reply from ctl T_WRITE: announce done
            if (!is_ok) {
                failListen(proc);
                return false;
            }
            meta.listening = true;
            proc.syscall_ret = 0;
            proc.pending_op = .none;
            return false;
        },
        else => {
            failListen(proc);
            return false;
        },
    }
}

fn failListen(proc: *process.Process) void {
    proc.syscall_ret = EINVAL;
    proc.pending_op = .none;
}

// ── Accept state machine (3 steps: 0-2) ──────────────────────────────

fn resumeAccept(
    proc: *process.Process,
    meta: *SocketMeta,
    step: u32,
    is_ok: bool,
    reply_data_ptr: [*]const u8,
    reply_data_len: u32,
) bool {
    switch (step) {
        0 => {
            // Reply from listen T_OPEN: save handle, T_READ (blocks until connection)
            if (!is_ok or reply_data_len < 4) {
                failAccept(proc);
                return false;
            }
            const handle = readU32LE(reply_data_ptr[0..4]);
            if (proc.getFdEntryPtr(proc.pending_fd)) |fd_entry| {
                fd_entry.server_handle = handle;
            }
            proc.linux_stat_fd = 1;
            if (!sendRead(proc)) {
                failAccept(proc);
                return false;
            }
            return true;
        },
        1 => {
            // Reply from listen T_READ: parse child conn number, close listen fd, open child/data
            if (!is_ok or reply_data_len == 0) {
                proc.closeFd(proc.pending_fd);
                failAccept(proc);
                return false;
            }
            const child_num = parseDecimal(reply_data_ptr[0..reply_data_len]) orelse {
                proc.closeFd(proc.pending_fd);
                failAccept(proc);
                return false;
            };
            proc.closeFd(proc.pending_fd);

            proc.linux_stat_fd = 2;
            var path_buf: [64]u8 = undefined;
            const sub = fmtConnPath(&path_buf, child_num, "/data");
            var full_buf: [80]u8 = undefined;
            const fp = "/net/";
            @memcpy(full_buf[0..fp.len], fp);
            @memcpy(full_buf[fp.len..][0..sub.len], sub);

            if (!openNetPath(proc, full_buf[0 .. fp.len + sub.len])) {
                failAccept(proc);
                return false;
            }
            return true;
        },
        2 => {
            // Reply from child data T_OPEN: allocate new fd for the accepted connection
            if (!is_ok or reply_data_len < 4) {
                failAccept(proc);
                return false;
            }
            const handle = readU32LE(reply_data_ptr[0..4]);
            const data_fd = proc.pending_fd;

            // Get channel from the data fd
            const data_entry = proc.getFdEntry(data_fd) orelse {
                failAccept(proc);
                return false;
            };
            const data_channel = data_entry.channel_id;

            // Allocate a new fd for the accepted connection
            const new_fd = proc.allocFd(data_channel, false) orelse {
                proc.closeFd(data_fd);
                proc.syscall_ret = EMFILE;
                proc.pending_op = .none;
                return false;
            };

            // Set up the new fd with the server handle
            if (proc.getFdEntryPtr(new_fd)) |new_entry| {
                new_entry.server_handle = handle;
            }

            // Free the temp data fd (ownership transferred to new_fd)
            proc.closeFd(data_fd);

            // Create SocketMeta for the new fd
            if (allocMeta(proc.pid, new_fd)) |new_meta| {
                new_meta.conn_num = 0; // not tracked for accepted connections
                // We don't know the remote info from the accept path,
                // but the parent meta has the listening port
                new_meta.bound_port = meta.bound_port;
            }

            // Write peer address if requested
            const addr_ptr = proc.ipc_recv_buf_ptr;
            const addr_len_ptr = proc.syscall_ret;
            _ = addr_len_ptr;
            // We don't have remote info from the Plan 9 accept path,
            // write zeros — getpeername can be used separately if needed
            if (addr_ptr != 0) {
                writeSockaddrIn(addr_ptr, 0, .{ 0, 0, 0, 0 }, 0);
            }

            proc.syscall_ret = new_fd;
            proc.pending_op = .none;
            return false;
        },
        else => {
            failAccept(proc);
            return false;
        },
    }
}

fn failAccept(proc: *process.Process) void {
    proc.syscall_ret = EAGAIN;
    proc.pending_op = .none;
}

// ── fd_set helpers for select() ────────────────────────────────────────

fn fdSetTest(set_ptr: u64, word_idx: usize, bit_mask: u64) bool {
    const words: [*]u64 = @ptrFromInt(set_ptr);
    return (words[word_idx] & bit_mask) != 0;
}

fn fdSetClear(set_ptr: u64, word_idx: usize, bit_mask: u64) void {
    const words: [*]u64 = @ptrFromInt(set_ptr);
    words[word_idx] &= ~bit_mask;
}

fn readLeU64(buf: *const [8]u8) u64 {
    return @as(u64, buf[0]) |
        (@as(u64, buf[1]) << 8) |
        (@as(u64, buf[2]) << 16) |
        (@as(u64, buf[3]) << 24) |
        (@as(u64, buf[4]) << 32) |
        (@as(u64, buf[5]) << 40) |
        (@as(u64, buf[6]) << 48) |
        (@as(u64, buf[7]) << 56);
}
