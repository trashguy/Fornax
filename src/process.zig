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
        pub fn switchAddressSpace(_: anytype) void {}
    },
};

const gdt = switch (@import("builtin").cpu.arch) {
    .x86_64 => @import("arch/x86_64/gdt.zig"),
    else => struct {
        pub fn setKernelStack(_: u64) void {}
        pub const USER_CS: u16 = 0;
        pub const USER_DS: u16 = 0;
    },
};

const cpu = switch (@import("builtin").cpu.arch) {
    .x86_64 => @import("arch/x86_64/cpu.zig"),
    .aarch64 => @import("arch/aarch64/cpu.zig"),
    else => struct {
        pub fn halt() noreturn {
            while (true) {}
        }
    },
};

const syscall_entry = switch (@import("builtin").cpu.arch) {
    .x86_64 => @import("arch/x86_64/syscall_entry.zig"),
    else => struct {
        pub fn setKernelStack(_: u64) void {}
        pub var saved_user_rip: u64 = 0;
        pub var saved_user_rsp: u64 = 0;
        pub var saved_user_rflags: u64 = 0;
        pub var saved_kernel_rsp: u64 = 0;
        pub fn resume_from_kernel_frame(_: u64) noreturn {
            unreachable;
        }
    },
};

const MAX_PROCESSES = 64;
const MAX_FDS = 32;
const KERNEL_STACK_PAGES = 2; // 8 KB kernel stack per process
const USER_STACK_PAGES = 2; // 8 KB user stack per process

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

/// File descriptor entry: channel ID + which end of the channel.
pub const FdEntry = struct {
    channel_id: ipc.ChannelId,
    is_server: bool,
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
    /// Saved user RFLAGS (for resume after blocking).
    user_rflags: u64,
    /// Return value to place in RAX when resuming from a blocked syscall.
    syscall_ret: u64,
    /// Saved kernel RSP pointing to the GPR frame on the process's kernel stack.
    /// Non-zero when the process is blocked in a syscall (resume via kernel frame).
    /// Zero for first-run processes (resume via IRETQ).
    saved_kernel_rsp: u64,
    /// File descriptor table: maps fd -> channel + server/client role.
    fds: [MAX_FDS]?FdEntry,
    /// Per-process namespace (Plan 9 mount table).
    ns: namespace.Namespace,
    /// Current program break (for brk syscall / heap).
    brk: u64,
    /// Resource quotas (VMS-style).
    quotas: ResourceQuotas,
    /// Number of physical pages allocated to this process.
    pages_used: u32,
    /// Per-process IPC message buffer (used during blocking send/recv).
    ipc_msg: ipc.Message,
    /// User-space buffer pointer for a pending ipc_recv delivery.
    ipc_recv_buf_ptr: u64,
    /// Pointer to pending message to deliver when this process resumes.
    ipc_pending_msg: ?*ipc.Message,

    pub fn initFds(self: *Process) void {
        for (&self.fds) |*fd| {
            fd.* = null;
        }
    }

    /// Allocate a file descriptor pointing to the given channel.
    /// Returns the fd number, or null if the fd table is full.
    pub fn allocFd(self: *Process, channel_id: ipc.ChannelId, is_server: bool) ?u32 {
        // Start from fd 3 (0=stdin, 1=stdout, 2=stderr are special)
        for (3..MAX_FDS) |i| {
            if (self.fds[i] == null) {
                self.fds[i] = .{ .channel_id = channel_id, .is_server = is_server };
                return @intCast(i);
            }
        }
        return null;
    }

    /// Set a specific fd to a channel entry.
    pub fn setFd(self: *Process, fd: u32, channel_id: ipc.ChannelId, is_server: bool) void {
        if (fd < MAX_FDS) {
            self.fds[fd] = .{ .channel_id = channel_id, .is_server = is_server };
        }
    }

    /// Close a file descriptor.
    pub fn closeFd(self: *Process, fd: u32) void {
        if (fd < MAX_FDS) {
            self.fds[fd] = null;
        }
    }

    /// Get the channel info for a file descriptor.
    pub fn getFdEntry(self: *const Process, fd: u32) ?FdEntry {
        if (fd >= MAX_FDS) return null;
        return self.fds[fd];
    }
};

var processes: [MAX_PROCESSES]Process = undefined;
var initialized: bool = false;
var next_pid: u32 = 1;

/// Currently running process.
var current: ?*Process = null;
/// Index for round-robin scheduling.
var schedule_index: usize = 0;

pub fn init() void {
    for (&processes) |*p| {
        p.pid = 0;
        p.state = .free;
        p.pml4 = null;
        p.kernel_stack_top = 0;
        p.user_rip = 0;
        p.user_rsp = 0;
        p.user_rflags = 0x202; // IF=1
        p.syscall_ret = 0;
        p.saved_kernel_rsp = 0;
        p.brk = 0;
        p.pages_used = 0;
        p.quotas = .{};
        p.ipc_msg = ipc.Message.init(.t_open);
        p.ipc_recv_buf_ptr = 0;
        p.ipc_pending_msg = null;
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
    }

    proc.* = .{
        .pid = next_pid,
        .state = .ready,
        .pml4 = addr_space,
        .kernel_stack_top = stack_base + KERNEL_STACK_PAGES * mem.PAGE_SIZE,
        .user_rip = 0,
        .user_rsp = 0,
        .user_rflags = 0x202, // IF=1, reserved bit 1
        .syscall_ret = 0,
        .saved_kernel_rsp = 0,
        .fds = [_]?FdEntry{null} ** MAX_FDS,
        .ns = namespace.getRootNamespace().clone(),
        .brk = 0,
        .pages_used = 0,
        .quotas = .{},
        .ipc_msg = ipc.Message.init(.t_open),
        .ipc_recv_buf_ptr = 0,
        .ipc_pending_msg = null,
    };
    next_pid += 1;

    return proc;
}

