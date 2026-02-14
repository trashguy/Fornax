/// Process management for Fornax microkernel.
///
/// Each process has its own address space, kernel stack, file descriptor table,
/// and namespace (mount table).
const console = @import("console.zig");
const pmm = @import("pmm.zig");
const mem = @import("mem.zig");
const ipc = @import("ipc.zig");
const namespace = @import("namespace.zig");

const paging = switch (@import("builtin").cpu.arch) {
    .x86_64 => @import("arch/x86_64/paging.zig"),
    else => struct {
        pub const PageTable = struct { entries: [512]u64 };
        pub fn createAddressSpace() ?*PageTable {
            return null;
        }
        pub fn mapPage(_: anytype, _: u64, _: u64, _: u64) ?void {}
    },
};

const MAX_PROCESSES = 64;
const MAX_FDS = 32;
const KERNEL_STACK_PAGES = 2; // 8 KB kernel stack per process

pub const ProcessState = enum {
    free,
    running,
    ready,
    blocked,
    dead,
};

pub const ResourceQuotas = struct {
    max_memory_pages: u32 = 256, // 1 MB default
    max_channels: u32 = 16,
    max_children: u32 = 8,
    cpu_priority: u8 = 128, // 0=lowest, 255=highest
};

pub const Process = struct {
    pid: u32,
    state: ProcessState,
    /// Page table root (PML4 on x86_64).
    pml4: ?*paging.PageTable,
    /// Top of kernel stack (used for syscall/interrupt entry).
    kernel_stack_top: u64,
    /// Saved user instruction pointer (for resume).
    user_rip: u64,
    /// Saved user stack pointer (for resume).
    user_rsp: u64,
    /// File descriptor table: maps fd → channel ID.
    fds: [MAX_FDS]?ipc.ChannelId,
    /// Per-process namespace (Plan 9 mount table).
    ns: namespace.Namespace,
    /// Current program break (for brk syscall / heap).
    brk: u64,
    /// Resource quotas (VMS-style).
    quotas: ResourceQuotas,
    /// Number of physical pages allocated to this process.
    pages_used: u32,

    pub fn initFds(self: *Process) void {
        for (&self.fds) |*fd| {
            fd.* = null;
        }
    }
};

var processes: [MAX_PROCESSES]Process = undefined;
var initialized: bool = false;
var next_pid: u32 = 1;

pub fn init() void {
    for (&processes) |*p| {
        p.pid = 0;
        p.state = .free;
        p.pml4 = null;
        p.kernel_stack_top = 0;
        p.user_rip = 0;
        p.user_rsp = 0;
        p.brk = 0;
        p.pages_used = 0;
        p.quotas = .{};
        p.initFds();
    }
    initialized = true;
    console.puts("Process: initialized (max ");
    console.putDec(MAX_PROCESSES);
    console.puts(")\n");
}

/// Allocate a new process with its own address space and kernel stack.
pub fn create() ?*Process {
    if (!initialized) return null;

    // Find a free slot
    var slot: ?*Process = null;
    for (&processes) |*p| {
        if (p.state == .free) {
            slot = p;
            break;
        }
    }
    const proc = slot orelse return null;

    // Allocate address space
    const addr_space = paging.createAddressSpace() orelse return null;

    // Allocate kernel stack
    var stack_base: u64 = 0;
    for (0..KERNEL_STACK_PAGES) |i| {
        const page = pmm.allocPage() orelse return null;
        if (i == 0) stack_base = page;
        // Pages should ideally be contiguous; for MVP this works
        // since PMM often returns sequential pages
    }

    proc.* = .{
        .pid = next_pid,
        .state = .ready,
        .pml4 = addr_space,
        .kernel_stack_top = stack_base + KERNEL_STACK_PAGES * mem.PAGE_SIZE,
        .user_rip = 0,
        .user_rsp = 0,
        .fds = [_]?ipc.ChannelId{null} ** MAX_FDS,
        .ns = namespace.getRootNamespace().clone(),
        .brk = 0,
        .pages_used = 0,
        .quotas = .{},
    };
    next_pid += 1;

    return proc;
}

/// Get a process by PID.
pub fn getByPid(pid: u32) ?*Process {
    for (&processes) |*p| {
        if (p.state != .free and p.pid == pid) return p;
    }
    return null;
}
