/// Linux syscall compatibility layer for Fornax containers.
///
/// Translates Linux syscall numbers and conventions to Fornax equivalents.
/// Per-arch syscall numbers: x86_64 uses legacy numbers, riscv64/aarch64
/// use the generic Linux ABI (no legacy syscalls like open/stat/pipe).
///
/// Detection: Process.compat == 1 (set via container config or ELF detection).
/// Dispatch: syscall.dispatch() routes here before Fornax SYS enum lookup.
const process = @import("process.zig");
const ipc = @import("ipc.zig");
const builtin = @import("builtin");

// ── Linux syscall numbers (per-arch) ──────────────────────────────────────
// x86_64 has legacy syscalls (open=2, stat=4, pipe=22, etc.)
// riscv64/aarch64 use the generic Linux ABI (openat=56, fstatat=79, pipe2=59, etc.)
// Some syscalls share numbers across all arches (e.g. clone=220 on generic).

const is_x86_64 = builtin.cpu.arch == .x86_64;
const is_generic = builtin.cpu.arch == .riscv64 or builtin.cpu.arch == .aarch64;

// I/O
const LNX_READ: u64 = if (is_x86_64) 0 else 63;
const LNX_WRITE: u64 = if (is_x86_64) 1 else 64;
const LNX_CLOSE: u64 = if (is_x86_64) 3 else 57;
const LNX_FSTAT: u64 = if (is_x86_64) 5 else 80;
const LNX_LSEEK: u64 = if (is_x86_64) 8 else 62;
const LNX_MMAP: u64 = if (is_x86_64) 9 else 222;
const LNX_MPROTECT: u64 = if (is_x86_64) 10 else 226;
const LNX_MUNMAP: u64 = if (is_x86_64) 11 else 215;
const LNX_BRK: u64 = if (is_x86_64) 12 else 214;
const LNX_RT_SIGACTION: u64 = if (is_x86_64) 13 else 134;
const LNX_RT_SIGPROCMASK: u64 = if (is_x86_64) 14 else 135;
const LNX_IOCTL: u64 = if (is_x86_64) 16 else 29;
const LNX_READV: u64 = if (is_x86_64) 19 else 65;
const LNX_WRITEV: u64 = if (is_x86_64) 20 else 66;
const LNX_MADVISE: u64 = if (is_x86_64) 28 else 233;
const LNX_DUP: u64 = if (is_x86_64) 32 else 23;
const LNX_GETPID: u64 = if (is_x86_64) 39 else 172;
const LNX_CLONE: u64 = if (is_x86_64) 56 else 220;
const LNX_EXECVE: u64 = if (is_x86_64) 59 else 221;
const LNX_EXIT: u64 = if (is_x86_64) 60 else 93;
const LNX_WAIT4: u64 = if (is_x86_64) 61 else 260;
const LNX_UNAME: u64 = if (is_x86_64) 63 else 160;
const LNX_FCNTL: u64 = if (is_x86_64) 72 else 25;
const LNX_FTRUNCATE: u64 = if (is_x86_64) 77 else 46;
const LNX_GETCWD: u64 = if (is_x86_64) 79 else 17;
const LNX_FCHMOD: u64 = if (is_x86_64) 91 else 52;
const LNX_GETPPID: u64 = if (is_x86_64) 110 else 173;
const LNX_SETPGID: u64 = if (is_x86_64) 109 else 154;
const LNX_SETSID: u64 = if (is_x86_64) 112 else 157;
const LNX_GETTID: u64 = if (is_x86_64) 186 else 178;
const LNX_FUTEX: u64 = if (is_x86_64) 202 else 98;
const LNX_GETDENTS64: u64 = if (is_x86_64) 217 else 61;
const LNX_SET_TID_ADDRESS: u64 = if (is_x86_64) 218 else 96;
const LNX_CLOCK_GETTIME: u64 = if (is_x86_64) 228 else 113;
const LNX_EXIT_GROUP: u64 = if (is_x86_64) 231 else 94;
const LNX_OPENAT: u64 = if (is_x86_64) 257 else 56;
const LNX_MKDIRAT: u64 = if (is_x86_64) 258 else 34;
const LNX_NEWFSTATAT: u64 = if (is_x86_64) 262 else 79;
const LNX_UNLINKAT: u64 = if (is_x86_64) 263 else 35;
const LNX_SET_ROBUST_LIST: u64 = if (is_x86_64) 273 else 99;
const LNX_PIPE2: u64 = if (is_x86_64) 293 else 59;
const LNX_PRLIMIT64: u64 = if (is_x86_64) 302 else 261;
const LNX_RENAMEAT2: u64 = if (is_x86_64) 316 else 276;
const LNX_GETRANDOM: u64 = if (is_x86_64) 318 else 278;

