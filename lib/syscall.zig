/// Fornax userspace syscall library.
///
/// Thin wrappers around the Fornax syscall ABI.
/// x86_64:  SYSCALL — RAX=nr, RDI/RSI/RDX/R10/R8=args, return RAX
/// riscv64: ECALL  — A7=nr,  A0/A1/A2/A3/A4=args,      return A0
const arch = @import("builtin").cpu.arch;
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
    exit_sys = 14,
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
    getpid = 26,
    rename = 27,
    truncate = 28,
    wstat = 29,
    setuid = 30,
    getuid = 31,
    mmap = 32,
    munmap = 33,
    dup_fd = 34,
    dup2 = 35,
    arch_prctl = 36,
    clone = 37,
    futex = 38,
    ipc_pair = 39,
};

const ipc = @import("ipc.zig");
pub const IpcMessage = ipc.IpcMessage;
pub const DirEntry = ipc.DirEntry;
pub const Stat = ipc.Stat;
pub const FdMapping = ipc.FdMapping;
pub const T_OPEN = ipc.T_OPEN;
pub const T_READ = ipc.T_READ;
pub const T_WRITE = ipc.T_WRITE;
pub const T_CLOSE = ipc.T_CLOSE;
pub const T_STAT = ipc.T_STAT;
pub const T_CTL = ipc.T_CTL;
pub const T_CREATE = ipc.T_CREATE;
pub const T_REMOVE = ipc.T_REMOVE;
pub const R_OK = ipc.R_OK;
pub const R_ERROR = ipc.R_ERROR;

/// User argv layout base address (one page below stack top).
pub const ARGV_BASE: u64 = 0x0000_7FFF_FFEF_F000;

pub fn write(fd: i32, buf: []const u8) usize {
    return syscall3(.write, @bitCast(@as(i64, fd)), @intFromPtr(buf.ptr), buf.len);
}

pub fn exit(status: u8) noreturn {
    _ = syscall1(.exit_sys, status);
    unreachable;
}

pub fn wait(pid: u32) u64 {
    return syscall2(.wait, pid, 0);
}

pub fn open(path: []const u8) i32 {
    const result = syscall2(.open, @intFromPtr(path.ptr), path.len);
    return @bitCast(@as(u32, @truncate(result)));
}

pub fn read(fd: i32, buf: []u8) isize {
    const result = syscall3(.read, @bitCast(@as(i64, fd)), @intFromPtr(buf.ptr), buf.len);
    return @bitCast(@as(usize, result));
}

pub fn close(fd: i32) i32 {
    const result = syscall1(.close, @bitCast(@as(i64, fd)));
    return @bitCast(@as(u32, @truncate(result)));
}

// Create flags
pub const O_DIR: u32 = 1; // create directory
pub const O_APPEND: u32 = 2; // open at end of file for appending

pub fn create(path: []const u8, flags: u32) i32 {
    const result = syscall3(.create, @intFromPtr(path.ptr), path.len, flags);
    return @bitCast(@as(u32, @truncate(result)));
}

pub fn mkdir(path: []const u8) i32 {
    return create(path, O_DIR);
}

pub fn stat(fd: i32, buf: *Stat) i32 {
    const result = syscall2(.stat, @bitCast(@as(i64, fd)), @intFromPtr(buf));
    return @bitCast(@as(u32, @truncate(result)));
}

pub fn remove(path: []const u8) i32 {
    const result = syscall2(.remove, @intFromPtr(path.ptr), path.len);
    return @bitCast(@as(u32, @truncate(result)));
}

pub fn rename(old_path: []const u8, new_path: []const u8) i32 {
    const result = syscall4(.rename, @intFromPtr(old_path.ptr), old_path.len, @intFromPtr(new_path.ptr), new_path.len);
    return @bitCast(@as(u32, @truncate(result)));
}

pub fn truncate(fd: i32, size: u64) i32 {
    const result = syscall2(.truncate, @bitCast(@as(i64, fd)), size);
    return @bitCast(@as(u32, @truncate(result)));
}

// wstat mask bits
pub const WSTAT_MODE: u32 = 0x1;
pub const WSTAT_UID: u32 = 0x2;
pub const WSTAT_GID: u32 = 0x4;

pub fn wstat(fd: i32, mode: u16, uid: u16, gid: u16, mask: u32) i32 {
    const result = syscall5(.wstat, @bitCast(@as(i64, fd)), mode, uid, gid, mask);
    return @bitCast(@as(u32, @truncate(result)));
}

/// Mount an IPC channel fd at the given path in the current namespace.
pub fn mount(fd: i32, path: []const u8, flags: u32) i32 {
    const result = syscall4(.mount, @bitCast(@as(i64, fd)), @intFromPtr(path.ptr), path.len, flags);
    return @bitCast(@as(u32, @truncate(result)));
}

