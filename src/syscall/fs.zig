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
            if (buf_ptr == 0 or buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
            if (count == 0) return 0;
            const buf: [*]const u8 = @ptrFromInt(buf_ptr);
            const len: usize = @intCast(@min(count, 64));
            keyboard.handleCtl(proc.vt, buf[0..len]);
            return len;
        }
        if ((fd == 1 or fd == 2) and proc.getFdEntry(@intCast(fd)) == null) {
            // Default: direct framebuffer console + serial (routed to process's VT)
            if (buf_ptr == 0 or buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
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

    if (buf_ptr == 0 or buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
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

    // Proc fd: write "kill" to /proc/N/ctl
    if (entry.fd_type == .proc) {
        return devfiles.procWrite(entry, buf_ptr, count);
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

    // /dev/ipcctl: write sets effective_max_data (root only)
    if (entry.fd_type == .dev_ipcctl) {
        return devfiles.ipcctlWrite(buf_ptr, count);
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
        entry.fd_type == .dev_trace or
        entry.fd_type == .dev_fbinfo)
    {
        return EBADF;
    }

    // Raw Ethernet write: ctl commands or send frame via virtio-net
    if (entry.fd_type == .dev_ether) {
        const ether_mod = @import("../ether.zig");
        const virtio_net = @import("../virtio_net.zig");
        const src: [*]const u8 = @ptrFromInt(buf_ptr);
        const max_frame: usize = if (virtio_net.hasTsoOffload()) virtio_net.TSO_MAX_FRAME else 1518;
        const len: usize = @intCast(@min(count, max_frame));
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
        // TSO: large TCP frames (> 1514) are offloaded to virtio device
        if (len > 1514 and virtio_net.hasTsoOffload()) {
            _ = virtio_net.sendTso(src[0..len], 1460);
            return len;
        }
        // TCP checksum offload: if device supports CSUM and frame is IPv4+TCP,
        // set NEEDS_CSUM so the device computes the checksum.
        if (virtio_net.hasCsumOffload() and len >= 34) {
            const ethertype = @as(u16, src[12]) << 8 | src[13];
            if (ethertype == 0x0800 and src[23] == 6) { // IPv4 + TCP
                const ip_hdr_len: u16 = @as(u16, src[14] & 0x0F) * 4;
                _ = virtio_net.sendWithCsum(src[0..len], 14 + ip_hdr_len, 16);
                return len;
            }
        }
        _ = virtio_net.send(src[0..len]);
        return len;
    }

    // IRQ forward fd: mask/unmask commands
    if (entry.fd_type == .dev_irq) {
        return devfiles.irqWrite(buf_ptr, count, entry);
    }

    const chan = ipc.getChannel(entry.channel_id) orelse return EBADF;
    const buf: [*]const u8 = @ptrFromInt(buf_ptr);

    // Server-backed fd: T_WRITE with [handle: u32][data...]
    if (entry.server_handle > 0) {
        const max_data = ipc.effective_max_data - 4;
        const data_len: u32 = @intCast(@min(count, max_data));

        proc.ipc_msg.reset(.t_write);
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
    const len: u32 = @intCast(@min(count, ipc.effective_max_data));

    proc.ipc_msg.reset(.t_write);
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
        if (strEql(path_slice, "/dev/random") or strEql(path_slice, "/dev/urandom")) {
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
            if (proc.group_id != 0xFF) return @bitCast(@as(i64, -1));
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
        if (strEql(path_slice, "/dev/ipcctl")) {
            return proc.allocDevFd(.dev_ipcctl) orelse return EMFILE;
        }
        if (strEql(path_slice, "/dev/fbinfo")) {
            return proc.allocDevFd(.dev_fbinfo) orelse return EMFILE;
        }
    }

    // /cntr/* is now served by cntrd (userspace IPC server).
    // Requests go through the namespace mount, not kernel interception.

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

        // "/proc/supervisor"
        if (suffix.len == 10 and suffix[0] == 's' and suffix[1] == 'u' and
            suffix[2] == 'p' and suffix[3] == 'e' and suffix[4] == 'r' and
            suffix[5] == 'v' and suffix[6] == 'i' and suffix[7] == 's' and
            suffix[8] == 'o' and suffix[9] == 'r')
        {
            return proc.allocProcFd(.supervisor, 0) orelse return EMFILE;
        }

        // "/proc/supervisor/ctl"
        if (suffix.len == 14 and suffix[0] == 's' and suffix[1] == 'u' and
            suffix[2] == 'p' and suffix[3] == 'e' and suffix[4] == 'r' and
            suffix[5] == 'v' and suffix[6] == 'i' and suffix[7] == 's' and
            suffix[8] == 'o' and suffix[9] == 'r' and suffix[10] == '/' and
            suffix[11] == 'c' and suffix[12] == 't' and suffix[13] == 'l')
        {
            return proc.allocProcFd(.supervisor_ctl, 0) orelse return EMFILE;
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
    const path_slice = path[0..@intCast(path_len)];

    // Writable virtual files: redirect create to open so shell ">" works.
    // /proc/* paths are all kernel-intercepted — create == open.
    if (path_len >= 6 and path_slice[0] == '/' and path_slice[1] == 'p' and
        path_slice[2] == 'r' and path_slice[3] == 'o' and path_slice[4] == 'c' and
        (path_len == 5 or path_slice[5] == '/'))
    {
        return sysOpen(path_ptr, path_len);
    }

    const resolved = proc.getNs().resolve(path_slice) orelse return ENOENT;

    const chan = ipc.getChannel(resolved.channel_id) orelse return ENOENT;

    // Can't create on kernel-backed channels
    if (chan.kernel_data != null) return ENOSYS;

    const fd_val = proc.allocFd(resolved.channel_id, false) orelse return EMFILE;

    proc.pending_op = .create;
    proc.pending_fd = fd_val;

    // Build T_CREATE: [flags: u32][prefix][suffix]
    proc.ipc_msg.reset(.t_create);
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
            if (buf_ptr == 0 or buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
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

    if (buf_ptr == 0 or buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
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

    // Proc fd: kernel-generated process info
    if (entry_ptr.fd_type == .proc) {
        return devfiles.procRead(entry_ptr, buf_ptr, count);
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
    if (entry_ptr.fd_type == .dev_fbinfo) {
        return devfiles.fbinfoRead(entry_ptr, buf_ptr, count);
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
    if (entry_ptr.fd_type == .dev_ipcctl) {
        return devfiles.ipcctlRead(entry_ptr, buf_ptr, count);
    }
    if (entry_ptr.fd_type == .dev_irq) {
        return devfiles.irqRead(proc, fd, entry_ptr, buf_ptr, count);
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
        const read_count: u32 = @intCast(@min(count, ipc.effective_max_data));

        proc.ipc_msg.reset(.t_read);
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
    const len: u32 = @intCast(@min(count, ipc.effective_max_data));

    proc.ipc_msg.reset(.t_read);
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

    // Proc fd: no cleanup needed, just close
    if (entry.fd_type == .proc) {
        proc.closeFd(@intCast(fd));
        return 0;
    }

    // Virtual device fds: no cleanup, just close
    if (entry.fd_type == .dev_null or entry.fd_type == .dev_zero or entry.fd_type == .dev_random or entry.fd_type == .dev_fbinfo) {
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

    // IRQ forward fd: free the forward slot
    if (entry.fd_type == .dev_irq) {
        const irq_forward = @import("../irq_forward.zig");
        irq_forward.free(entry.irq_slot);
        proc.closeFd(@intCast(fd));
        return 0;
    }

    // Server-backed fd: send T_CLOSE to server before closing locally
    if (entry.server_handle > 0) {
        const chan = ipc.getChannel(entry.channel_id) orelse {
            proc.closeFd(@intCast(fd));
            return 0;
        };

        proc.ipc_msg.reset(.t_close);
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
        proc.ipc_msg.reset(.t_stat);
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
    proc.ipc_msg.reset(.t_remove);
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
    proc.ipc_msg.reset(.t_rename);
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
    proc.ipc_msg.reset(.t_truncate);
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
    proc.ipc_msg.reset(.t_wstat);
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

/// writev(fd, iovecs_ptr, iovecs_count) → total bytes written
/// For dev_ether fds: batch-send frames via virtio with a single notify.
/// For other fds: iterate and call sysWrite per iovec.
pub fn sysWritev(fd: u64, iovecs_ptr: u64, iovecs_count: u64) u64 {
    if (iovecs_ptr == 0 or iovecs_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    if (iovecs_count == 0) return 0;
    if (iovecs_count > 128) return EINVAL;

    const proc = process.getCurrent() orelse return EBADF;
    const entry = proc.getFdEntry(@intCast(fd)) orelse return EBADF;

    const count: usize = @intCast(iovecs_count);

    // Iovec: { ptr: u64, len: u64 } = 16 bytes each
    const iov_base: [*]const extern struct { ptr: u64, len: u64 } = @ptrFromInt(iovecs_ptr);

    // Fast path: dev_ether fd → batch send via virtio
    if (entry.fd_type == .dev_ether) {
        const virtio_net = @import("../virtio_net.zig");
        const has_tso = virtio_net.hasTsoOffload();
        var frame_refs: [128]virtio_net.FrameRef = undefined;
        var valid: usize = 0;
        var sent: u32 = 0;
        for (0..count) |i| {
            const iov = iov_base[i];
            if (iov.ptr == 0 or iov.ptr >= 0x0000_8000_0000_0000) continue;
            if (iov.len == 0) continue;
            if (iov.len > 1514) {
                // TSO frame: flush any pending normal frames, then send via sendTso
                if (has_tso) {
                    if (valid > 0) {
                        sent += virtio_net.sendBatch(frame_refs[0..valid]);
                        valid = 0;
                    }
                    const src: [*]const u8 = @ptrFromInt(iov.ptr);
                    if (virtio_net.sendTso(src[0..iov.len], 1460)) sent += 1;
                }
                continue;
            }
            frame_refs[valid] = .{
                .data = @ptrFromInt(iov.ptr),
                .len = @intCast(iov.len),
            };
            valid += 1;
        }
        if (valid > 0) {
            sent += virtio_net.sendBatch(frame_refs[0..valid]);
        }
        return sent;
    }

    // Generic fallback: iterate and write each iovec
    var total: u64 = 0;
    for (0..count) |i| {
        const iov = iov_base[i];
        if (iov.len == 0) continue;
        const n = sysWrite(fd, iov.ptr, iov.len);
        if (n >= 0x8000_0000_0000_0000) return n; // error
        total += n;
    }
    return total;
}