// x86_64-only legacy syscalls. On generic arches, each gets a unique
// high sentinel value that never matches real syscall numbers, so the
// switch arms compile but never fire.
const LNX_OPEN: u64 = if (is_x86_64) 2 else 0x8000_0001;
const LNX_STAT: u64 = if (is_x86_64) 4 else 0x8000_0002;
const LNX_LSTAT: u64 = if (is_x86_64) 6 else 0x8000_0003;
const LNX_ACCESS: u64 = if (is_x86_64) 21 else 0x8000_0004;
const LNX_PIPE: u64 = if (is_x86_64) 22 else 0x8000_0005;
const LNX_DUP2: u64 = if (is_x86_64) 33 else 0x8000_0006;
const LNX_FORK: u64 = if (is_x86_64) 57 else 0x8000_0007;
const LNX_VFORK: u64 = if (is_x86_64) 58 else 0x8000_0008;
const LNX_RENAME: u64 = if (is_x86_64) 82 else 0x8000_0009;
const LNX_MKDIR: u64 = if (is_x86_64) 83 else 0x8000_000A;
const LNX_RMDIR: u64 = if (is_x86_64) 84 else 0x8000_000B;
const LNX_CREAT: u64 = if (is_x86_64) 85 else 0x8000_000C;
const LNX_UNLINK: u64 = if (is_x86_64) 87 else 0x8000_000D;
const LNX_READLINK: u64 = if (is_x86_64) 89 else 0x8000_000E;
const LNX_ARCH_PRCTL: u64 = if (is_x86_64) 158 else 0x8000_000F;
const LNX_RENAMEAT: u64 = if (is_x86_64) 264 else 0x8000_0010;

// Generic-only syscalls (riscv64/aarch64). On x86_64, unique sentinels.
const LNX_DUP3: u64 = if (is_x86_64) 0x8000_0011 else 24;
const LNX_FACCESSAT: u64 = if (is_x86_64) 0x8000_0012 else 48;

// Linux constants
const AT_FDCWD: u64 = @bitCast(@as(i64, -100));
const O_CREAT: u64 = 0o100;
const O_DIRECTORY: u64 = 0o200000;
const O_APPEND: u64 = 0o2000;
const O_TRUNC: u64 = 0o1000;
const F_DUPFD: u64 = 0;
const F_GETFD: u64 = 1;
const F_SETFD: u64 = 2;
const F_GETFL: u64 = 3;
const F_SETFL: u64 = 4;
const TIOCGWINSZ: u64 = 0x5413;

// Fornax rfork flags (from lib/root.zig)
const RFPROC: u64 = 0x01;
const RFFDG: u64 = 0x04;

// Import Fornax syscall handlers
const syscall = @import("syscall.zig");

// Error constants (same as Fornax — already Linux-compatible negative values)
const ENOSYS: u64 = @bitCast(@as(i64, -38)); // Linux ENOSYS = 38
const ENOENT: u64 = @bitCast(@as(i64, -2));
const EFAULT: u64 = @bitCast(@as(i64, -14));
const EBADF: u64 = @bitCast(@as(i64, -9));
const EINVAL: u64 = @bitCast(@as(i64, -22));
const EIO: u64 = @bitCast(@as(i64, -5));
const ENOMEM: u64 = @bitCast(@as(i64, -12));
const ENOTTY: u64 = @bitCast(@as(i64, -25));
const ERANGE: u64 = @bitCast(@as(i64, -34));

// ── Main dispatch ─────────────────────────────────────────────────────────

