/// Fornax userspace syscall library.
///
/// Thin wrappers around the Fornax syscall ABI.
/// Convention: RAX=nr, RDI=a0, RSI=a1, RDX=a2, R10=a3, R8=a4
/// Returns: RAX
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
};

/// IPC message structure for user-space (matches kernel layout).
/// Layout: tag(u32) + data_len(u32) + data([4096]u8) = 4104 bytes.
pub const IpcMessage = extern struct {
    tag: u32,
    data_len: u32,
    data: [4096]u8,

    pub fn init(tag: u32) IpcMessage {
        return .{ .tag = tag, .data_len = 0, .data = undefined };
    }

    pub fn initWithData(tag: u32, payload: []const u8) IpcMessage {
        var msg = IpcMessage.init(tag);
        const len: u32 = @intCast(@min(payload.len, 4096));
        @memcpy(msg.data[0..len], payload[0..len]);
        msg.data_len = len;
        return msg;
    }

    pub fn getData(self: *const IpcMessage) []const u8 {
        return self.data[0..self.data_len];
    }
};

/// IPC message tags (matching kernel ipc.Tag values).
pub const T_OPEN: u32 = 1;
pub const T_READ: u32 = 2;
pub const T_WRITE: u32 = 3;
pub const T_CLOSE: u32 = 4;
pub const T_STAT: u32 = 5;
pub const T_CTL: u32 = 6;
pub const T_CREATE: u32 = 7;
pub const T_REMOVE: u32 = 8;
pub const R_OK: u32 = 128;
pub const R_ERROR: u32 = 129;

/// Directory entry returned by reading a directory handle.
pub const DirEntry = extern struct {
    name: [64]u8, // null-terminated
    file_type: u32, // 0=file, 1=directory
    size: u32, // file size
};

/// File stat information.
pub const Stat = extern struct {
    size: u32,
    file_type: u32, // 0=file, 1=directory
    _reserved: [56]u8,
};

/// FD mapping for spawn: maps a parent fd to a child fd slot.
pub const FdMapping = extern struct {
    child_fd: u32,
    parent_fd: u32,
};

pub fn write(fd: i32, buf: []const u8) usize {
    return syscall3(.write, @bitCast(@as(i64, fd)), @intFromPtr(buf.ptr), buf.len);
}

pub fn exit(status: u8) noreturn {
    _ = syscall1(.exit_sys, status);
    unreachable;
}

/// Wait for a child process to exit. Returns exit status.
/// pid=0: wait for any child. pid>0: wait for specific child.
pub fn wait(pid: u32) u64 {
    return syscall1(.wait, pid);
}

/// open(path) → fd or negative error.
pub fn open(path: []const u8) i32 {
    const result = syscall2(.open, @intFromPtr(path.ptr), path.len);
    return @bitCast(@as(u32, @truncate(result)));
}

/// read(fd, buf) → bytes read or negative error.
pub fn read(fd: i32, buf: []u8) isize {
    const result = syscall3(.read, @bitCast(@as(i64, fd)), @intFromPtr(buf.ptr), buf.len);
    return @bitCast(@as(usize, result));
}

/// close(fd) → 0 or negative error.
pub fn close(fd: i32) i32 {
    const result = syscall1(.close, @bitCast(@as(i64, fd)));
    return @bitCast(@as(u32, @truncate(result)));
}

/// create(path, flags) → fd or negative error.
/// Creates a file (or directory if flags bit 0 is set) at the given path.
pub fn create(path: []const u8, flags: u32) i32 {
    const result = syscall3(.create, @intFromPtr(path.ptr), path.len, flags);
    return @bitCast(@as(u32, @truncate(result)));
}

/// mkdir(path) → fd or negative error.
/// Convenience wrapper: creates a directory.
pub fn mkdir(path: []const u8) i32 {
    return create(path, 1); // flags bit 0 = directory
}

/// Receive an IPC message on a server channel fd.
/// Blocks until a message arrives.
pub fn ipc_recv(fd: i32, msg: *IpcMessage) i32 {
    const result = syscall2(.ipc_recv, @bitCast(@as(i64, fd)), @intFromPtr(msg));
    return @bitCast(@as(u32, @truncate(result)));
}

/// Send an IPC reply on a server channel fd.
pub fn ipc_reply(fd: i32, msg: *IpcMessage) i32 {
    const result = syscall2(.ipc_reply, @bitCast(@as(i64, fd)), @intFromPtr(msg));
    return @bitCast(@as(u32, @truncate(result)));
}

/// spawn(elf_data, fd_map) → child pid or negative error.
/// Creates a new process from ELF bytes with the given FD mappings.
pub fn spawn(elf_data: []const u8, fd_map: []const FdMapping) i32 {
    const result = syscall4(.spawn, @intFromPtr(elf_data.ptr), elf_data.len, @intFromPtr(fd_map.ptr), fd_map.len);
    return @bitCast(@as(u32, @truncate(result)));
}

pub fn exec(elf_data: []const u8) i32 {
    const result = syscall2(.exec, @intFromPtr(elf_data.ptr), elf_data.len);
    return @bitCast(@as(u32, @truncate(result)));
}

fn syscall1(nr: SYS, a0: u64) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [nr] "{rax}" (@intFromEnum(nr)),
          [a0] "{rdi}" (a0),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

fn syscall2(nr: SYS, a0: u64, a1: u64) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [nr] "{rax}" (@intFromEnum(nr)),
          [a0] "{rdi}" (a0),
          [a1] "{rsi}" (a1),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

fn syscall3(nr: SYS, a0: u64, a1: u64, a2: u64) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [nr] "{rax}" (@intFromEnum(nr)),
          [a0] "{rdi}" (a0),
          [a1] "{rsi}" (a1),
          [a2] "{rdx}" (a2),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

fn syscall4(nr: SYS, a0: u64, a1: u64, a2: u64, a3: u64) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [nr] "{rax}" (@intFromEnum(nr)),
          [a0] "{rdi}" (a0),
          [a1] "{rsi}" (a1),
          [a2] "{rdx}" (a2),
          [a3] "{r10}" (a3),
        : .{ .rcx = true, .r11 = true, .memory = true });
}
