/// Fornax Plan 9-inspired syscall interface.
///
/// Syscall numbers — NOT Linux-compatible. Fornax has its own ABI.
/// Convention: RAX=nr, RDI=a0, RSI=a1, RDX=a2, R10=a3, R8=a4
const std = @import("std");
const console = @import("console.zig");
const serial = @import("serial.zig");

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
};

/// Error return value — signals error to userspace.
/// Negative values indicate errors (user checks if result > max_valid).
const ENOSYS: u64 = @bitCast(@as(i64, -1));
const EBADF: u64 = @bitCast(@as(i64, -9));
const EFAULT: u64 = @bitCast(@as(i64, -14));

/// Main syscall dispatch. Called from arch-specific entry point.
pub fn dispatch(nr: u64, arg0: u64, arg1: u64, arg2: u64, _: u64, _: u64) u64 {
    const sys = std.meta.intToEnum(SYS, nr) catch {
        serial.puts("syscall: unknown nr=");
        serial.putDec(nr);
        serial.puts("\n");
        return ENOSYS;
    };

    return switch (sys) {
        .write => sysWrite(arg0, arg1, arg2),
        .exit => sysExit(arg0),
        .open, .create, .read, .close, .stat, .seek, .remove => {
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
/// For Milestone 1: fd 1/2 → framebuffer console + serial.
fn sysWrite(fd: u64, buf_ptr: u64, count: u64) u64 {
    // Only support stdout (1) and stderr (2) for now
    if (fd != 1 and fd != 2) return EBADF;

    // Basic validation: buf_ptr should be in user space (< 0x0000_8000_0000_0000)
    if (buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    if (count == 0) return 0;

    const buf: [*]const u8 = @ptrFromInt(buf_ptr);
    const len: usize = @intCast(@min(count, 4096));

    console.puts(buf[0..len]);

    return len;
}

/// exit(status) — noreturn from userspace perspective.
/// For Milestone 1: just print and halt.
fn sysExit(status: u64) noreturn {
    console.puts("\n[Process exited with status ");
    console.putDec(status);
    console.puts("]\n");

    // For now, halt the system. Later: schedule next process.
    const cpu = switch (@import("builtin").cpu.arch) {
        .x86_64 => @import("arch/x86_64/cpu.zig"),
        else => struct {
            pub fn halt() noreturn {
                while (true) {}
            }
        },
    };
    cpu.halt();
}
