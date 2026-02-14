const std = @import("std");
const console = @import("console.zig");
const serial = @import("serial.zig");

const cpu = switch (@import("builtin").cpu.arch) {
    .x86_64 => @import("arch/x86_64/cpu.zig"),
    .aarch64 => @import("arch/aarch64/cpu.zig"),
    else => struct {
        pub fn halt() noreturn {
            while (true) {}
        }
    },
};

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    // Serial gets priority in case framebuffer is broken
    serial.puts("\n!!! KERNEL PANIC !!!\n");
    serial.puts(msg);
    serial.puts("\nSystem halted.\n");
    console.puts("\n!!! KERNEL PANIC !!!\n");
    console.puts(msg);
    console.puts("\nSystem halted.\n");
    cpu.halt();
}