/// Get the currently running process.
pub fn getCurrent() ?*Process {
    return current;
}

/// Set the currently running process.
pub fn setCurrent(proc: ?*Process) void {
    current = proc;
}

/// Get a process by PID.
pub fn getByPid(pid: u32) ?*Process {
    for (&processes) |*p| {
        if (p.state != .free and p.pid == pid) return p;
    }
    return null;
}

/// Save current user context from the syscall entry point globals.
/// Called at the start of syscall dispatch to snapshot the user state.
pub fn saveCurrentContext() void {
    if (current) |proc| {
        proc.user_rip = syscall_entry.saved_user_rip;
        proc.user_rsp = syscall_entry.saved_user_rsp;
        proc.user_rflags = syscall_entry.saved_user_rflags;
        proc.saved_kernel_rsp = syscall_entry.saved_kernel_rsp;
    }
}

/// Round-robin scheduler: pick the next .ready process and jump to it.
/// If no process is ready, halts the system.
pub fn scheduleNext() noreturn {
    // Mark current as no longer running (if it was)
    if (current) |proc| {
        if (proc.state == .running) {
            proc.state = .ready;
        }
    }

    // Round-robin: scan from schedule_index
    var checked: usize = 0;
    while (checked < MAX_PROCESSES) : (checked += 1) {
        schedule_index = (schedule_index + 1) % MAX_PROCESSES;
        const proc = &processes[schedule_index];
        if (proc.state == .ready) {
            switchTo(proc);
        }
    }

    // No ready process found
    // Check if any processes are alive (blocked)
    var any_blocked = false;
    for (&processes) |*p| {
        if (p.state == .blocked) {
            any_blocked = true;
            break;
        }
    }

    if (any_blocked) {
        console.puts("\n[DEADLOCK: all processes blocked, none ready]\n");
    } else {
        console.puts("\n[All processes exited. System halting.]\n");
    }

    // Halt
    current = null;
    cpu.halt();
}

/// Assembly entry point defined in entry.S — returns to userspace via IRETQ.
/// SysV args: RDI=rip, RSI=rsp, RDX=rflags, RCX=ret_val
extern fn resume_user_mode(rip: u64, rsp: u64, rflags: u64, ret_val: u64) callconv(.{ .x86_64_sysv = .{} }) noreturn;

/// Switch to a specific process and jump to its user mode.
fn switchTo(proc: *Process) noreturn {
    current = proc;
    proc.state = .running;

    // Set up kernel stack for this process
    syscall_entry.setKernelStack(proc.kernel_stack_top);
    gdt.setKernelStack(proc.kernel_stack_top);

    // Switch address space
    if (proc.pml4) |pml4| {
        paging.switchAddressSpace(pml4);
    }

    // If there's a pending IPC message to deliver, do it now
    // (address space is loaded, so user pointers are valid)
    if (proc.ipc_pending_msg) |msg| {
        if (proc.ipc_recv_buf_ptr != 0) {
            deliverIpcMessage(msg, proc.ipc_recv_buf_ptr);
        }
        proc.ipc_pending_msg = null;
        proc.ipc_recv_buf_ptr = 0;
    }

    if (proc.saved_kernel_rsp != 0) {
        // Resume from blocked syscall: the process's kernel stack still has
        // the full GPR frame from entry.S. Write the return value into the
        // saved RAX slot (frame[12]) and jump to the pop/SYSRETQ path.
        const frame: [*]u64 = @ptrFromInt(proc.saved_kernel_rsp);
        frame[12] = proc.syscall_ret;
        proc.saved_kernel_rsp = 0;
        syscall_entry.resume_from_kernel_frame(@intFromPtr(frame));
    } else {
        // First run (no saved kernel frame) — use IRETQ path
        resume_user_mode(proc.user_rip, proc.user_rsp, proc.user_rflags, proc.syscall_ret);
    }
}

/// Copy an IPC message to a user-space IpcMessage struct.
/// Layout: tag(u32) + data_len(u32) + data([4096]u8) = 4104 bytes.
fn deliverIpcMessage(msg: *const ipc.Message, user_buf_ptr: u64) void {
    // Validate user pointer
    if (user_buf_ptr == 0 or user_buf_ptr >= 0x0000_8000_0000_0000) return;

    const tag_ptr: *align(1) u32 = @ptrFromInt(user_buf_ptr);
    const len_ptr: *align(1) u32 = @ptrFromInt(user_buf_ptr + 4);
    const data_ptr: [*]u8 = @ptrFromInt(user_buf_ptr + 8);

    tag_ptr.* = @intFromEnum(msg.tag);
    len_ptr.* = msg.data_len;
    if (msg.data_len > 0) {
        @memcpy(data_ptr[0..msg.data_len], msg.data_buf[0..msg.data_len]);
    }
}

/// Allocate a physical page for a process, checking quotas.
pub fn allocPageForProcess(proc: *Process) ?u64 {
    if (proc.pages_used >= proc.quotas.max_memory_pages) return null;
    const page = pmm.allocPage() orelse return null;
    proc.pages_used += 1;
    return page;
}
