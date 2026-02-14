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
};

pub fn write(fd: i32, buf: []const u8) usize {
    return syscall3(.write, @bitCast(@as(i64, fd)), @intFromPtr(buf.ptr), buf.len);
}

pub fn exit(status: u8) noreturn {
    _ = syscall1(.exit_sys, status);
    unreachable;
}

fn syscall1(nr: SYS, a0: u64) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [nr] "{rax}" (@intFromEnum(nr)),
          [a0] "{rdi}" (a0),
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
