/// Namespace and miscellaneous syscall handlers.
const process = @import("../process.zig");
const klog = @import("../klog.zig");
const pmm = @import("../pmm.zig");
const timer = @import("../timer.zig");
const ipc = @import("../ipc.zig");
const root = @import("root.zig");

const ENOSYS = root.ENOSYS;
const EBADF = root.EBADF;
const EFAULT = root.EFAULT;
const EINVAL = root.EINVAL;
const EIO = root.EIO;

/// mount(fd, path_ptr, path_len, flags) → 0 on success, negative on error.
/// Mount an IPC channel at the given path in the current namespace.
pub fn sysMount(fd: u64, path_ptr: u64, path_len: u64, flags: u64) u64 {
    const proc = process.getCurrent() orelse return ENOSYS;
    if (path_ptr == 0 or path_ptr >= 0x0000_8000_0000_0000 or path_len == 0 or path_len > 256) return EFAULT;
    if (fd >= 32) return EBADF;

    const entry = proc.getFdEntry(@intCast(fd)) orelse return EBADF;
    if (entry.fd_type != .ipc) return EBADF; // Only IPC fds can be mounted

    const path: [*]const u8 = @ptrFromInt(path_ptr);
    const path_slice = path[0..path_len];

    const namespace = @import("../namespace.zig");
    const ns = proc.getNs();
    const mount_flags: namespace.MountFlags = @bitCast(@as(u8, @truncate(flags)));
    ns.mount(path_slice, entry.channel_id, mount_flags) catch return EIO;
    return 0;
}

/// bind(fd, path_ptr, path_len, flags) → 0 on success, negative on error.
/// Bind is the same as mount in Fornax (Plan 9 uses bind for same-namespace rebinding).
pub fn sysBind(fd: u64, path_ptr: u64, path_len: u64, flags: u64) u64 {
    return sysMount(fd, path_ptr, path_len, flags);
}

/// unmount(path_ptr, path_len) → 0 on success, negative on error.
/// Remove a mount point from the current namespace.
pub fn sysUnmount(path_ptr: u64, path_len: u64) u64 {
    const proc = process.getCurrent() orelse return ENOSYS;
    if (path_ptr == 0 or path_ptr >= 0x0000_8000_0000_0000 or path_len == 0 or path_len > 256) return EFAULT;

    const path: [*]const u8 = @ptrFromInt(path_ptr);
    const ns = proc.getNs();
    ns.unmount(path[0..path_len]);
    return 0;
}

pub fn sysKlog(buf_ptr: u64, buf_len: u64, offset: u64) u64 {
    if (buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    if (buf_len == 0) return 0;

    const dest: [*]u8 = @ptrFromInt(buf_ptr);
    const n = @min(buf_len, 4096);

    return klog.read(dest[0..n], offset);
}

/// sysinfo(info_ptr) → 0 or error
/// Writes SysInfo struct { total_pages: u64, free_pages: u64, page_size: u64 } to user buffer.
pub fn sysSysinfo(info_ptr: u64) u64 {
    if (info_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    if (info_ptr % 8 != 0) return EFAULT;

    const ptr: *[4]u64 = @ptrFromInt(info_ptr);
    ptr[0] = pmm.getTotalPages();
    ptr[1] = pmm.getFreePages();
    ptr[2] = 4096;
    ptr[3] = timer.getTicks() / timer.TICKS_PER_SEC;
    return 0;
}

pub fn sysSleep(ms: u64) u64 {
    const proc = process.getCurrent() orelse return EFAULT;

    // At least 1 tick, even for small ms values
    const ticks_to_sleep: u32 = @intCast(@max(1, ms * timer.TICKS_PER_SEC / 1000));
    proc.sleep_until = timer.getTicks() +% ticks_to_sleep;
    proc.pending_op = .sleep;
    proc.state = .blocked;
    process.scheduleNext();
}

pub fn sysShutdown(flags: u64) noreturn {
    const cpu = switch (@import("builtin").cpu.arch) {
        .x86_64 => @import("../arch/x86_64/cpu.zig"),
        .riscv64 => @import("../arch/riscv64/cpu.zig"),
        .aarch64 => @import("../arch/aarch64/cpu.zig"),
        else => @compileError("unsupported arch for shutdown"),
    };
    // Container processes cannot shut down the host
    if (process.getCurrent()) |proc| {
        if (proc.container_id != 0xFF) {
            proc.state = .dead;
            process.scheduleNext();
        }
    }
    if (flags == 1) {
        klog.warn("syscall: reboot requested\n");
        cpu.resetSystem();
    } else {
        klog.warn("syscall: shutdown requested\n");
        cpu.acpiShutdown();
    }
}