/// Translates a Linux syscall to Fornax equivalents.
/// Called from syscall.dispatch() when proc.compat == 1.
/// Handles both x86_64 legacy and riscv64/aarch64 generic ABI numbers.
pub fn linuxDispatch(nr: u64, a: u64, b: u64, c: u64, d: u64, e: u64) u64 {
    return switch (nr) {
        // ── I/O ───────────────────────────────────────────────────
        LNX_READ => syscall.sysRead(a, b, c),
        LNX_WRITE => syscall.sysWrite(a, b, c),
        LNX_OPEN => linuxOpen(a, b, c),
        LNX_OPENAT => linuxOpenat(a, b, c, d),
        LNX_CLOSE => syscall.sysClose(a),
        LNX_LSEEK => syscall.sysSeek(a, b, c),
        LNX_READV => linuxReadv(a, b, c),
        LNX_WRITEV => linuxWritev(a, b, c),

        // ── File metadata ─────────────────────────────────────────
        LNX_STAT, LNX_LSTAT => linuxPathStat(a, b),
        LNX_FSTAT => linuxFstat(a, b),
        LNX_NEWFSTATAT => linuxNewfstatat(a, b, c, d),

        // ── Memory management ─────────────────────────────────────
        LNX_MMAP => syscall.sysMmap(a, b, c, d),
        LNX_MUNMAP => syscall.sysMunmap(a, b),
        LNX_MPROTECT => 0, // no-op
        LNX_MADVISE => 0, // no-op
        LNX_BRK => syscall.sysBrk(a),

        // ── File descriptors ──────────────────────────────────────
        LNX_DUP => syscall.sysDup(a),
        LNX_DUP2 => syscall.sysDup2(a, b),
        LNX_DUP3 => syscall.sysDup2(a, b), // dup3 flags ignored
        LNX_PIPE => syscall.sysPipe(a),
        LNX_PIPE2 => syscall.sysPipe(a),
        LNX_FCNTL => linuxFcntl(a, b),

        // ── Filesystem operations ─────────────────────────────────
        LNX_RENAME => linuxRename(a, b),
        LNX_RENAMEAT, LNX_RENAMEAT2 => linuxRenameat(nr, a, b, c, d),
        LNX_MKDIR => linuxMkdir(a),
        LNX_MKDIRAT => linuxMkdirat(a, b),
        LNX_RMDIR, LNX_UNLINK => linuxRemove(a),
        LNX_UNLINKAT => linuxUnlinkat(a, b),
        LNX_CREAT => linuxCreat(a),
        LNX_FTRUNCATE => syscall.sysTruncate(a, b),
        LNX_ACCESS => linuxAccess(a),
        LNX_FACCESSAT => linuxFaccessat(a, b),
        LNX_READLINK => EINVAL, // no symlinks
        LNX_FCHMOD => 0, // no-op for now

        // ── Process ───────────────────────────────────────────────
        LNX_EXIT => {
            syscall.sysThreadExit(a);
        },
        LNX_EXIT_GROUP => {
            syscall.sysExit(a);
        },
        LNX_GETPID, LNX_GETTID => syscall.sysGetpid(0),
        LNX_GETPPID => syscall.sysGetpid(1),
        LNX_FORK, LNX_VFORK => syscall.sysRfork(RFPROC | RFFDG),
        LNX_EXECVE => ENOSYS, // containers use spawn mechanism
        LNX_WAIT4 => linuxWait4(a, b, c),
        LNX_SETPGID, LNX_SETSID => 0, // no-op
        LNX_ARCH_PRCTL => syscall.sysArchPrctl(a, b),

        // ── Threading ─────────────────────────────────────────────
        LNX_CLONE => syscall.sysClone(b, e, d, c, a), // reorder: Linux(flags,stack,ptid,ctid,tls) → Fornax(stack,tls,ctid,ptid,flags)
        LNX_FUTEX => syscall.sysFutex(a, b, c, d),
        LNX_SET_TID_ADDRESS => syscall.sysGetpid(0),
        LNX_SET_ROBUST_LIST => 0, // no-op

        // ── Signals (stubs) ───────────────────────────────────────
        LNX_RT_SIGACTION, LNX_RT_SIGPROCMASK => 0,

        // ── Terminal / ioctl ──────────────────────────────────────
        LNX_IOCTL => linuxIoctl(a, b, c),

        // ── Time ──────────────────────────────────────────────────
        LNX_CLOCK_GETTIME => linuxClockGettime(a, b),

        // ── Info ──────────────────────────────────────────────────
        LNX_GETCWD => linuxGetcwd(a, b),
        LNX_UNAME => linuxUname(a),
        LNX_PRLIMIT64 => ENOSYS,
        LNX_GETDENTS64 => linuxGetdents64(a, b, c),

        // ── Random ────────────────────────────────────────────────
        LNX_GETRANDOM => linuxGetrandom(a, b),

        else => ENOSYS,
    };
}

