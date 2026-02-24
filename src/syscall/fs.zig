/// Filesystem syscall handlers: open, create, read, write, pread, pwrite,
/// close, pipe, seek, stat, remove, rename, truncate, wstat.
const process = @import("../process.zig");
const ipc = @import("../ipc.zig");
const console = @import("../console.zig");
const mem = @import("../mem.zig");
const klog = @import("../klog.zig");
const devfiles = @import("../devfiles.zig");
const namespace = @import("../namespace.zig");
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
const readU32LE = root.readU32LE;
const sendToServer = root.sendToServer;
const strEql = root.strEql;
const hasNetMount = root.hasNetMount;

/// write(fd, buf, count) → bytes_written
/// fd 1/2 → direct framebuffer console + serial (bootstrap path).
/// Other fds → IPC to file server via channel.
pub fn sysWrite(fd: u64, buf_ptr: u64, count: u64) u64 {
    const pipe_mod = @import("../pipe.zig");
    const ns = @import("ns.zig");

    // For fd 0/1/2, check if process has an explicit FdEntry override.
    // If not, use the default console/keyboard path.
    if (fd <= 2) {
        const proc = process.getCurrent() orelse return EBADF;
        if (fd == 0 and proc.getFdEntry(0) == null) {
            // Default: keyboard control (Plan 9 style: write to fd 0)
            const keyboard = @import("../keyboard.zig");
            if (buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
            if (count == 0) return 0;
            const buf: [*]const u8 = @ptrFromInt(buf_ptr);
            const len: usize = @intCast(@min(count, 64));
            keyboard.handleCtl(proc.vt, buf[0..len]);
            return len;
        }
        if ((fd == 1 or fd == 2) and proc.getFdEntry(@intCast(fd)) == null) {
            // Default: direct framebuffer console + serial (routed to process's VT)
            if (buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
            if (count == 0) return 0;
            const buf: [*]const u8 = @ptrFromInt(buf_ptr);
            const len: usize = @intCast(@min(count, 4096));
            console.putsVt(proc.vt, buf[0..len]);
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
        const net = @import("../net.zig");
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

    // Proc fd: write "kill" to /proc/N/ctl
    if (entry.fd_type == .proc) {
        return devfiles.procWrite(entry, buf_ptr, count);
    }

    // Container fd: write to /cntr/N/ctl
    if (entry.fd_type == .cntr) {
        return devfiles.cntrWrite(entry, buf_ptr, count);
    }

    // Virtual device fds: discard writes, return count
    if (entry.fd_type == .dev_null or entry.fd_type == .dev_zero or entry.fd_type == .dev_random) {
        return @min(count, 4096);
    }

    // /dev/sysname: write sets the hostname
    if (entry.fd_type == .dev_sysname) {
        return devfiles.sysnameWrite(buf_ptr, count);
    }

    // /dev/reboot: "reboot" or "halt" (root only)
    if (entry.fd_type == .dev_reboot) {
        const caller = process.getCurrent() orelse return EBADF;
        if (caller.uid != 0) return EBADF; // permission denied
        const src: [*]const u8 = @ptrFromInt(buf_ptr);
        const len: usize = @intCast(@min(count, 64));
        var cmd_len = len;
        while (cmd_len > 0 and (src[cmd_len - 1] == '\n' or src[cmd_len - 1] == ' ')) {
            cmd_len -= 1;
        }
        if (cmd_len == 6 and src[0] == 'r' and src[1] == 'e' and src[2] == 'b' and
            src[3] == 'o' and src[4] == 'o' and src[5] == 't')
        {
            ns.sysShutdown(1); // reboot
        }
        if (cmd_len == 4 and src[0] == 'h' and src[1] == 'a' and src[2] == 'l' and src[3] == 't') {
            ns.sysShutdown(0); // halt
        }
        return EINVAL;
    }

    // /dev/consctl: rawon/rawoff/echo on/echo off/size
    if (entry.fd_type == .dev_consctl) {
        const keyboard = @import("../keyboard.zig");
        const caller = process.getCurrent() orelse return EBADF;
        const src: [*]const u8 = @ptrFromInt(buf_ptr);
        const len: usize = @intCast(@min(count, 64));
        keyboard.handleCtl(caller.vt, src[0..len]);
        return len;
    }

    // /dev/time: write epoch seconds to adjust clock (root only)
    if (entry.fd_type == .dev_time) {
        const caller = process.getCurrent() orelse return EBADF;
        if (caller.uid != 0) return EBADF; // permission denied
        const src: [*]const u8 = @ptrFromInt(buf_ptr);
        const len: usize = @intCast(@min(count, 64));
        // Strip trailing whitespace
        var end = len;
        while (end > 0 and (src[end - 1] == '\n' or src[end - 1] == ' ')) {
            end -= 1;
        }
        if (end == 0) return EINVAL;
        const time_mod = @import("../time.zig");
        const new_epoch = devfiles.parseDecimal(src[0..end]) orelse return EINVAL;
        const current = time_mod.wallClock();
        const delta: i64 = @as(i64, @intCast(new_epoch)) - @as(i64, @intCast(current));
        time_mod.setOffset(delta);
        return len;
    }

    // Read-only /dev/ files: reject writes
    if (entry.fd_type == .dev_osversion or
        entry.fd_type == .dev_kmesg or entry.fd_type == .dev_drivers or
        entry.fd_type == .dev_pid or entry.fd_type == .dev_user or
        entry.fd_type == .dev_sysstat or
        entry.fd_type == .dev_trace)
    {
        return EBADF;
    }

    // Raw Ethernet write: ctl commands or send frame via virtio-net
    if (entry.fd_type == .dev_ether) {
        const ether_mod = @import("../ether.zig");
        const src: [*]const u8 = @ptrFromInt(buf_ptr);
        const len: usize = @intCast(@min(count, 1518));
        // Check for ctl commands (short text strings)
        if (len <= 12) {
            var cmd_len = len;
            while (cmd_len > 0 and (src[cmd_len - 1] == '\n' or src[cmd_len - 1] == ' ')) {
                cmd_len -= 1;
            }
            if (cmd_len > 0 and ether_mod.handleCtl(entry.ether_client, src[0..cmd_len])) {
                return len;
            }
        }
        // Not a ctl command — send as raw Ethernet frame
        const virtio_net = @import("../virtio_net.zig");
        _ = virtio_net.send(src[0..len]);
        return len;
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

        proc.state = .blocked;
        sendToServer(chan, proc);
        process.scheduleNext();
    }

    // Raw IPC write (existing behavior for non-server-backed channels)
    const len: u32 = @intCast(@min(count, ipc.MAX_MSG_DATA));

    proc.ipc_msg = ipc.Message.init(.t_write);
    @memcpy(proc.ipc_msg.data_buf[0..len], buf[0..len]);
    proc.ipc_msg.data_len = len;

    proc.pending_op = .none;
    proc.state = .blocked;
    sendToServer(chan, proc);
    process.scheduleNext();
}

/// open(path_ptr, path_len) → fd
/// Resolves path in the process's namespace. For kernel-backed channels (initrd),
/// allocates fd directly. For server channels, sends T_OPEN and blocks for reply.
/// Paths starting with /net/ are intercepted for kernel TCP/DNS.
pub fn sysOpen(path_ptr: u64, path_len: u64) u64 {
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
        const blk_dev = @import("../blk.zig");
        if (!blk_dev.isInitialized()) return ENOENT;
        return proc.allocBlkFd() orelse return EMFILE;
    }

    // Intercept /dev/null, /dev/zero, /dev/random, /dev/pci, /dev/usb, /dev/mouse
    if (path_len >= 8 and path_slice[0] == '/' and path_slice[1] == 'd' and
        path_slice[2] == 'e' and path_slice[3] == 'v' and path_slice[4] == '/')
    {
        if (strEql(path_slice, "/dev/null")) {
            return proc.allocDevFd(.dev_null) orelse return EMFILE;
        }
        if (strEql(path_slice, "/dev/zero")) {
            return proc.allocDevFd(.dev_zero) orelse return EMFILE;
        }
        if (strEql(path_slice, "/dev/random")) {
            return proc.allocDevFd(.dev_random) orelse return EMFILE;
        }
        if (strEql(path_slice, "/dev/pci")) {
            return proc.allocDevFd(.dev_pci) orelse return EMFILE;
        }
        if (strEql(path_slice, "/dev/usb")) {
            return proc.allocDevFd(.dev_usb) orelse return EMFILE;
        }
        if (strEql(path_slice, "/dev/mouse")) {
            return proc.allocDevFd(.dev_mouse) orelse return EMFILE;
        }
        if (strEql(path_slice, "/dev/cpu")) {
            return proc.allocDevFd(.dev_cpu) orelse return EMFILE;
        }
        if (strEql(path_slice, "/dev/ether0")) {
            const ether_mod = @import("../ether.zig");
            const client_idx = ether_mod.allocClient() orelse return EMFILE;
            const fd_num = proc.allocDevFd(.dev_ether) orelse {
                ether_mod.freeClient(client_idx);
                return EMFILE;
            };
            if (proc.getFdEntryPtr(fd_num)) |entry| {
                entry.ether_client = client_idx;
            }
            return fd_num;
        }
        if (strEql(path_slice, "/dev/sysname")) {
            return proc.allocDevFd(.dev_sysname) orelse return EMFILE;
        }
        if (strEql(path_slice, "/dev/osversion")) {
            return proc.allocDevFd(.dev_osversion) orelse return EMFILE;
        }
        if (strEql(path_slice, "/dev/time")) {
            return proc.allocDevFd(.dev_time) orelse return EMFILE;
        }
        if (strEql(path_slice, "/dev/kmesg")) {
            return proc.allocDevFd(.dev_kmesg) orelse return EMFILE;
        }
        if (strEql(path_slice, "/dev/reboot")) {
            // Container processes cannot reboot the host
            if (proc.container_id != 0xFF) return @bitCast(@as(i64, -1));
            return proc.allocDevFd(.dev_reboot) orelse return EMFILE;
        }
        if (strEql(path_slice, "/dev/drivers")) {
            return proc.allocDevFd(.dev_drivers) orelse return EMFILE;
        }
        if (strEql(path_slice, "/dev/pid")) {
            return proc.allocDevFd(.dev_pid) orelse return EMFILE;
        }
        if (strEql(path_slice, "/dev/user")) {
            return proc.allocDevFd(.dev_user) orelse return EMFILE;
        }
        if (strEql(path_slice, "/dev/consctl")) {
            return proc.allocDevFd(.dev_consctl) orelse return EMFILE;
        }
        if (strEql(path_slice, "/dev/sysstat")) {
            return proc.allocDevFd(.dev_sysstat) orelse return EMFILE;
        }
        if (strEql(path_slice, "/dev/trace")) {
            return proc.allocDevFd(.dev_trace) orelse return EMFILE;
        }
    }

    // Intercept /net/* paths for kernel TCP/DNS — only when no userspace netd is mounted.
    // When netd is mounted at /net/, namespace resolution (below) handles it instead.
    if (path_len > 5 and path_slice[0] == '/' and path_slice[1] == 'n' and
        path_slice[2] == 'e' and path_slice[3] == 't' and path_slice[4] == '/' and
        !hasNetMount(proc.getNs()))
    {
        const net = @import("../net.zig");
        const netfs = net.netfs;

        const result = netfs.netOpen(path_slice[5..]) orelse return ENOENT;
        const fd_val = proc.allocNetFd(result.kind, result.conn) orelse return EMFILE;

        // For tcp/N/listen, block until a connection arrives
        if (result.kind == .tcp_listen) {
            const tcp = net.tcp;
            tcp.setListenWaiter(result.conn, @intCast(proc.pid));
            proc.pending_op = .net_listen;
            proc.pending_fd = fd_val;
            proc.syscall_ret = fd_val;
            proc.state = .blocked;
            process.scheduleNext();
        }

        return fd_val;
    }

    // Intercept /cntr/* paths for container management
    if (path_len >= 5 and path_slice[0] == '/' and path_slice[1] == 'c' and
        path_slice[2] == 'n' and path_slice[3] == 't' and path_slice[4] == 'r')
    {
        const container = @import("../container.zig");

        // "/cntr" or "/cntr/" — directory listing
        if (path_len == 5 or (path_len == 6 and path_slice[5] == '/')) {
            return proc.allocCntrFd(.dir, 0) orelse return EMFILE;
        }

        if (path_slice[5] != '/') return ENOENT;
        const cntr_suffix = path_slice[6..];

        // "/cntr/clone" — allocate new container
        if (cntr_suffix.len == 5 and cntr_suffix[0] == 'c' and cntr_suffix[1] == 'l' and
            cntr_suffix[2] == 'o' and cntr_suffix[3] == 'n' and cntr_suffix[4] == 'e')
        {
            return proc.allocCntrFd(.clone, 0) orelse return EMFILE;
        }

        // Parse container ID: digits until '/' or end
        var cntr_id: u32 = 0;
        var ci: usize = 0;
        while (ci < cntr_suffix.len and cntr_suffix[ci] >= '0' and cntr_suffix[ci] <= '9') : (ci += 1) {
            cntr_id = cntr_id * 10 + (cntr_suffix[ci] - '0');
        }
        if (ci == 0 or cntr_id >= container.MAX_CONTAINERS) return ENOENT;

        // Verify container exists
        if (container.getById(@intCast(cntr_id)) == null) return ENOENT;

        // "/cntr/N" — per-container directory
        if (ci == cntr_suffix.len) {
            return proc.allocCntrFd(.status, @intCast(cntr_id)) orelse return EMFILE;
        }

        if (cntr_suffix[ci] != '/') return ENOENT;
        const file = cntr_suffix[ci + 1 ..];

        // "/cntr/N/status"
        if (file.len == 6 and file[0] == 's' and file[1] == 't' and
            file[2] == 'a' and file[3] == 't' and file[4] == 'u' and file[5] == 's')
        {
            return proc.allocCntrFd(.status, @intCast(cntr_id)) orelse return EMFILE;
        }

        // "/cntr/N/ctl"
        if (file.len == 3 and file[0] == 'c' and file[1] == 't' and file[2] == 'l') {
            return proc.allocCntrFd(.ctl, @intCast(cntr_id)) orelse return EMFILE;
        }

        // "/cntr/N/procs"
        if (file.len == 5 and file[0] == 'p' and file[1] == 'r' and
            file[2] == 'o' and file[3] == 'c' and file[4] == 's')
        {
            return proc.allocCntrFd(.procs, @intCast(cntr_id)) orelse return EMFILE;
        }

        return ENOENT;
    }

    // Intercept /proc/* paths for kernel process info
    if (path_len >= 5 and path_slice[0] == '/' and path_slice[1] == 'p' and
        path_slice[2] == 'r' and path_slice[3] == 'o' and path_slice[4] == 'c')
    {
        // "/proc" — directory listing of PIDs
        if (path_len == 5) {
            return proc.allocProcFd(.dir, 0) orelse return EMFILE;
        }

        // Must have "/" after "/proc"
        if (path_slice[5] != '/') return ENOENT;

        const suffix = path_slice[6..];

        // "/proc/meminfo"
        if (suffix.len == 7 and suffix[0] == 'm' and suffix[1] == 'e' and
            suffix[2] == 'm' and suffix[3] == 'i' and suffix[4] == 'n' and
            suffix[5] == 'f' and suffix[6] == 'o')
        {
            return proc.allocProcFd(.meminfo, 0) orelse return EMFILE;
        }

        // Parse PID: digits until '/' or end
        var pid: u32 = 0;
        var i: usize = 0;
        while (i < suffix.len and suffix[i] >= '0' and suffix[i] <= '9') : (i += 1) {
            pid = pid * 10 + (suffix[i] - '0');
        }
        if (i == 0) return ENOENT;

        // Verify PID exists
        if (process.getByPid(pid) == null) return ENOENT;

        // "/proc/N" — per-pid directory
        if (i == suffix.len) {
            return proc.allocProcFd(.pid_dir, pid) orelse return EMFILE;
        }

        // Must have "/" after PID
        if (suffix[i] != '/') return ENOENT;
        const file = suffix[i + 1 ..];

        // "/proc/N/status"
        if (file.len == 6 and file[0] == 's' and file[1] == 't' and
            file[2] == 'a' and file[3] == 't' and file[4] == 'u' and file[5] == 's')
        {
            return proc.allocProcFd(.status, pid) orelse return EMFILE;
        }

        // "/proc/N/ctl"
        if (file.len == 3 and file[0] == 'c' and file[1] == 't' and file[2] == 'l') {
            return proc.allocProcFd(.ctl, pid) orelse return EMFILE;
        }

        return ENOENT;
    }

    const resolved = proc.getNs().resolve(path_slice) orelse return ENOENT;

    const chan = ipc.getChannel(resolved.channel_id) orelse return ENOENT;

    // Kernel-backed channel (initrd): just allocate fd, no IPC needed
    if (chan.kernel_data != null) {
        return proc.allocFd(resolved.channel_id, false) orelse return EMFILE;
    }

    // Server channel: send T_OPEN with path suffix
    const fd_val = proc.allocFd(resolved.channel_id, false) orelse return EMFILE;

    // Linux compat: if linux_stat_buf is set, this open is phase 1 of a path stat
    proc.pending_op = if (proc.linux_stat_buf != 0) .linux_stat_open else .open;
    proc.pending_fd = fd_val;

    // Build T_OPEN: data = [prefix][suffix]
    proc.ipc_msg = ipc.Message.init(.t_open);
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

    // Pre-set return value (overridden on error in reply handler)
    proc.syscall_ret = fd_val;

    proc.state = .blocked;
    sendToServer(chan, proc);
    process.scheduleNext();
}

/// create(path_ptr, path_len, flags) → fd
/// Like open but creates the file if it doesn't exist.
/// flags bit 0 = directory.
pub fn sysCreate(path_ptr: u64, path_len: u64, flags: u64) u64 {
    const proc = process.getCurrent() orelse return ENOSYS;
    if (path_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    if (path_len == 0 or path_len > 256) return ENOENT;

    const path: [*]const u8 = @ptrFromInt(path_ptr);
    const resolved = proc.getNs().resolve(path[0..@intCast(path_len)]) orelse return ENOENT;

    const chan = ipc.getChannel(resolved.channel_id) orelse return ENOENT;

    // Can't create on kernel-backed channels
    if (chan.kernel_data != null) return ENOSYS;

    const fd_val = proc.allocFd(resolved.channel_id, false) orelse return EMFILE;

    proc.pending_op = .create;
    proc.pending_fd = fd_val;

    // Build T_CREATE: [flags: u32][prefix][suffix]
    proc.ipc_msg = ipc.Message.init(.t_create);
    writeU32LE(proc.ipc_msg.data_buf[0..4], @truncate(flags));
    const c_prefix = resolved.prefix;
    const suffix = resolved.suffix;
    const c_prefix_len: u32 = @intCast(c_prefix.len);
    const suffix_len: u32 = @intCast(suffix.len);
    if (c_prefix_len > 0) {
        @memcpy(proc.ipc_msg.data_buf[4..][0..c_prefix_len], c_prefix);
    }
    if (suffix_len > 0) {
        @memcpy(proc.ipc_msg.data_buf[4 + c_prefix_len ..][0..suffix_len], suffix);
    }
    proc.ipc_msg.data_len = 4 + c_prefix_len + suffix_len;

    proc.syscall_ret = fd_val;

    proc.state = .blocked;
    sendToServer(chan, proc);
    process.scheduleNext();
}

/// read(fd, buf, count) → bytes_read
/// For IPC channels: sends T_READ to the server and blocks for reply.
pub fn sysRead(fd: u64, buf_ptr: u64, count: u64) u64 {
    const pipe_mod = @import("../pipe.zig");

    // For fd 0, check if process has an explicit FdEntry override.
    // If not, use the default keyboard/console read path.
    if (fd == 0) {
        const proc0 = process.getCurrent() orelse return EBADF;
        if (proc0.getFdEntry(0) == null) {
            // Default: console read (stdin from keyboard)
            const keyboard = @import("../keyboard.zig");
            if (buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
            if (count == 0) return 0;

            // Check if data is already available
            if (keyboard.dataAvailable(proc0.vt)) {
                const dest: [*]u8 = @ptrFromInt(buf_ptr);
                const n = keyboard.read(proc0.vt, dest, @intCast(@min(count, 4096)));
                return n;
            }

            // No data — block and wait for keyboard input
            proc0.pending_op = .console_read;
            proc0.ipc_recv_buf_ptr = buf_ptr;
            proc0.pending_fd = @intCast(@min(count, 4096)); // stash requested size
            keyboard.registerWaiter(proc0.vt, @intCast(proc0.pid), buf_ptr, @intCast(@min(count, 4096)));
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
        const net = @import("../net.zig");
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

    // Proc fd: kernel-generated process info
    if (entry_ptr.fd_type == .proc) {
        return devfiles.procRead(entry_ptr, buf_ptr, count);
    }

    // Container fd: kernel-generated container info
    if (entry_ptr.fd_type == .cntr) {
        return devfiles.cntrRead(entry_ptr, buf_ptr, count);
    }

    // Virtual device fds
    if (entry_ptr.fd_type == .dev_null) return 0; // EOF
    if (entry_ptr.fd_type == .dev_zero) {
        const dest: [*]u8 = @ptrFromInt(buf_ptr);
        const n = @min(count, 4096);
        @memset(dest[0..n], 0);
        return n;
    }
    if (entry_ptr.fd_type == .dev_random) {
        const dest: [*]u8 = @ptrFromInt(buf_ptr);
        const n = @min(count, 4096);
        devfiles.devRandomFill(dest[0..n]);
        return n;
    }
    if (entry_ptr.fd_type == .dev_pci) {
        return devfiles.pciRead(entry_ptr, buf_ptr, count);
    }
    if (entry_ptr.fd_type == .dev_usb) {
        return devfiles.usbRead(entry_ptr, buf_ptr, count);
    }
    if (entry_ptr.fd_type == .dev_mouse) {
        return devfiles.mouseRead(proc, entry_ptr, buf_ptr, count);
    }
    if (entry_ptr.fd_type == .dev_cpu) {
        return devfiles.cpuInfoRead(entry_ptr, buf_ptr, count);
    }
    if (entry_ptr.fd_type == .dev_ether) {
        return devfiles.etherRead(proc, fd, entry_ptr, buf_ptr, count);
    }
    if (entry_ptr.fd_type == .dev_sysname) {
        return devfiles.sysnameRead(entry_ptr, buf_ptr, count);
    }
    if (entry_ptr.fd_type == .dev_osversion) {
        return devfiles.osversionRead(entry_ptr, buf_ptr, count);
    }
    if (entry_ptr.fd_type == .dev_time) {
        return devfiles.timeRead(entry_ptr, buf_ptr, count);
    }
    if (entry_ptr.fd_type == .dev_kmesg) {
        return devfiles.kmesgRead(entry_ptr, buf_ptr, count);
    }
    if (entry_ptr.fd_type == .dev_reboot) return 0; // write-only
    if (entry_ptr.fd_type == .dev_drivers) {
        return devfiles.driversRead(entry_ptr, buf_ptr, count);
    }
    if (entry_ptr.fd_type == .dev_pid) {
        return devfiles.pidRead(entry_ptr, buf_ptr, count);
    }
    if (entry_ptr.fd_type == .dev_user) {
        return devfiles.userRead(entry_ptr, buf_ptr, count);
    }
    if (entry_ptr.fd_type == .dev_consctl) return 0; // write-only
    if (entry_ptr.fd_type == .dev_sysstat) {
        return devfiles.sysstatRead(entry_ptr, buf_ptr, count);
    }
    if (entry_ptr.fd_type == .dev_trace) {
        return devfiles.traceRead(entry_ptr, buf_ptr, count);
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

        proc.state = .blocked;
        sendToServer(chan, proc);
        process.scheduleNext();
    }

    // Raw IPC read (existing behavior)
    const len: u32 = @intCast(@min(count, ipc.MAX_MSG_DATA));

    proc.ipc_msg = ipc.Message.init(.t_read);
    proc.ipc_msg.data_len = len; // requested read size

    proc.pending_op = .none;
    proc.ipc_recv_buf_ptr = buf_ptr;

    proc.state = .blocked;
    sendToServer(chan, proc);
    process.scheduleNext();
}

pub fn sysPread(fd: u64, buf_ptr: u64, count: u64, offset: u64) u64 {
    const blk = @import("../blk.zig");

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
        if (!blk.readBlock(block_start + i, buf)) {
            if (bytes_read > 0) return bytes_read;
            return EIO;
        }
        bytes_read += 4096;
    }

    return bytes_read;
}

pub fn sysPwrite(fd: u64, buf_ptr: u64, count: u64, offset: u64) u64 {
    const blk = @import("../blk.zig");

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
        if (!blk.writeBlock(block_start + i, buf)) {
            if (bytes_written > 0) return bytes_written;
            return EIO;
        }
        bytes_written += 4096;
    }

    return bytes_written;
}

pub fn sysSeek(fd: u64, offset: u64, whence: u64) u64 {
    const proc = process.getCurrent() orelse return ENOSYS;
    const entry_ptr = proc.getFdEntryPtr(@intCast(fd)) orelse return EBADF;

    switch (whence) {
        0 => entry_ptr.read_offset = @intCast(offset), // SEEK_SET
        1 => entry_ptr.read_offset +|= @intCast(offset), // SEEK_CUR
        else => return ENOSYS,
    }
    return entry_ptr.read_offset;
}

/// close(fd) → 0 or error
pub fn sysClose(fd: u64) u64 {
    const proc = process.getCurrent() orelse return EBADF;
    if (fd >= 32) return EBADF;

    const entry = proc.getFdEntry(@intCast(fd)) orelse return EBADF;

    // Pipe fd: close the appropriate end
    if (entry.fd_type == .pipe) {
        const pipe_mod = @import("../pipe.zig");
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
        const net = @import("../net.zig");
        net.netfs.netClose(entry.net_kind, entry.net_conn);
        proc.closeFd(@intCast(fd));
        return 0;
    }

    // Proc fd: no cleanup needed, just close
    if (entry.fd_type == .proc) {
        proc.closeFd(@intCast(fd));
        return 0;
    }

    // Virtual device fds: no cleanup, just close
    if (entry.fd_type == .dev_null or entry.fd_type == .dev_zero or entry.fd_type == .dev_random) {
        proc.closeFd(@intCast(fd));
        return 0;
    }

    // Ether fd: free the client slot
    if (entry.fd_type == .dev_ether) {
        const ether_mod = @import("../ether.zig");
        ether_mod.freeClient(entry.ether_client);
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

        proc.state = .blocked;
        sendToServer(chan, proc);
        process.scheduleNext();
    }

    // Non-server fd: just close locally
    proc.closeFd(@intCast(fd));
    return 0;
}

/// pipe(result_ptr) → 0 on success, negative on error.
/// Creates a pipe and writes [read_fd: u32, write_fd: u32] to result_ptr.
pub fn sysPipe(result_ptr: u64) u64 {
    if (result_ptr == 0 or result_ptr >= 0x0000_8000_0000_0000) return EFAULT;

    const proc = process.getCurrent() orelse return EBADF;
    const pipe_mod = @import("../pipe.zig");

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
pub fn sysStat(fd: u64, stat_buf_ptr: u64) u64 {
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

    // Proc fds: synthetic stat
    if (entry.fd_type == .proc) {
        const stat_ptr: *align(1) [64]u8 = @ptrFromInt(stat_buf_ptr);
        @memset(stat_ptr, 0);
        // file_type at offset 4: 1=directory for dir/pid_dir, 0=file otherwise
        if (entry.proc_kind == .dir or entry.proc_kind == .pid_dir) {
            writeU32LE(@ptrCast(stat_ptr[4..8]), 1);
        }
        return 0;
    }

    // Container fds: synthetic stat
    if (entry.fd_type == .cntr) {
        const stat_ptr: *align(1) [64]u8 = @ptrFromInt(stat_buf_ptr);
        @memset(stat_ptr, 0);
        if (entry.cntr_kind == .dir) {
            writeU32LE(@ptrCast(stat_ptr[4..8]), 1);
        }
        return 0;
    }

    // Virtual device fds: synthetic stat (size=0, type=file)
    if (entry.fd_type == .dev_null or entry.fd_type == .dev_zero or entry.fd_type == .dev_random or entry.fd_type == .dev_ether) {
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

        proc.state = .blocked;
        sendToServer(chan, proc);
        process.scheduleNext();
    }

    return EBADF;
}

/// remove(path_ptr, path_len) → 0 or negative error.
/// Resolve path in namespace, send T_REMOVE to the server.
pub fn sysRemove(path_ptr: u64, path_len: u64) u64 {
    const proc = process.getCurrent() orelse return ENOSYS;
    if (path_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    if (path_len == 0 or path_len > 256) return ENOENT;

    const path: [*]const u8 = @ptrFromInt(path_ptr);
    const path_slice = path[0..@intCast(path_len)];

    const resolved = proc.getNs().resolve(path_slice) orelse return ENOENT;

    const chan = ipc.getChannel(resolved.channel_id) orelse return ENOENT;

    // Cannot remove on kernel-backed channels
    if (chan.kernel_data != null) return ENOSYS;

    // Send T_REMOVE with [prefix][suffix]
    proc.ipc_msg = ipc.Message.init(.t_remove);
    const rm_prefix = resolved.prefix;
    const suffix = resolved.suffix;
    const rm_prefix_len: u32 = @intCast(rm_prefix.len);
    const suffix_len: u32 = @intCast(suffix.len);
    if (rm_prefix_len > 0) {
        @memcpy(proc.ipc_msg.data_buf[0..rm_prefix_len], rm_prefix);
    }
    if (suffix_len > 0) {
        @memcpy(proc.ipc_msg.data_buf[rm_prefix_len..][0..suffix_len], suffix);
    }
    proc.ipc_msg.data_len = rm_prefix_len + suffix_len;

    proc.pending_op = .remove;
    proc.pending_fd = 0;
    proc.syscall_ret = 0;

    proc.state = .blocked;
    sendToServer(chan, proc);
    process.scheduleNext();
}

/// rename(old_path_ptr, old_path_len, new_path_ptr, new_path_len) → 0 or negative error.
/// Resolves both paths, verifies same server, sends T_RENAME.
pub fn sysRename(old_ptr: u64, old_len: u64, new_ptr: u64, new_len: u64) u64 {
    const proc = process.getCurrent() orelse return ENOSYS;
    if (old_ptr >= 0x0000_8000_0000_0000 or new_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    if (old_len == 0 or old_len > 256 or new_len == 0 or new_len > 256) return ENOENT;

    const old_path: [*]const u8 = @ptrFromInt(old_ptr);
    const new_path: [*]const u8 = @ptrFromInt(new_ptr);

    const old_resolved = proc.getNs().resolve(old_path[0..@intCast(old_len)]) orelse return ENOENT;
    const new_resolved = proc.getNs().resolve(new_path[0..@intCast(new_len)]) orelse return ENOENT;

    // Both paths must be on the same server
    if (old_resolved.channel_id != new_resolved.channel_id) return ENOSYS;

    const chan = ipc.getChannel(old_resolved.channel_id) orelse return ENOENT;
    if (chan.kernel_data != null) return ENOSYS;

    // Build T_RENAME: [old_prefix][old_suffix] \0 [new_prefix][new_suffix]
    proc.ipc_msg = ipc.Message.init(.t_rename);
    const old_prefix = old_resolved.prefix;
    const old_suffix = old_resolved.suffix;
    const new_prefix = new_resolved.prefix;
    const new_suffix = new_resolved.suffix;
    const old_plen: u32 = @intCast(old_prefix.len);
    const old_slen: u32 = @intCast(old_suffix.len);
    const new_plen: u32 = @intCast(new_prefix.len);
    const new_slen: u32 = @intCast(new_suffix.len);
    const old_total = old_plen + old_slen;
    const new_total = new_plen + new_slen;
    const total: u32 = old_total + 1 + new_total;
    if (total > ipc.MAX_MSG_DATA) return ENOENT;

    var pos: u32 = 0;
    if (old_plen > 0) {
        @memcpy(proc.ipc_msg.data_buf[pos..][0..old_plen], old_prefix);
        pos += old_plen;
    }
    if (old_slen > 0) {
        @memcpy(proc.ipc_msg.data_buf[pos..][0..old_slen], old_suffix);
        pos += old_slen;
    }
    proc.ipc_msg.data_buf[pos] = 0; // separator
    pos += 1;
    if (new_plen > 0) {
        @memcpy(proc.ipc_msg.data_buf[pos..][0..new_plen], new_prefix);
        pos += new_plen;
    }
    if (new_slen > 0) {
        @memcpy(proc.ipc_msg.data_buf[pos..][0..new_slen], new_suffix);
    }
    proc.ipc_msg.data_len = total;

    proc.pending_op = .rename;
    proc.pending_fd = 0;
    proc.syscall_ret = 0;

    proc.state = .blocked;
    sendToServer(chan, proc);
    process.scheduleNext();
}

/// truncate(fd, new_size) → 0 or negative error.
/// Sends T_TRUNCATE to the server with handle + new size.
pub fn sysTruncate(fd: u64, new_size: u64) u64 {
    const proc = process.getCurrent() orelse return ENOSYS;
    const entry = proc.getFdEntry(@intCast(fd)) orelse return EBADF;

    const chan = ipc.getChannel(entry.channel_id) orelse return EBADF;
    if (entry.server_handle == 0) return ENOSYS;

    // Build T_TRUNCATE: [handle: u32][new_size: u64]
    proc.ipc_msg = ipc.Message.init(.t_truncate);
    writeU32LE(proc.ipc_msg.data_buf[0..4], entry.server_handle);
    writeU64LE(proc.ipc_msg.data_buf[4..12], new_size);
    proc.ipc_msg.data_len = 12;

    proc.pending_op = .truncate;
    proc.pending_fd = @intCast(fd);
    proc.syscall_ret = 0;

    proc.state = .blocked;
    sendToServer(chan, proc);
    process.scheduleNext();
}

/// wstat(fd, mode, uid, gid, mask) → 0 or negative error.
/// Sends T_WSTAT to the server to modify inode metadata.
pub fn sysWstat(fd: u64, mode: u64, uid: u64, gid: u64, mask: u64) u64 {
    const proc = process.getCurrent() orelse return ENOSYS;
    const entry = proc.getFdEntry(@intCast(fd)) orelse return EBADF;

    const chan = ipc.getChannel(entry.channel_id) orelse return EBADF;
    if (entry.server_handle == 0) return ENOSYS;

    // Build T_WSTAT: [handle:u32][mask:u32][mode:u32][uid:u32][gid:u32][caller_uid:u32] = 24 bytes
    proc.ipc_msg = ipc.Message.init(.t_wstat);
    writeU32LE(proc.ipc_msg.data_buf[0..4], entry.server_handle);
    writeU32LE(proc.ipc_msg.data_buf[4..8], @truncate(mask));
    writeU32LE(proc.ipc_msg.data_buf[8..12], @truncate(mode));
    writeU32LE(proc.ipc_msg.data_buf[12..16], @truncate(uid));
    writeU32LE(proc.ipc_msg.data_buf[16..20], @truncate(gid));
    writeU32LE(proc.ipc_msg.data_buf[20..24], @as(u32, proc.uid));
    proc.ipc_msg.data_len = 24;

    proc.pending_op = .wstat;
    proc.pending_fd = @intCast(fd);
    proc.syscall_ret = 0;

    proc.state = .blocked;
    sendToServer(chan, proc);
    process.scheduleNext();
}
