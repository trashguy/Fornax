const std = @import("std");
const uefi = std.os.uefi;

const boot = @import("boot.zig");
const console = @import("console.zig");
const pmm = @import("pmm.zig");
const serial = @import("serial.zig");
const heap = @import("heap.zig");
const ipc = @import("ipc.zig");
const process = @import("process.zig");
const elf = @import("elf.zig");
const supervisor = @import("supervisor.zig");
const container = @import("container.zig");
const virtio_net = @import("virtio_net.zig");
const net = @import("net.zig");
const panic_handler = @import("panic.zig");

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

    // Register console server for supervision
    if (@import("builtin").cpu.arch == .x86_64) {
        const console_elf = @embedFile("user_console_elf");
        if (supervisor.register("console", console_elf, "/dev/console")) |svc| {
            _ = svc;
            console.puts("Console server registered for supervision\n");
        }
    }

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

    // ── Milestone 1: Load and run user hello program ────────────────
    launchUserHello();

    // Network poll loop — process packets while idle
    if (net.isInitialized()) {
        console.puts("\nFornax ready. Polling network...\n");
        while (true) {
            net.poll();
        }
    }

    console.puts("\nFornax ready. Halting.\n");
    halt();
}

fn launchUserHello() void {
    if (@import("builtin").cpu.arch != .x86_64) {
        console.puts("User mode not yet supported on this architecture.\n");
        return;
    }

    const paging = @import("arch/x86_64/paging.zig");
    const syscall_entry = @import("arch/x86_64/syscall_entry.zig");
    const gdt = @import("arch/x86_64/gdt.zig");
    const mem = @import("mem.zig");

    // Embedded user binary
    const user_elf = @embedFile("user_hello_elf");
    console.puts("Loading user hello (");
    console.putDec(user_elf.len);
    console.puts(" bytes)...\n");

    // Create process
    const proc = process.create() orelse {
        console.puts("Failed to create process!\n");
        return;
    };

    // Load ELF into process address space
    const load_result = elf.load(proc.pml4.?, user_elf) catch |err| {
        console.puts("ELF load failed: ");
        console.puts(switch (err) {
            elf.LoadError.InvalidMagic => "invalid magic",
            elf.LoadError.Not64Bit => "not 64-bit",
            elf.LoadError.NotExecutable => "not executable",
            elf.LoadError.WrongArch => "wrong arch",
            elf.LoadError.NoSegments => "no segments",
            elf.LoadError.OutOfMemory => "out of memory",
        });
        console.puts("\n");
        return;
    };

    console.puts("ELF loaded. Entry: ");
    console.putHex(load_result.entry_point);
    console.puts("\n");

    proc.user_rip = load_result.entry_point;
    proc.brk = load_result.brk;

    // Allocate user stack (one page at USER_STACK_TOP - PAGE_SIZE)
    const user_stack_phys = pmm.allocPage() orelse {
        console.puts("Failed to allocate user stack!\n");
        return;
    };
    // Zero the stack page
    const stack_ptr: [*]u8 = @ptrFromInt(user_stack_phys);
    @memset(stack_ptr[0..mem.PAGE_SIZE], 0);

    const user_stack_virt = mem.USER_STACK_TOP - mem.PAGE_SIZE;
    paging.mapPage(proc.pml4.?, user_stack_virt, user_stack_phys, paging.Flags.WRITABLE | paging.Flags.USER) orelse {
        console.puts("Failed to map user stack!\n");
        return;
    };
    proc.user_rsp = mem.USER_STACK_TOP; // stack grows down

    // Set kernel stack for syscall entry
    syscall_entry.setKernelStack(proc.kernel_stack_top);
    gdt.setKernelStack(proc.kernel_stack_top);

    console.puts("Entering Ring 3...\n");

    // Jump to user mode via IRETQ
    // Stack frame: SS, RSP, RFLAGS, CS, RIP
    jumpToUserMode(proc.user_rip, proc.user_rsp);
}

fn jumpToUserMode(rip: u64, rsp: u64) noreturn {
    const gdt = @import("arch/x86_64/gdt.zig");
    asm volatile (
        \\push %[ss]       // SS
        \\push %[rsp]      // RSP
        \\push %[rflags]   // RFLAGS (IF=1 to enable interrupts)
        \\push %[cs]       // CS
        \\push %[rip]      // RIP
        \\iretq
        :
        : [ss] "r" (@as(u64, gdt.USER_DS)),
          [rsp] "r" (rsp),
          [rflags] "r" (@as(u64, 0x202)), // IF=1
          [cs] "r" (@as(u64, gdt.USER_CS)),
          [rip] "r" (rip),
    );
    unreachable;
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