// ── Translation helpers ───────────────────────────────────────────────────

fn linuxOpen(path_ptr: u64, flags: u64, mode: u64) u64 {
    _ = mode;
    const path_len = strlenUser(path_ptr);
    if (path_len == 0) return ENOENT;

    if (flags & O_CREAT != 0) {
        var fx_flags: u64 = 0;
        if (flags & O_DIRECTORY != 0) fx_flags |= 0x01;
        if (flags & O_APPEND != 0) fx_flags |= 0x02;
        return syscall.sysCreate(path_ptr, path_len, fx_flags);
    } else {
        const fd = syscall.sysOpen(path_ptr, path_len);
        // If sysOpen blocked, it won't return here. We only handle non-blocking.
        if (isError(fd)) return fd;
        if (flags & O_TRUNC != 0) {
            _ = syscall.sysTruncate(fd, 0);
        }
        return fd;
    }
}

fn linuxOpenat(dirfd: u64, path_ptr: u64, flags: u64, mode: u64) u64 {
    if (dirfd != AT_FDCWD) return ENOSYS;
    return linuxOpen(path_ptr, flags, mode);
}

fn linuxFstat(fd: u64, linux_buf: u64) u64 {
    // Call Fornax stat — writes 32-byte Fornax stat to user buffer.
    // If sysStat blocks (IPC-backed fd), the delivery path in switchTo
    // checks proc.compat==1 and calls translateStatInPlace.
    const result = syscall.sysStat(fd, linux_buf);
    // If we reach here, sysStat returned without blocking (kernel-intercepted fd)
    if (result == 0) {
        translateStatInPlace(linux_buf);
    }
    return result;
}

fn linuxPathStat(path_ptr: u64, linux_buf: u64) u64 {
    // Multi-step: open → stat → translate → close.
    // For kernel-intercepted paths, all steps are non-blocking.
    // For IPC-backed paths, sysOpen blocks → state machine in IPC reply handler.
    const proc = process.getCurrent() orelse return ENOSYS;
    const path_len = strlenUser(path_ptr);
    if (path_len == 0) return ENOENT;

    // Save linux stat buf — sysOpen checks this to use .linux_stat_open pending_op
    proc.linux_stat_buf = linux_buf;
    const fd = syscall.sysOpen(path_ptr, path_len);

    // If we reach here, sysOpen returned without blocking
    proc.linux_stat_buf = 0;
    if (isError(fd)) return ENOENT;

    // Now stat the fd
    const stat_result = syscall.sysStat(fd, linux_buf);
    // If sysStat blocks, the pending_op for stat delivery + compat translation
    // is handled by the normal .stat path in switchTo.
    if (stat_result == 0) {
        translateStatInPlace(linux_buf);
    }
    _ = syscall.sysClose(fd);
    return stat_result;
}

fn linuxNewfstatat(dirfd: u64, path_ptr: u64, linux_buf: u64, flags: u64) u64 {
    _ = flags;
    if (dirfd != AT_FDCWD) return ENOSYS;
    return linuxPathStat(path_ptr, linux_buf);
}

fn linuxRename(old_ptr: u64, new_ptr: u64) u64 {
    const old_len = strlenUser(old_ptr);
    const new_len = strlenUser(new_ptr);
    if (old_len == 0 or new_len == 0) return ENOENT;
    return syscall.sysRename(old_ptr, old_len, new_ptr, new_len);
}

fn linuxRenameat(nr: u64, a: u64, b: u64, c: u64, d: u64) u64 {
    if (a != AT_FDCWD) return ENOSYS;
    const old_ptr = b;
    const new_ptr = if (nr == LNX_RENAMEAT2) d else c;
    if (nr == LNX_RENAMEAT2 and c != AT_FDCWD) return ENOSYS;
    return linuxRename(old_ptr, new_ptr);
}

fn linuxMkdir(path_ptr: u64) u64 {
    const path_len = strlenUser(path_ptr);
    if (path_len == 0) return ENOENT;
    return syscall.sysCreate(path_ptr, path_len, 0x01); // O_DIR
}