/// Bind (same as mount in Fornax).
pub fn bind(fd: i32, path: []const u8, flags: u32) i32 {
    const result = syscall4(.bind, @bitCast(@as(i64, fd)), @intFromPtr(path.ptr), path.len, flags);
    return @bitCast(@as(u32, @truncate(result)));
}

/// Unmount a path from the current namespace.
pub fn unmount(path: []const u8) i32 {
    const result = syscall2(.unmount, @intFromPtr(path.ptr), path.len);
    return @bitCast(@as(u32, @truncate(result)));
}

/// Create an IPC channel pair. Returns { server_fd, client_fd, err }.
pub fn ipc_pair() struct { server_fd: i32, client_fd: i32, err: i32 } {
    var result: [2]i32 = undefined;
    const rc = syscall1(.ipc_pair, @intFromPtr(&result));
    const err: i32 = @bitCast(@as(u32, @truncate(rc)));
    if (err < 0) return .{ .server_fd = -1, .client_fd = -1, .err = err };
    return .{ .server_fd = result[0], .client_fd = result[1], .err = 0 };
}

pub fn brk(new_brk: u64) u64 {
    return syscall1(.brk, new_brk);
}

pub fn ipc_recv(fd: i32, msg: *IpcMessage) i32 {
    const result = syscall2(.ipc_recv, @bitCast(@as(i64, fd)), @intFromPtr(msg));
    return @bitCast(@as(u32, @truncate(result)));
}

pub fn ipc_reply(fd: i32, msg: *IpcMessage) i32 {
    const result = syscall2(.ipc_reply, @bitCast(@as(i64, fd)), @intFromPtr(msg));
    return @bitCast(@as(u32, @truncate(result)));
}

pub fn spawn(elf_data: []const u8, fd_map: []const FdMapping, argv_block: ?[]const u8) i32 {
    const argv_ptr: u64 = if (argv_block) |blk| @intFromPtr(blk.ptr) else 0;
    const result = syscall5(.spawn, @intFromPtr(elf_data.ptr), elf_data.len, @intFromPtr(fd_map.ptr), fd_map.len, argv_ptr);
    return @bitCast(@as(u32, @truncate(result)));
}

pub fn exec(elf_data: []const u8) i32 {
    const result = syscall2(.exec, @intFromPtr(elf_data.ptr), elf_data.len);
    return @bitCast(@as(u32, @truncate(result)));
}

pub fn pipe() struct { read_fd: i32, write_fd: i32, err: i32 } {
    var fds: [2]u32 = undefined;
    const result = syscall1(.pipe, @intFromPtr(&fds));
    if (result != 0) return .{ .read_fd = -1, .write_fd = -1, .err = @bitCast(@as(u32, @truncate(result))) };
    return .{ .read_fd = @bitCast(fds[0]), .write_fd = @bitCast(fds[1]), .err = 0 };
}

pub fn pread(fd: i32, buf: []u8, offset: u64) isize {
    const result = syscall4(.pread, @bitCast(@as(i64, fd)), @intFromPtr(buf.ptr), buf.len, offset);
    return @bitCast(@as(usize, result));
}

pub fn pwrite(fd: i32, buf: []const u8, offset: u64) isize {
    const result = syscall4(.pwrite, @bitCast(@as(i64, fd)), @intFromPtr(buf.ptr), buf.len, offset);
    return @bitCast(@as(usize, result));
}

pub fn klog(buf: []u8, offset: u64) usize {
    return syscall3(.klog, @intFromPtr(buf.ptr), buf.len, offset);
}

pub const SysInfo = extern struct {
    total_pages: u64,
    free_pages: u64,
    page_size: u64,
    uptime_secs: u64,
};

pub fn sysinfo() ?SysInfo {
    var buf: [4]u64 = undefined;
    const result = syscall1(.sysinfo, @intFromPtr(&buf));
    if (result != 0) return null;
    return .{ .total_pages = buf[0], .free_pages = buf[1], .page_size = buf[2], .uptime_secs = buf[3] };
}

pub fn sleep(ms: u64) void {
    _ = syscall1(.sleep, ms);
}

pub fn shutdown() noreturn {
    _ = syscall1(.shutdown, 0);
    unreachable;
}

pub fn reboot() noreturn {
    _ = syscall1(.shutdown, 1);
    unreachable;
}

pub fn seek(fd: i32, offset: u64, whence: u32) i64 {
    const result = syscall3(.seek, @bitCast(@as(i64, fd)), offset, whence);
    return @bitCast(result);
}

