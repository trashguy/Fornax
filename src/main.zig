const std = @import("std");
const uefi = std.os.uefi;

const boot = @import("boot.zig");
const console = @import("console.zig");
const pmm = @import("pmm.zig");
const serial = @import("serial.zig");
const heap = @import("heap.zig");
const ipc = @import("ipc.zig");
const process = @import("process.zig");
const supervisor = @import("supervisor.zig");
const container = @import("container.zig");
const virtio_net = @import("virtio_net.zig");
const net = @import("net.zig");
const panic_handler = @import("panic.zig");

const cpu = switch (@import("builtin").cpu.arch) {
    .x86_64 => @import("arch/x86_64/cpu.zig"),
    .aarch64 => @import("arch/aarch64/cpu.zig"),
    else => @compileError("unsupported architecture"),
};

const arch = switch (@import("builtin").cpu.arch) {
    .x86_64 => @import("arch/x86_64/interrupts.zig"),
    .aarch64 => @import("arch/aarch64/exceptions.zig"),
    else => @compileError("unsupported architecture"),
};

pub const panic = panic_handler.panic;

pub fn main() noreturn {
    // Phase 1: UEFI text output
    const con_out = uefi.system_table.con_out orelse halt();
    con_out.clearScreen() catch {};
    puts16(con_out, L("Fornax booting...\r\n"));

    // Phase 2: GOP framebuffer + exit boot services
    const boot_info = boot.init() catch |err| {
        puts16(con_out, L("Boot init failed: "));
        puts16(con_out, boot.errorName(err));
        puts16(con_out, L("\r\n"));
        halt();
    };

    // Serial console — init before framebuffer so we get early output
    serial.init();

    // Now we have a framebuffer — switch to graphical console
    console.init(boot_info.framebuffer);
    console.puts("Fornax booting...\n");

    // Phase 3: Physical memory manager
    pmm.init(boot_info.memory_map) catch {
        console.puts("PMM init failed!\n");
        halt();
    };

    // Phase 7: Kernel heap
    heap.init();

    // Phase 4/5: Architecture-specific init (GDT/IDT/paging)
    arch.init();
    console.puts("Architecture init complete.\n");

    // Phase 9: IPC
    ipc.init();

    // Phase 10: Process manager
    process.init();

    // Architecture-specific: SYSCALL setup
    if (@import("builtin").cpu.arch == .x86_64) {
        const syscall_entry = @import("arch/x86_64/syscall_entry.zig");
        syscall_entry.init();
    }

    // Phase 13: Fault supervisor
    supervisor.init();

    // Phase 14: Containers
    container.init();

    // Phase 15: PCI + virtio-net
    if (@import("builtin").cpu.arch == .x86_64) {
        const pci_mod = @import("arch/x86_64/pci.zig");
        pci_mod.enumerate();
        if (virtio_net.init()) {
            console.puts("Network ready.\n");
        }
    }

    // Phase 16: IP stack
    net.init();

    console.puts("Kernel initialized. No userspace yet.\n");

    // Start the scheduler — with no processes spawned, this will
    // print "All processes exited" and halt.
    process.scheduleNext();
}

fn halt() noreturn {
    cpu.halt();
}

/// Convert a comptime ASCII string literal to a UEFI UTF-16 null-terminated string.
fn L(comptime ascii: []const u8) *const [ascii.len:0]u16 {
    const S = struct {
        const value = blk: {
            var buf: [ascii.len:0]u16 = undefined;
            for (0..ascii.len) |i| {
                buf[i] = ascii[i];
            }
            buf[ascii.len] = 0;
            break :blk buf;
        };
    };
    return &S.value;
}

fn puts16(con_out: *uefi.protocol.SimpleTextOutput, msg: [*:0]const u16) void {
    _ = con_out.outputString(msg) catch {};
}
