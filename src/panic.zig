const std = @import("std");
const console = @import("console.zig");
const serial = @import("serial.zig");

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    // Serial gets priority in case framebuffer is broken
    serial.puts("\n!!! KERNEL PANIC !!!\n");
    serial.puts(msg);
    serial.puts("\nSystem halted.\n");
    console.puts("\n!!! KERNEL PANIC !!!\n");
    console.puts(msg);
    console.puts("\nSystem halted.\n");
    halt();
}

fn halt() noreturn {
    switch (@import("builtin").cpu.arch) {
        .x86_64 => while (true) {
            asm volatile ("cli");
            asm volatile ("hlt");
        },
        .aarch64 => while (true) {
            asm volatile ("wfi");
        },
        else => while (true) {},
    }
}
