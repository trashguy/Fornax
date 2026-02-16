const std = @import("std");
const klog = @import("klog.zig");

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
    // klog.err routes to console.puts which sends to serial first, then framebuffer.
    // Always visible because .err >= any console_level.
    klog.err("\n!!! KERNEL PANIC !!!\n");
    klog.err(msg);
    klog.err("\nSystem halted.\n");
    cpu.halt();
}