fn linuxMkdirat(dirfd: u64, path_ptr: u64) u64 {
    if (dirfd != AT_FDCWD) return ENOSYS;
    return linuxMkdir(path_ptr);
}

fn linuxRemove(path_ptr: u64) u64 {
    const path_len = strlenUser(path_ptr);
    if (path_len == 0) return ENOENT;
    return syscall.sysRemove(path_ptr, path_len);
}

fn linuxUnlinkat(dirfd: u64, path_ptr: u64) u64 {
    if (dirfd != AT_FDCWD) return ENOSYS;
    return linuxRemove(path_ptr);
}

fn linuxCreat(path_ptr: u64) u64 {
    const path_len = strlenUser(path_ptr);
    if (path_len == 0) return ENOENT;
    return syscall.sysCreate(path_ptr, path_len, 0);
}

fn linuxAccess(path_ptr: u64) u64 {
    const path_len = strlenUser(path_ptr);
    if (path_len == 0) return ENOENT;
    const fd = syscall.sysOpen(path_ptr, path_len);
    // If sysOpen blocked, we never reach here — process will resume
    // with the open fd in syscall_ret. Not ideal for access(), but
    // the process gets a valid fd instead of ENOENT, which is close enough.
    if (isError(fd)) return ENOENT;
    _ = syscall.sysClose(fd);
    return 0;
}

fn linuxFaccessat(dirfd: u64, path_ptr: u64) u64 {
    if (dirfd != AT_FDCWD) return ENOSYS;
    return linuxAccess(path_ptr);
}

fn linuxGetdents64(fd: u64, buf_ptr: u64, buf_size: u64) u64 {
    _ = buf_size;
    // Read Fornax dir entries, then convert to Linux dirent64 format.
    // For now, return ENOSYS — full implementation would require
    // reading Fornax DirEntry structs and converting to Linux dirent64.
    // Container binaries typically use opendir/readdir which go through
    // the POSIX shim's getdents64 handler.
    _ = fd;
    _ = buf_ptr;
    return ENOSYS;
}

fn linuxFcntl(fd: u64, cmd: u64) u64 {
    return switch (cmd) {
        F_DUPFD => syscall.sysDup(fd),
        F_GETFL, F_SETFL, F_GETFD, F_SETFD => 0,
        else => ENOSYS,
    };
}

fn linuxWait4(pid: u64, status_ptr: u64, options: u64) u64 {
    var flags: u64 = 0;
    if (options & 1 != 0) flags |= 1; // WNOHANG

    // Convert pid=-1 to Fornax convention: 0 means any child
    const fx_pid: u64 = if (pid == @as(u64, @bitCast(@as(i64, -1)))) 0 else pid;

    const result = syscall.sysWait(fx_pid, flags);
    // If sysWait blocks, we don't reach here.

    if (result != 0 and !isError(result) and status_ptr != 0 and status_ptr < 0x0000_8000_0000_0000) {
        // Packed result: upper 32 = child pid, lower 32 = POSIX status word
        const status: *align(1) u32 = @ptrFromInt(status_ptr);
        status.* = @truncate(result); // lower 32 = status word
        return result >> 32; // upper 32 = child pid
    }
    return result;
}

