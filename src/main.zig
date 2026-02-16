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
const virtio_blk = @import("virtio_blk.zig");
const net = @import("net.zig");
const initrd = @import("initrd.zig");
const elf = @import("elf.zig");
const mem = @import("mem.zig");
const namespace = @import("namespace.zig");
const panic_handler = @import("panic.zig");

const paging = switch (@import("builtin").cpu.arch) {
    .x86_64 => @import("arch/x86_64/paging.zig"),
    else => struct {
        pub fn mapPage(_: anytype, _: u64, _: u64, _: u64) ?void {}
        pub const Flags = struct {
            pub const WRITABLE: u64 = 0;
            pub const USER: u64 = 0;
        };
        pub inline fn physPtr(phys: u64) [*]u8 {
            return @ptrFromInt(phys);
        }
    },
};

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

    // Phase 23: PIC initialization (remap IRQs before any device init)
    const pic_mod = @import("pic.zig");
    pic_mod.init();

    // Phase 23: Serial console input (COM1 IRQ 4)
    serial.enableRxInterrupt();

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

        // Phase 300: Virtio-blk
        if (virtio_blk.init()) {
            console.puts("Block device ready.\n");

            // Phase 305: GPT partition table
            const gpt = @import("gpt.zig");
            if (gpt.init()) {
                console.puts("GPT partition table loaded.\n");
            }
        }

        // Phase 23: Virtio-input (keyboard)
        const virtio_input = @import("virtio_input.zig");
        if (!virtio_input.init()) {
            console.puts("No keyboard device found.\n");
        }
    }

    // Phase 100: Timer tick counter (for TCP retransmission)
    const timer = @import("timer.zig");
    timer.init();

    // Phase 16+100: IP stack + TCP/DNS
    net.init();

    // Phase 20: Initrd
    _ = initrd.init(boot_info.initrd_base, boot_info.initrd_size);

    // Phase 21: Mount initrd files at /boot/ and spawn init
    initrd.mountFiles();
    spawnRamfs();
    spawnPartfs();
    spawnFxfs();
    spawnInit();

    console.puts("Kernel initialized.\n");

    // Start the scheduler — runs init (PID 1) if spawned, else halts.
    process.scheduleNext();
}

/// Spawn ramfs server from the initrd. Creates a channel mounted at "/" in the
/// root namespace. Ramfs serves the root filesystem via IPC.
fn spawnRamfs() void {
    const ramfs_elf = initrd.findFile("ramfs") orelse {
        console.puts("No ramfs in initrd — running without root filesystem.\n");
        return;
    };

    const proc = process.create() orelse {
        console.puts("Failed to create ramfs process!\n");
        return;
    };

    // Load ELF into ramfs's address space
    const load_result = elf.load(proc.pml4.?, ramfs_elf) catch {
        console.puts("Failed to load ramfs ELF!\n");
        proc.state = .dead;
        return;
    };

    proc.user_rip = load_result.entry_point;
    proc.brk = load_result.brk;

    // Allocate user stack
    for (0..process.USER_STACK_PAGES) |i| {
        const page = pmm.allocPage() orelse {
            console.puts("Failed to allocate ramfs stack!\n");
            proc.state = .dead;
            return;
        };
        const ptr: [*]u8 = paging.physPtr(page);
        @memset(ptr[0..mem.PAGE_SIZE], 0);
        const vaddr = mem.USER_STACK_TOP - (process.USER_STACK_PAGES - i) * mem.PAGE_SIZE;
        paging.mapPage(proc.pml4.?, vaddr, page, paging.Flags.WRITABLE | paging.Flags.USER) orelse {
            console.puts("Failed to map ramfs stack!\n");
            proc.state = .dead;
            return;
        };
    }
    proc.user_rsp = mem.USER_STACK_INIT;

    // Create IPC channel for ramfs
    const chan = ipc.channelCreate() catch {
        console.puts("Failed to create ramfs channel!\n");
        proc.state = .dead;
        return;
    };

    // Server end as fd 3
    proc.setFd(3, chan.server, true);

    // Mount client end at "/" in the root namespace
    const root_ns = namespace.getRootNamespace();
    root_ns.mount("/", chan.client, .{ .replace = true }) catch {
        console.puts("Failed to mount ramfs at /!\n");
        proc.state = .dead;
        return;
    };

    // Ramfs has no parent (kernel-spawned)
    proc.parent_pid = null;
    root_ns.cloneInto(&proc.ns);

    serial.puts("[ramfs: pid=");
    serial.putDec(proc.pid);
    serial.puts(" entry=0x");
    serial.putHex(load_result.entry_point);
    serial.puts("]\n");

    console.puts("Spawned ramfs (PID ");
    console.putDec(proc.pid);
    console.puts(")\n");
}