pub fn getpid() u32 {
    return @truncate(syscall1(.getpid, 0));
}

pub fn setuid(uid: u16, gid: u16) i32 {
    const result = syscall2(.setuid, uid, gid);
    return @bitCast(@as(u32, @truncate(result)));
}

pub fn getuid() u16 {
    return @truncate(syscall1(.getuid, 0));
}

pub fn getgid() u16 {
    return @truncate(syscall1(.getuid, 0) >> 16);
}

pub fn mmap(addr: u64, length: u64, prot: u64, flags: u64) u64 {
    return syscall4(.mmap, addr, length, prot, flags);
}

pub fn munmap(addr: u64, length: u64) u64 {
    return syscall2(.munmap, addr, length);
}

pub fn dup(fd: i32) i32 {
    const result = syscall1(.dup_fd, @bitCast(@as(i64, fd)));
    return @bitCast(@as(i64, @bitCast(result)));
}

pub fn dup2(old_fd: i32, new_fd: i32) i32 {
    const result = syscall2(.dup2, @bitCast(@as(i64, old_fd)), @bitCast(@as(i64, new_fd)));
    return @bitCast(@as(i64, @bitCast(result)));
}

pub fn arch_prctl(cmd: u64, addr: u64) u64 {
    return syscall2(.arch_prctl, cmd, addr);
}

pub fn rfork(flags: u64) u64 {
    return syscall1(.rfork, flags);
}

pub fn clone(stack_top: u64, tls: u64, ctid_ptr: u64, ptid_ptr: u64, flags: u64) u64 {
    return syscall5(.clone, stack_top, tls, ctid_ptr, ptid_ptr, flags);
}

pub fn futex(addr: u64, op: u64, val: u64, timeout: u64) u64 {
    return syscall4(.futex, addr, op, val, timeout);
}

pub const RFNAMEG: u64 = 0x08;

// rfork flags (Plan 9)
pub const RFPROC: u64 = 0x01; // create new process
pub const RFFDG: u64 = 0x02; // copy fd table to child
pub const RFCFDG: u64 = 0x04; // child gets clean fd table
pub const RFMEM: u64 = 0x10; // share memory with parent
pub const RFNOWAIT: u64 = 0x20; // child auto-reaps (no wait needed)

/// Build a serialized argv block: [argc: u32][total_len: u32][str0\0str1\0...]
pub fn buildArgvBlock(buf: []u8, args: []const []const u8) ?[]const u8 {
    if (args.len == 0) return null;
    if (buf.len < 8) return null;

    // Write argc
    const argc: u32 = @intCast(args.len);
    buf[0] = @truncate(argc);
    buf[1] = @truncate(argc >> 8);
    buf[2] = @truncate(argc >> 16);
    buf[3] = @truncate(argc >> 24);

    // Write strings with null terminators
    var pos: usize = 8;
    for (args) |arg| {
        if (pos + arg.len + 1 > buf.len) return null;
        @memcpy(buf[pos..][0..arg.len], arg);
        buf[pos + arg.len] = 0;
        pos += arg.len + 1;
    }

    // Write total string data length
    const total: u32 = @intCast(pos - 8);
    buf[4] = @truncate(total);
    buf[5] = @truncate(total >> 8);
    buf[6] = @truncate(total >> 16);
    buf[7] = @truncate(total >> 24);

    return buf[0..pos];
}

/// Get argc from the argv layout at ARGV_BASE.
pub fn getArgc() usize {
    const ptr: *const u64 = @ptrFromInt(ARGV_BASE);
    return @intCast(ptr.*);
}

/// Get the argv pointer array from the argv layout at ARGV_BASE.
pub fn getArgs() []const [*:0]const u8 {
    const argc = getArgc();
    if (argc == 0) return &.{};
    const argv_ptr: [*]const [*:0]const u8 = @ptrFromInt(ARGV_BASE + 8);
    return argv_ptr[0..argc];
}

/// Read wall-clock epoch seconds from /dev/time.
pub fn time() u64 {
    return readTimeField(0);
}

/// Read uptime seconds from /dev/time.
pub fn getUptime() u64 {
    return readTimeField(1);
}

fn readTimeField(field: usize) u64 {
    const fd_raw = open("/dev/time");
    if (fd_raw < 0) return 0;
    const fd: i32 = @intCast(fd_raw);
    var buf: [64]u8 = undefined;
    const n = read(fd, &buf);
    _ = close(fd);
    if (n <= 0) return 0;
    const text = buf[0..@as(usize, @intCast(n))];
    // Parse space-separated fields: "<epoch> <uptime>\n"
    var start: usize = 0;
    var idx: usize = 0;
    for (text, 0..) |c, i| {
        if (c == ' ' or c == '\n') {
            if (idx == field) {
                return parseU64(text[start..i]);
            }
            idx += 1;
            start = i + 1;
        }
    }
    if (idx == field and start < text.len) {
        return parseU64(text[start..]);
    }
    return 0;
}