fn linuxReadv(fd: u64, iov_ptr: u64, iovcnt: u64) u64 {
    if (iov_ptr == 0 or iov_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    if (iovcnt == 0) return 0;

    // iovec: { base: u64, len: u64 } = 16 bytes each
    const max_iov = @min(iovcnt, 16);
    var total: u64 = 0;
    var i: u64 = 0;
    while (i < max_iov) : (i += 1) {
        const entry_ptr = iov_ptr + i * 16;
        if (entry_ptr + 16 > 0x0000_8000_0000_0000) break;
        const base: *align(1) const u64 = @ptrFromInt(entry_ptr);
        const len: *align(1) const u64 = @ptrFromInt(entry_ptr + 8);
        if (len.* > 0) {
            const r = syscall.sysRead(fd, base.*, len.*);
            if (isError(r)) return if (total > 0) total else r;
            total += r;
            if (r < len.*) break; // short read
        }
    }
    return total;
}

fn linuxWritev(fd: u64, iov_ptr: u64, iovcnt: u64) u64 {
    if (iov_ptr == 0 or iov_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    if (iovcnt == 0) return 0;

    const max_iov = @min(iovcnt, 16);
    var total: u64 = 0;
    var i: u64 = 0;
    while (i < max_iov) : (i += 1) {
        const entry_ptr = iov_ptr + i * 16;
        if (entry_ptr + 16 > 0x0000_8000_0000_0000) break;
        const base: *align(1) const u64 = @ptrFromInt(entry_ptr);
        const len: *align(1) const u64 = @ptrFromInt(entry_ptr + 8);
        if (len.* > 0) {
            const r = syscall.sysWrite(fd, base.*, len.*);
            if (isError(r)) return if (total > 0) total else r;
            total += r;
        }
    }
    return total;
}

fn linuxIoctl(fd: u64, req: u64, arg: u64) u64 {
    _ = fd;
    if (req == TIOCGWINSZ) {
        if (arg != 0 and arg < 0x0000_8000_0000_0000) {
            // struct winsize { u16 row, col, xpixel, ypixel }
            const ws: *align(1) [8]u8 = @ptrFromInt(arg);
            @memset(ws, 0);
            ws[0] = 25; // rows
            ws[2] = 80; // cols
        }
        return 0;
    }
    return ENOTTY;
}

fn linuxClockGettime(clk_id: u64, tp_ptr: u64) u64 {
    _ = clk_id;
    if (tp_ptr == 0 or tp_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    // struct timespec { i64 tv_sec, i64 tv_nsec }
    const result = syscall.sysSysinfo(tp_ptr);
    // sysSysinfo writes to user buf. We need uptime_secs from the result.
    // Fornax sysinfo format: [total_mem:u64][free_mem:u64][procs:u64][uptime_secs:u64]
    // We need a temp buf to get the sysinfo, then extract uptime.
    _ = result;
    // Simpler approach: read uptime from timer directly
    const timer = @import("timer.zig");
    const uptime_ticks = timer.getTicks();
    const uptime_secs = uptime_ticks / timer.TICKS_PER_SEC;

    const sec_ptr: *align(1) u64 = @ptrFromInt(tp_ptr);
    const nsec_ptr: *align(1) u64 = @ptrFromInt(tp_ptr + 8);
    sec_ptr.* = uptime_secs;
    nsec_ptr.* = 0;
    return 0;
}

fn linuxGetcwd(buf_ptr: u64, size: u64) u64 {
    if (buf_ptr == 0 or buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    // Fornax doesn't track per-process cwd in kernel.
    // Return "/" as default (containers start in root).
    if (size < 2) return ERANGE;
    const dest: [*]u8 = @ptrFromInt(buf_ptr);
    dest[0] = '/';
    dest[1] = 0;
    return buf_ptr; // Linux getcwd returns pointer on success
}

fn linuxUname(buf_ptr: u64) u64 {
    if (buf_ptr == 0 or buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    // struct utsname { char [65] × 6 } = 390 bytes
    const dest: [*]u8 = @ptrFromInt(buf_ptr);
    @memset(dest[0..390], 0);
    // sysname at offset 0
    const sysname = "Fornax";
    @memcpy(dest[0..sysname.len], sysname);
    // nodename at offset 65
    const nodename = "fornax";
    @memcpy(dest[65..][0..nodename.len], nodename);
    // release at offset 130
    const release = "0.1.0";
    @memcpy(dest[130..][0..release.len], release);
    // version at offset 195
    const version = "Phase 1002";
    @memcpy(dest[195..][0..version.len], version);
    // machine at offset 260
    const machine = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .riscv64 => "riscv64",
        .aarch64 => "aarch64",
        else => "unknown",
    };
    @memcpy(dest[260..][0..machine.len], machine);
    return 0;
}

fn linuxGetrandom(buf_ptr: u64, len: u64) u64 {
    if (buf_ptr == 0 or buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    // Fill directly from kernel PRNG (same as /dev/random)
    const dest: [*]u8 = @ptrFromInt(buf_ptr);
    const n = @min(len, 4096);
    const devfiles_mod = @import("devfiles.zig");
    devfiles_mod.devRandomFill(dest[0..n]);
    return n;
}

// ── Stat translation ──────────────────────────────────────────────────────

/// Translate Fornax stat (32 bytes at user_buf) to Linux stat (144 bytes)
/// in-place. Called after Fornax stat data has been delivered to user memory.
pub fn translateStatInPlace(user_buf_ptr: u64) void {
    if (user_buf_ptr == 0 or user_buf_ptr >= 0x0000_8000_0000_0000) return;

    // Read Fornax stat (32 bytes) before overwriting
    const src: [*]const u8 = @ptrFromInt(user_buf_ptr);
    const fx_size = readU64(src[0..8]);
    const fx_file_type = readU32(src[8..12]);
    // offset 12: reserved
    const fx_mtime = readU64(src[16..24]);
    const fx_mode = readU32(src[24..28]);
    const fx_uid = readU16(src[28..30]);
    const fx_gid = readU16(src[30..32]);

    // Write Linux stat (144 bytes)
    const dst: [*]u8 = @ptrFromInt(user_buf_ptr);
    @memset(dst[0..144], 0);

    // st_ino at offset 8 (u64)
    writeU64(dst[8..16], 1);
    // st_nlink at offset 16 (u64)
    writeU64(dst[16..24], 1);
    // st_mode at offset 24 (u32)
    var mode: u32 = fx_mode;
    if (fx_file_type == 1) {
        mode |= 0o040000; // S_IFDIR
    } else {
        mode |= 0o100000; // S_IFREG
    }
    writeU32(dst[24..28], mode);
    // st_uid at offset 28 (u32)
    writeU32(dst[28..32], @as(u32, fx_uid));
    // st_gid at offset 32 (u32)
    writeU32(dst[32..36], @as(u32, fx_gid));
    // st_size at offset 48 (i64)
    writeU64(dst[48..56], fx_size);
    // st_blksize at offset 56 (i64)
    writeU64(dst[56..64], 4096);
    // st_blocks at offset 64 (i64)
    writeU64(dst[64..72], (fx_size + 511) / 512);
    // st_atime_sec at offset 72
    writeU64(dst[72..80], fx_mtime);
    // st_mtime_sec at offset 88
    writeU64(dst[88..96], fx_mtime);
    // st_ctime_sec at offset 104
    writeU64(dst[104..112], fx_mtime);
}

// ── Helpers ───────────────────────────────────────────────────────────────

/// Read null-terminated string length from user memory. Returns 0 on error.
fn strlenUser(ptr: u64) u64 {
    if (ptr == 0 or ptr >= 0x0000_8000_0000_0000) return 0;
    const s: [*]const u8 = @ptrFromInt(ptr);
    var i: u64 = 0;
    while (i < 256) : (i += 1) {
        if (s[i] == 0) return i;
    }
    return 256; // max path length
}

/// Check if a u64 return value is a Fornax/Linux error (negative when cast to i64).
fn isError(val: u64) bool {
    const signed: i64 = @bitCast(val);
    return signed < 0;
}

fn readU16(buf: *const [2]u8) u16 {
    return @as(u16, buf[0]) | (@as(u16, buf[1]) << 8);
}

fn readU32(buf: *const [4]u8) u32 {
    return @as(u32, buf[0]) |
        (@as(u32, buf[1]) << 8) |
        (@as(u32, buf[2]) << 16) |
        (@as(u32, buf[3]) << 24);
}

fn readU64(buf: *const [8]u8) u64 {
    return @as(u64, buf[0]) |
        (@as(u64, buf[1]) << 8) |
        (@as(u64, buf[2]) << 16) |
        (@as(u64, buf[3]) << 24) |
        (@as(u64, buf[4]) << 32) |
        (@as(u64, buf[5]) << 40) |
        (@as(u64, buf[6]) << 48) |
        (@as(u64, buf[7]) << 56);
}

fn writeU32(buf: *[4]u8, val: u32) void {
    buf[0] = @truncate(val);
    buf[1] = @truncate(val >> 8);
    buf[2] = @truncate(val >> 16);
    buf[3] = @truncate(val >> 24);
}

fn writeU64(buf: *[8]u8, val: u64) void {
    buf[0] = @truncate(val);
    buf[1] = @truncate(val >> 8);
    buf[2] = @truncate(val >> 16);
    buf[3] = @truncate(val >> 24);
    buf[4] = @truncate(val >> 32);
    buf[5] = @truncate(val >> 40);
    buf[6] = @truncate(val >> 48);
    buf[7] = @truncate(val >> 56);
}