fn spawnPartfs() void {
    // Only spawn partfs if virtio-blk is available
    if (!virtio_blk.isInitialized()) return;

    const partfs_elf = initrd.findFile("partfs") orelse {
        serial.puts("No partfs in initrd — running without /dev/.\n");
        return;
    };

    const proc = process.create() orelse {
        console.puts("Failed to create partfs process!\n");
        return;
    };

    const load_result = elf.load(proc.pml4.?, partfs_elf) catch {
        console.puts("Failed to load partfs ELF!\n");
        proc.state = .dead;
        return;
    };

    proc.user_rip = load_result.entry_point;
    proc.brk = load_result.brk;

    // Allocate user stack
    for (0..process.USER_STACK_PAGES) |i| {
        const page = pmm.allocPage() orelse {
            console.puts("Failed to allocate partfs stack!\n");
            proc.state = .dead;
            return;
        };
        const ptr: [*]u8 = paging.physPtr(page);
        @memset(ptr[0..mem.PAGE_SIZE], 0);
        const vaddr = mem.USER_STACK_TOP - (process.USER_STACK_PAGES - i) * mem.PAGE_SIZE;
        paging.mapPage(proc.pml4.?, vaddr, page, paging.Flags.WRITABLE | paging.Flags.USER) orelse {
            console.puts("Failed to map partfs stack!\n");
            proc.state = .dead;
            return;
        };
    }
    proc.user_rsp = mem.USER_STACK_INIT;

    // Create IPC channel for partfs
    const chan = ipc.channelCreate() catch {
        console.puts("Failed to create partfs channel!\n");
        proc.state = .dead;
        return;
    };

    // Server end as fd 3
    proc.setFd(3, chan.server, true);

    // Block device as fd 4 (raw, whole disk — partfs reads GPT itself)
    proc.fds[4] = .{
        .fd_type = .blk,
        .channel_id = 0,
        .is_server = false,
        .read_offset = 0,
        .server_handle = 0,
    };

    // Mount client end at "/dev/" in root namespace
    const root_ns = namespace.getRootNamespace();
    root_ns.mount("/dev/", chan.client, .{ .replace = true }) catch {
        console.puts("Failed to mount partfs at /dev/!\n");
        proc.state = .dead;
        return;
    };

    proc.parent_pid = null;
    root_ns.cloneInto(&proc.ns);

    serial.puts("[partfs: pid=");
    serial.putDec(proc.pid);
    serial.puts(" entry=0x");
    serial.putHex(load_result.entry_point);
    serial.puts("]\n");

    console.puts("Spawned partfs (PID ");
    console.putDec(proc.pid);
    console.puts(")\n");
}