fn parseU64(s: []const u8) u64 {
    var result: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') break;
        result = result *% 10 +% (c - '0');
    }
    return result;
}

fn syscall1(nr: SYS, a0: u64) u64 {
    return switch (arch) {
        .x86_64 => asm volatile ("syscall"
            : [ret] "={rax}" (-> u64),
            : [nr] "{rax}" (@intFromEnum(nr)),
              [a0] "{rdi}" (a0),
            : .{ .rcx = true, .r11 = true, .memory = true }),
        .riscv64 => asm volatile ("ecall"
            : [ret] "={a0}" (-> u64),
            : [nr] "{a7}" (@intFromEnum(nr)),
              [a0] "{a0}" (a0),
            : .{ .memory = true }),
        else => @compileError("unsupported arch for syscall"),
    };
}

fn syscall2(nr: SYS, a0: u64, a1: u64) u64 {
    return switch (arch) {
        .x86_64 => asm volatile ("syscall"
            : [ret] "={rax}" (-> u64),
            : [nr] "{rax}" (@intFromEnum(nr)),
              [a0] "{rdi}" (a0),
              [a1] "{rsi}" (a1),
            : .{ .rcx = true, .r11 = true, .memory = true }),
        .riscv64 => asm volatile ("ecall"
            : [ret] "={a0}" (-> u64),
            : [nr] "{a7}" (@intFromEnum(nr)),
              [a0] "{a0}" (a0),
              [a1] "{a1}" (a1),
            : .{ .memory = true }),
        else => @compileError("unsupported arch for syscall"),
    };
}

fn syscall3(nr: SYS, a0: u64, a1: u64, a2: u64) u64 {
    return switch (arch) {
        .x86_64 => asm volatile ("syscall"
            : [ret] "={rax}" (-> u64),
            : [nr] "{rax}" (@intFromEnum(nr)),
              [a0] "{rdi}" (a0),
              [a1] "{rsi}" (a1),
              [a2] "{rdx}" (a2),
            : .{ .rcx = true, .r11 = true, .memory = true }),
        .riscv64 => asm volatile ("ecall"
            : [ret] "={a0}" (-> u64),
            : [nr] "{a7}" (@intFromEnum(nr)),
              [a0] "{a0}" (a0),
              [a1] "{a1}" (a1),
              [a2] "{a2}" (a2),
            : .{ .memory = true }),
        else => @compileError("unsupported arch for syscall"),
    };
}

fn syscall4(nr: SYS, a0: u64, a1: u64, a2: u64, a3: u64) u64 {
    return switch (arch) {
        .x86_64 => asm volatile ("syscall"
            : [ret] "={rax}" (-> u64),
            : [nr] "{rax}" (@intFromEnum(nr)),
              [a0] "{rdi}" (a0),
              [a1] "{rsi}" (a1),
              [a2] "{rdx}" (a2),
              [a3] "{r10}" (a3),
            : .{ .rcx = true, .r11 = true, .memory = true }),
        .riscv64 => asm volatile ("ecall"
            : [ret] "={a0}" (-> u64),
            : [nr] "{a7}" (@intFromEnum(nr)),
              [a0] "{a0}" (a0),
              [a1] "{a1}" (a1),
              [a2] "{a2}" (a2),
              [a3] "{a3}" (a3),
            : .{ .memory = true }),
        else => @compileError("unsupported arch for syscall"),
    };
}

fn syscall5(nr: SYS, a0: u64, a1: u64, a2: u64, a3: u64, a4: u64) u64 {
    return switch (arch) {
        .x86_64 => asm volatile ("syscall"
            : [ret] "={rax}" (-> u64),
            : [nr] "{rax}" (@intFromEnum(nr)),
              [a0] "{rdi}" (a0),
              [a1] "{rsi}" (a1),
              [a2] "{rdx}" (a2),
              [a3] "{r10}" (a3),
              [a4] "{r8}" (a4),
            : .{ .rcx = true, .r11 = true, .memory = true }),
        .riscv64 => asm volatile ("ecall"
            : [ret] "={a0}" (-> u64),
            : [nr] "{a7}" (@intFromEnum(nr)),
              [a0] "{a0}" (a0),
              [a1] "{a1}" (a1),
              [a2] "{a2}" (a2),
              [a3] "{a3}" (a3),
              [a4] "{a4}" (a4),
            : .{ .memory = true }),
        else => @compileError("unsupported arch for syscall"),
    };
}