fn spawnFxfs() void {
    // Only spawn fxfs if virtio-blk is available
    if (!virtio_blk.isInitialized()) return;

    const fxfs_elf = initrd.findFile("fxfs") orelse {
        serial.puts("No fxfs in initrd — running without persistent filesystem.\n");
        return;
    };

    const proc = process.create() orelse {
        console.puts("Failed to create fxfs process!\n");
        return;
    };

    const load_result = elf.load(proc.pml4.?, fxfs_elf) catch {
        console.puts("Failed to load fxfs ELF!\n");
        proc.state = .dead;
        return;
    };

    proc.user_rip = load_result.entry_point;
    proc.brk = load_result.brk;

    // Allocate user stack
    for (0..process.USER_STACK_PAGES) |i| {
        const page = pmm.allocPage() orelse {
            console.puts("Failed to allocate fxfs stack!\n");
            proc.state = .dead;
            return;
        };
        const ptr: [*]u8 = paging.physPtr(page);
        @memset(ptr[0..mem.PAGE_SIZE], 0);
        const vaddr = mem.USER_STACK_TOP - (process.USER_STACK_PAGES - i) * mem.PAGE_SIZE;
        paging.mapPage(proc.pml4.?, vaddr, page, paging.Flags.WRITABLE | paging.Flags.USER) orelse {
            console.puts("Failed to map fxfs stack!\n");
            proc.state = .dead;
            return;
        };
    }
    proc.user_rsp = mem.USER_STACK_INIT;

    // Create IPC channel for fxfs
    const chan = ipc.channelCreate() catch {
        console.puts("Failed to create fxfs channel!\n");
        proc.state = .dead;
        return;
    };

    // Server end as fd 3
    proc.setFd(3, chan.server, true);

    // Block device as fd 4 (with partition offset if GPT detected)
    const gpt = @import("gpt.zig");
    if (gpt.isInitialized() and gpt.getPartitionCount() > 0) {
        const part = gpt.getPartition(0).?;
        proc.fds[4] = .{
            .fd_type = .blk,
            .channel_id = 0,
            .is_server = false,
            .read_offset = 0,
            .server_handle = 0,
            .blk_offset = part.first_lba * 512,
            .blk_size = (part.last_lba - part.first_lba + 1) * 512,
        };
        serial.puts("[fxfs: using partition 1 at LBA ");
        serial.putDec(part.first_lba);
        serial.puts("]\n");
    } else {
        // Fallback: whole disk (backward compatible with unpartitioned disks)
        proc.fds[4] = .{
            .fd_type = .blk,
            .channel_id = 0,
            .is_server = false,
            .read_offset = 0,
            .server_handle = 0,
        };
    }

    // Mount client end at "/disk/" in root namespace
    const root_ns = namespace.getRootNamespace();
    root_ns.mount("/disk/", chan.client, .{ .replace = true }) catch {
        console.puts("Failed to mount fxfs at /disk/!\n");
        proc.state = .dead;
        return;
    };

    proc.parent_pid = null;
    root_ns.cloneInto(&proc.ns);

    serial.puts("[fxfs: pid=");
    serial.putDec(proc.pid);
    serial.puts(" entry=0x");
    serial.putHex(load_result.entry_point);
    serial.puts("]\n");

    console.puts("Spawned fxfs (PID ");
    console.putDec(proc.pid);
    console.puts(")\n");
}

/// Spawn init (PID 1) from the initrd. Init inherits the root namespace
/// with /boot/ mounts, so it can open("/boot/<program>") + read + spawn.
fn spawnInit() void {
    const init_elf = initrd.findFile("init") orelse {
        console.puts("No init in initrd — running without userspace.\n");
        return;
    };

    const proc = process.create() orelse {
        console.puts("Failed to create init process!\n");
        return;
    };

    // Load ELF into init's address space
    const load_result = elf.load(proc.pml4.?, init_elf) catch {
        console.puts("Failed to load init ELF!\n");
        proc.state = .dead;
        return;
    };

    proc.user_rip = load_result.entry_point;
    proc.brk = load_result.brk;

    // Allocate user stack
    for (0..process.USER_STACK_PAGES) |i| {
        const page = pmm.allocPage() orelse {
            console.puts("Failed to allocate init stack!\n");
            proc.state = .dead;
            return;
        };
        const ptr: [*]u8 = paging.physPtr(page);
        @memset(ptr[0..mem.PAGE_SIZE], 0);
        const vaddr = mem.USER_STACK_TOP - (process.USER_STACK_PAGES - i) * mem.PAGE_SIZE;
        paging.mapPage(proc.pml4.?, vaddr, page, paging.Flags.WRITABLE | paging.Flags.USER) orelse {
            console.puts("Failed to map init stack!\n");
            proc.state = .dead;
            return;
        };
    }
    proc.user_rsp = mem.USER_STACK_INIT;

    // Init has no parent (kernel-spawned PID 1)
    proc.parent_pid = null;

    // Init inherits root namespace (already has /boot/ mounts)
    namespace.getRootNamespace().cloneInto(&proc.ns);

    serial.puts("[init: pid=");
    serial.putDec(proc.pid);
    serial.puts(" entry=0x");
    serial.putHex(load_result.entry_point);
    serial.puts("]\n");

    console.puts("Spawned init (PID ");
    console.putDec(proc.pid);
    console.puts(")\n");
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
