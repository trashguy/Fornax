/// Process management for Fornax microkernel.
///
/// Each process has its own address space, kernel stack, file descriptor table,
/// and namespace (mount table).
const pmm = @import("pmm.zig");
const klog = @import("klog.zig");
const mem = @import("mem.zig");
const ipc = @import("ipc.zig");
const namespace = @import("namespace.zig");
const SpinLock = @import("spinlock.zig").SpinLock;
pub const thread_group = @import("thread_group.zig");

const paging = switch (@import("builtin").cpu.arch) {
    .x86_64 => @import("arch/x86_64/paging.zig"),
    .riscv64 => @import("arch/riscv64/paging.zig"),
    else => struct {
        pub const PageTable = struct { entries: [512]u64 };
        pub fn createAddressSpace() ?*PageTable {
            return null;
        }
        pub fn mapPage(_: anytype, _: u64, _: u64, _: u64) ?void {}
        pub fn switchAddressSpace(_: anytype) void {}
        pub fn isInitialized() bool {
            return false;
        }
        pub inline fn physPtr(phys: u64) [*]u8 {
            return @ptrFromInt(phys);
        }
    },
};

const gdt = switch (@import("builtin").cpu.arch) {
    .x86_64 => @import("arch/x86_64/gdt.zig"),
    else => struct { // riscv64 and others: no segmentation
        pub fn setKernelStack(_: u64) void {}
        pub const USER_CS: u16 = 0;
        pub const USER_DS: u16 = 0;
    },
};

const cpu = switch (@import("builtin").cpu.arch) {
    .x86_64 => @import("arch/x86_64/cpu.zig"),
    .aarch64 => @import("arch/aarch64/cpu.zig"),
    .riscv64 => @import("arch/riscv64/cpu.zig"),
    else => struct {
        pub fn halt() noreturn {
            while (true) {}
        }
    },
};

const percpu = @import("percpu.zig");

const syscall_entry = switch (@import("builtin").cpu.arch) {
    .x86_64 => @import("arch/x86_64/syscall_entry.zig"),
    .riscv64 => @import("arch/riscv64/syscall_entry.zig"),
    else => struct {
        pub fn setKernelStack(_: u64) void {}
        pub fn getSavedUserRip() u64 { return 0; }
        pub fn getSavedUserRsp() u64 { return 0; }
        pub fn getSavedUserRflags() u64 { return 0; }
        pub fn getSavedKernelRsp() u64 { return 0; }
        pub fn resume_from_kernel_frame(_: u64) noreturn {
            unreachable;
        }
    },
};

/// Frame return value slot index:
/// x86_64: frame[RET_SLOT] = RAX slot, riscv64: frame[9] = a0 slot
const RET_SLOT: usize = switch (@import("builtin").cpu.arch) {
    .riscv64 => 9,
    else => 12,
};

pub const MAX_PROCESSES = 128;
pub const MAX_FDS = 32;
pub const KERNEL_STACK_PAGES = 8; // 32 KB kernel stack per process
pub const USER_STACK_PAGES = 64; // 256 KB user stack per process

pub const ProcessState = enum {
    free,
    running,
    ready,
    blocked,
    zombie, // exited but not yet reaped by parent
    dead,
};

pub const ResourceQuotas = struct {
    max_memory_pages: u32 = 256, // 1 MB default
    max_channels: u32 = 16,
    max_children: u32 = 8,
    cpu_priority: u8 = 128, // 0=lowest, 255=highest
};

pub const PendingOp = enum(u8) { none, open, create, read, write, close, stat, remove, rename, truncate, wstat, console_read, net_read, net_connect, net_listen, dns_query, icmp_read, pipe_read, pipe_write, sleep };

pub const FdType = enum(u8) { ipc, net, pipe, blk, proc, dev_null, dev_zero, dev_random, dev_pci, dev_usb, dev_mouse, dev_cpu };

pub const ProcFdKind = enum(u8) {
    dir,
    pid_dir,
    status,
    ctl,
    meminfo,
};

pub const NetFdKind = enum(u8) {
    tcp_clone,
    tcp_ctl,
    tcp_data,
    tcp_listen,
    tcp_local,
    tcp_remote,
    tcp_status,
    dns_query,
    dns_ctl,
    dns_cache,
    icmp_clone,
    icmp_ctl,
    icmp_data,
    net_status,
};

/// File descriptor entry: channel ID + which end of the channel.
pub const FdEntry = struct {
    fd_type: FdType = .ipc,
    channel_id: ipc.ChannelId,
    is_server: bool,
    /// Read offset for kernel-backed channels (initrd files).
    read_offset: u32,
    /// Server-assigned handle (0 = none / raw channel or kernel-backed, >0 = server file handle).
    server_handle: u32,
    /// Net-specific fields (only used when fd_type == .net)
    net_kind: NetFdKind = .tcp_clone,
    net_conn: u8 = 0,
    net_read_done: bool = false,
    /// Pipe-specific fields (only used when fd_type == .pipe)
    pipe_id: u8 = 0,
    pipe_is_read: bool = false,
    /// Block device partition offset (bytes). Added to pread/pwrite offset.
    blk_offset: u64 = 0,
    /// Block device partition size (bytes). 0 = whole device (no bounds check).
    blk_size: u64 = 0,
    /// Proc-specific fields (only used when fd_type == .proc)
    proc_kind: ProcFdKind = .dir,
    proc_pid: u32 = 0,
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
    /// Parent process ID (null if orphaned or root process).
    parent_pid: ?u32,
    /// Exit status stored when process exits (for parent to collect via wait).
    exit_status: u8,
    /// PID of child this process is waiting for (0 = any child, null = not waiting).
    waiting_for_pid: ?u32,
    /// What IPC op is in-flight (for reply dispatch in server-backed file ops).
    pending_op: PendingOp,
    /// Pre-allocated fd for open/create reply handling.
    pending_fd: u32,
    /// Deferred kernel stack free (can't free while running on it).
    needs_stack_free: bool = false,
    /// Tick at which a sleeping process should wake up.
    sleep_until: u32 = 0,
    /// Virtual terminal index (0-3) for console I/O routing.
    vt: u8 = 0,
    /// Process user ID (for permission checks).
    uid: u16 = 0,
    /// Process group ID.
    gid: u16 = 0,
    /// Core this process is assigned to run on.
    assigned_core: u8 = 0,
    /// Core affinity: -1 = any core, >=0 = pinned to specific core.
    core_affinity: i16 = -1,
    /// Bitmap of cores that have run this process (for TLB shootdown).
    cores_ran_on: u128 = 0,
    /// Next virtual address for anonymous mmap allocations.
    mmap_next: u64 = 0x0000_4000_0000_0000,
    /// Saved FS_BASE MSR value (for TLS, used by musl libc).
    fs_base: u64 = 0,
    /// Thread group pointer (non-null for threads sharing an address space).
    thread_group: ?*thread_group.ThreadGroup = null,
    /// Address to clear and futex-wake on thread exit (CLONE_CHILD_CLEARTID).
    ctid_ptr: u64 = 0,
    /// PID of the client this server thread is currently serving (for IPC reply).
    ipc_serving_client: u32 = 0,

    pub fn initFds(self: *Process) void {
        for (&self.fds) |*fd| {
            fd.* = null;
        }
    }

    /// Allocate a file descriptor pointing to the given channel.
    /// Returns the fd number, or null if the fd table is full.
    pub fn allocFd(self: *Process, channel_id: ipc.ChannelId, is_server: bool) ?u32 {
        const fds = if (self.thread_group) |tg|
            (if (tg.fd_table) |ft| &ft.fds else &self.fds)
        else
            &self.fds;
        // Start from fd 3 (0=stdin, 1=stdout, 2=stderr are special)
        for (3..MAX_FDS) |i| {
            if (fds[i] == null) {
                fds[i] = .{ .channel_id = channel_id, .is_server = is_server, .read_offset = 0, .server_handle = 0 };
                return @intCast(i);
            }
        }
        return null;
    }

    /// Allocate a net fd for /net/* paths.
    pub fn allocNetFd(self: *Process, kind: NetFdKind, conn: u8) ?u32 {
        const fds = if (self.thread_group) |tg|
            (if (tg.fd_table) |ft| &ft.fds else &self.fds)
        else
            &self.fds;
        for (3..MAX_FDS) |i| {
            if (fds[i] == null) {
                fds[i] = .{
                    .fd_type = .net,
                    .channel_id = 0,
                    .is_server = false,
                    .read_offset = 0,
                    .server_handle = 0,
                    .net_kind = kind,
                    .net_conn = conn,
                    .net_read_done = false,
                };
                return @intCast(i);
            }
        }
        return null;
    }

    /// Allocate a pipe fd.
    pub fn allocPipeFd(self: *Process, pipe_id: u8, is_read: bool) ?u32 {
        const fds = if (self.thread_group) |tg|
            (if (tg.fd_table) |ft| &ft.fds else &self.fds)
        else
            &self.fds;
        for (0..MAX_FDS) |i| {
            if (fds[i] == null) {
                fds[i] = .{
                    .fd_type = .pipe,
                    .channel_id = 0,
                    .is_server = false,
                    .read_offset = 0,
                    .server_handle = 0,
                    .pipe_id = pipe_id,
                    .pipe_is_read = is_read,
                };
                return @intCast(i);
            }
        }
        return null;
    }

    pub fn allocBlkFd(self: *Process) ?u32 {
        const fds = if (self.thread_group) |tg|
            (if (tg.fd_table) |ft| &ft.fds else &self.fds)
        else
            &self.fds;
        for (3..MAX_FDS) |i| {
            if (fds[i] == null) {
                fds[i] = .{
                    .fd_type = .blk,
                    .channel_id = 0,
                    .is_server = false,
                    .read_offset = 0,
                    .server_handle = 0,
                };
                return @intCast(i);
            }
        }
        return null;
    }

        pub fn allocProcFd(self: *Process, kind: ProcFdKind, pid: u32) ?u32 {
            const fds = if (self.thread_group) |tg|
                (if (tg.fd_table) |ft| &ft.fds else &self.fds)
            else
                &self.fds;
            for (3..MAX_FDS) |i| {
                if (fds[i] == null) {
                    fds[i] = .{
                        .fd_type = .proc,
                        .channel_id = 0,
                        .is_server = false,
                        .read_offset = 0,
                        .server_handle = 0,
                        .proc_kind = kind,
                        .proc_pid = pid,
                    };
                    return @intCast(i);
                }
            }
            return null;
        }

        pub fn allocDevFd(self: *Process, fd_type: FdType) ?u32 {
            const fds = if (self.thread_group) |tg|
                (if (tg.fd_table) |ft| &ft.fds else &self.fds)
            else
                &self.fds;
            for (3..MAX_FDS) |i| {
                if (fds[i] == null) {
                    fds[i] = .{
                        .fd_type = fd_type,
                        .channel_id = 0,
                        .is_server = false,
                        .read_offset = 0,
                        .server_handle = 0,
                    };
                    return @intCast(i);
                }
            }
            return null;
        }

    /// Set a specific fd to a channel entry.
    pub fn setFd(self: *Process, fd: u32, channel_id: ipc.ChannelId, is_server: bool) void {
        if (fd < MAX_FDS) {
            const fds = if (self.thread_group) |tg|
                (if (tg.fd_table) |ft| &ft.fds else &self.fds)
            else
                &self.fds;
            fds[fd] = .{ .channel_id = channel_id, .is_server = is_server, .read_offset = 0, .server_handle = 0 };
        }
    }

    /// Close a file descriptor.
    pub fn closeFd(self: *Process, fd: u32) void {
        if (fd < MAX_FDS) {
            const fds = if (self.thread_group) |tg|
                (if (tg.fd_table) |ft| &ft.fds else &self.fds)
            else
                &self.fds;
            fds[fd] = null;
        }
    }

    /// Get the channel info for a file descriptor.
    pub fn getFdEntry(self: *const Process, fd: u32) ?FdEntry {
        if (fd >= MAX_FDS) return null;
        const fds = if (self.thread_group) |tg|
            (if (tg.fd_table) |ft| &ft.fds else &@constCast(self).fds)
        else
            &@constCast(self).fds;
        return fds[fd];
    }

    /// Get a mutable pointer to an fd entry (for updating read_offset).
    pub fn getFdEntryPtr(self: *Process, fd: u32) ?*FdEntry {
        if (fd >= MAX_FDS) return null;
        const fds = if (self.thread_group) |tg|
            (if (tg.fd_table) |ft| &ft.fds else &self.fds)
        else
            &self.fds;
        return if (fds[fd]) |*entry| entry else null;
    }

    /// Get the namespace pointer (group-shared or inline).
    pub fn getNs(self: *Process) *namespace.Namespace {
        if (self.thread_group) |tg| {
            if (tg.ns) |ns| return ns;
        }
        return &self.ns;
    }
};

var processes: [MAX_PROCESSES]Process = undefined;
var initialized: bool = false;
pub var next_pid: u32 = 1;

/// Spinlock guarding process table allocation (next_pid, state transitions).
pub var table_lock: SpinLock = .{};

/// Index for round-robin scheduling.
var schedule_index: usize = 0;

/// Get the currently running process on this core (from per-CPU state).
fn current() ?*Process {
    const ptr = percpu.get().current orelse return null;
    return @ptrCast(@alignCast(ptr));
}

/// Set the currently running process on this core (in per-CPU state).
fn setCurrentInternal(proc: ?*Process) void {
    percpu.get().current = if (proc) |p| @ptrCast(p) else null;
}

pub fn init() void {
    for (&processes) |*p| {
        p.pid = 0;
        p.state = .free;
        p.pml4 = null;
        p.kernel_stack_top = 0;
        p.user_rip = 0;
        p.user_rsp = 0;
        p.user_rflags = switch (@import("builtin").cpu.arch) {
            .riscv64 => @import("arch/riscv64/cpu.zig").SSTATUS_SPIE | @import("arch/riscv64/cpu.zig").SSTATUS_SUM, // SPIE + SUM
            else => 0x202, // IF=1
        };
        p.syscall_ret = 0;
        p.saved_kernel_rsp = 0;
        p.brk = 0;
        p.pages_used = 0;
        p.quotas = .{};
        p.ipc_msg = ipc.Message.init(.t_open);
        p.ipc_recv_buf_ptr = 0;
        p.ipc_pending_msg = null;
        p.ipc_serving_client = 0;
        p.parent_pid = null;
        p.exit_status = 0;
        p.waiting_for_pid = null;
        p.pending_op = .none;
        p.pending_fd = 0;
        p.needs_stack_free = false;
        p.sleep_until = 0;
        p.vt = 0;
        p.thread_group = null;
        p.ctid_ptr = 0;
        p.initFds();
    }
    thread_group.init();
    initialized = true;
    klog.info("Process: initialized (max ");
    klog.infoDec(MAX_PROCESSES);
    klog.info(")\n");
}

/// Allocate a new process with its own address space and kernel stack.
pub fn create() ?*Process {
    if (!initialized) return null;

    // Find a free slot (under table lock)
    const proc = blk: {
        table_lock.lock();
        defer table_lock.unlock();
        var slot: ?*Process = null;
        for (&processes) |*p| {
            if (p.state == .free) {
                slot = p;
                break;
            }
        }
        const p = slot orelse break :blk null;
        // Claim the slot immediately so no other core takes it
        p.state = .blocked;
        break :blk p;
    } orelse return null;

    // Free deferred kernel stack from previous incarnation
    if (proc.needs_stack_free) {
        freeKernelStack(proc);
        proc.needs_stack_free = false;
    }

    // Allocate address space
    const addr_space = paging.createAddressSpace() orelse return null;

    // Allocate kernel stack — contiguous physical pages required because the
    // higher-half mapping is a direct phys→virt translation (no per-page mappings).
    const stack_base: u64 = pmm.allocContiguousPages(KERNEL_STACK_PAGES) orelse return null;
    const stack_virt = if (paging.isInitialized()) stack_base + mem.KERNEL_VIRT_BASE else stack_base;

    // Parent is whoever is currently running (null for kernel-spawned processes)
    const parent_pid: ?u32 = if (current()) |cur| cur.pid else null;

    proc.pid = @atomicRmw(u32, &next_pid, .Add, 1, .monotonic);
    proc.pml4 = addr_space;
    proc.kernel_stack_top = stack_virt + KERNEL_STACK_PAGES * mem.PAGE_SIZE;
    proc.user_rip = 0;
    proc.user_rsp = 0;
    proc.user_rflags = switch (@import("builtin").cpu.arch) {
        .riscv64 => @import("arch/riscv64/cpu.zig").SSTATUS_SPIE | @import("arch/riscv64/cpu.zig").SSTATUS_SUM,
        else => 0x202,
    };
    proc.syscall_ret = 0;
    proc.saved_kernel_rsp = 0;
    proc.fds = [_]?FdEntry{null} ** MAX_FDS;
    proc.brk = 0;
    proc.pages_used = 0;
    proc.quotas = .{};
    proc.ipc_recv_buf_ptr = 0;
    proc.ipc_pending_msg = null;
    proc.ipc_serving_client = 0;
    proc.parent_pid = parent_pid;
    proc.exit_status = 0;
    proc.waiting_for_pid = null;
    proc.pending_op = .none;
    proc.pending_fd = 0;
    proc.needs_stack_free = false;
    proc.sleep_until = 0;
    proc.vt = if (current()) |cur| cur.vt else 0;
    proc.uid = 0;
    proc.gid = 0;
    proc.thread_group = null;
    proc.ctid_ptr = 0;
    proc.fs_base = 0;
    proc.mmap_next = 0x0000_4000_0000_0000;
    namespace.getRootNamespace().cloneInto(&proc.ns);
    proc.ipc_msg = ipc.Message.init(.t_open);

    // Assign core: kernel-spawned → BSP; otherwise least-loaded core
    proc.assigned_core = if (current()) |_| leastLoadedCore() else 0;
    proc.core_affinity = -1; // any core
    proc.cores_ran_on = 0;

    // Enqueue on the assigned core's run queue
    markReady(proc);

    return proc;
}

/// Create a new thread that shares its parent's address space via a ThreadGroup.
/// The thread gets its own kernel stack and process table slot, but shares
/// pml4, fds, namespace, mmap_next, and brk with the parent.
pub fn createThread(parent: *Process) ?*Process {
    if (!initialized) return null;

    // Ensure the parent has a thread group (create one on first clone)
    if (parent.thread_group == null) {
        const tg = thread_group.createGroup(parent) orelse return null;
        _ = tg;
    }
    const tg = parent.thread_group.?;

    // Find a free slot (under table lock)
    const proc = blk: {
        table_lock.lock();
        defer table_lock.unlock();
        var slot: ?*Process = null;
        for (&processes) |*p| {
            if (p.state == .free) {
                slot = p;
                break;
            }
        }
        const p = slot orelse break :blk null;
        p.state = .blocked;
        break :blk p;
    } orelse return null;

    // Free deferred kernel stack from previous incarnation
    if (proc.needs_stack_free) {
        freeKernelStack(proc);
        proc.needs_stack_free = false;
    }

    // Allocate kernel stack for the new thread
    const stack_base: u64 = pmm.allocContiguousPages(KERNEL_STACK_PAGES) orelse {
        proc.state = .free;
        return null;
    };
    const stack_virt = if (paging.isInitialized()) stack_base + mem.KERNEL_VIRT_BASE else stack_base;

    proc.pid = @atomicRmw(u32, &next_pid, .Add, 1, .monotonic);
    proc.pml4 = tg.pml4; // shared address space
    proc.kernel_stack_top = stack_virt + KERNEL_STACK_PAGES * mem.PAGE_SIZE;
    proc.user_rip = 0;
    proc.user_rsp = 0;
    proc.user_rflags = switch (@import("builtin").cpu.arch) {
        .riscv64 => @import("arch/riscv64/cpu.zig").SSTATUS_SPIE | @import("arch/riscv64/cpu.zig").SSTATUS_SUM,
        else => 0x202,
    };
    proc.syscall_ret = 0;
    proc.saved_kernel_rsp = 0;
    proc.fds = [_]?FdEntry{null} ** MAX_FDS; // not used directly when thread_group != null
    proc.brk = 0;
    proc.pages_used = 0;
    proc.quotas = .{};
    proc.ipc_recv_buf_ptr = 0;
    proc.ipc_pending_msg = null;
    proc.ipc_serving_client = 0;
    proc.parent_pid = parent.pid;
    proc.exit_status = 0;
    proc.waiting_for_pid = null;
    proc.pending_op = .none;
    proc.pending_fd = 0;
    proc.needs_stack_free = false;
    proc.sleep_until = 0;
    proc.vt = parent.vt;
    proc.uid = parent.uid;
    proc.gid = parent.gid;
    proc.ns = namespace.Namespace{ .mounts = undefined, .count = 0 };
    proc.ipc_msg = ipc.Message.init(.t_open);
    proc.fs_base = 0;
    proc.ctid_ptr = 0;
    proc.mmap_next = 0; // not used directly, group has the shared value

    // Join the thread group
    thread_group.retainGroup(tg);
    proc.thread_group = tg;

    // Assign core
    proc.assigned_core = leastLoadedCore();
    proc.core_affinity = -1;
    proc.cores_ran_on = 0;

    markReady(proc);
    return proc;
}

/// Get the currently running process on this core.
pub fn getCurrent() ?*Process {
    return current();
}

/// Set the currently running process on this core.
pub fn setCurrent(proc: ?*Process) void {
    setCurrentInternal(proc);
}

/// Get a process by PID.
pub fn getByPid(pid: u32) ?*Process {
    for (&processes) |*p| {
        if (p.state != .free and p.pid == pid) return p;
    }
    return null;
}

/// Pick the online core with the shortest run queue.
pub fn leastLoadedCore() u8 {
    var best: u8 = 0;
    var best_len: u32 = percpu.percpu_array[0].run_queue.len;
    var i: u8 = 1;
    while (i < percpu.cores_online) : (i += 1) {
        const len = percpu.percpu_array[i].run_queue.len;
        if (len < best_len) {
            best = i;
            best_len = len;
        }
    }
    return best;
}

/// Get the process table index for a given process pointer.
pub fn procIndex(proc: *const Process) u16 {
    return @intCast((@intFromPtr(proc) - @intFromPtr(&processes[0])) / @sizeOf(Process));
}

/// Mark a process as ready and enqueue it on its assigned core's run queue.
/// If the target core is different from the current core, sends a schedule IPI.
pub fn markReady(proc: *Process) void {
    proc.state = .ready;
    const target_core = proc.assigned_core;
    _ = percpu.percpu_array[target_core].run_queue.push(procIndex(proc));

    // Send IPI if target core is remote (and LAPIC is available)
    if (@import("builtin").cpu.arch == .x86_64) {
        if (percpu.cores_online > 1 and target_core != percpu.getCoreId()) {
            const apic = @import("arch/x86_64/apic.zig");
            apic.sendIpi(apic.lapic_ids[target_core], apic.IPI_SCHEDULE);
        }
    }
}

/// Send TLB shootdown IPI to all cores that have run this process.
/// Called when tearing down page tables (process exit, exec).
/// The current core flushes its own TLB directly; remote cores get an IPI.
pub fn tlbShootdown(proc: *const Process) void {
    if (@import("builtin").cpu.arch != .x86_64) return;
    if (percpu.cores_online <= 1) return;

    const my_core = percpu.getCoreId();
    const bitmap = proc.cores_ran_on;
    const apic = @import("arch/x86_64/apic.zig");

    var core: u8 = 0;
    while (core < percpu.cores_online) : (core += 1) {
        if (bitmap & (@as(u128, 1) << @intCast(core)) == 0) continue;
        if (core == my_core) {
            // Flush own TLB by reloading CR3
            const cpu_mod = @import("arch/x86_64/cpu.zig");
            cpu_mod.flushTlb();
        } else {
            // Set pending flag and send IPI
            @atomicStore(bool, &percpu.percpu_array[core].tlb_flush_pending, true, .release);
            apic.sendIpi(apic.lapic_ids[core], apic.IPI_TLB_SHOOTDOWN);
        }
    }
}

/// Mark a process as ready by PID. Returns false if PID not found.
pub fn markReadyByPid(pid: u32) bool {
    if (getByPid(pid)) |proc| {
        markReady(proc);
        return true;
    }
    return false;
}

/// Recursively kill all children of a process (Fornax orphan policy).
/// When a parent exits, its entire subtree dies — Plan 9/L4/VMS style.
pub fn killChildren(parent_pid: u32) void {
    for (&processes) |*p| {
        if (p.parent_pid) |ppid| {
            if (ppid == parent_pid and p.state != .free) {
                // Skip threads in the same thread group — they're siblings, not children
                if (p.thread_group != null) continue;
                // Recurse first (kill grandchildren before child)
                killChildren(p.pid);
                // Free all process resources (safe — runs in parent's context)
                freeUserMemory(p);
                freeKernelStack(p);
                p.state = .free;
                p.parent_pid = null;
                klog.debug("[killed orphan pid=");
                klog.debugDec(p.pid);
                klog.debug("]\n");
            }
        }
    }
}

/// Get the process table for iteration (used by syscall implementations).
pub fn getProcessTable() *[MAX_PROCESSES]Process {
    return &processes;
}

/// Save current user context from the syscall entry point globals.
/// Called at the start of syscall dispatch to snapshot the user state.
pub fn saveCurrentContext() void {
    if (current()) |proc| {
        proc.user_rip = syscall_entry.getSavedUserRip();
        proc.user_rsp = syscall_entry.getSavedUserRsp();
        proc.user_rflags = syscall_entry.getSavedUserRflags();
        proc.saved_kernel_rsp = syscall_entry.getSavedKernelRsp();
    }
}

/// Round-robin scheduler: pick the next .ready process and jump to it.
/// If no process is ready, halts the system.
pub fn scheduleNext() noreturn {
    // Mark current as no longer running (if it was)
    if (current()) |proc| {
        if (proc.state == .running) {
            // Re-enqueue on this core's run queue
            markReady(proc);
        }
    }

    const my_core = percpu.getCoreId();
    const my_queue = &percpu.percpu_array[my_core].run_queue;

    while (true) {
        // Try to pop from local run queue
        if (my_queue.pop()) |pid| {
            const proc = &processes[pid];
            if (proc.state == .ready) {
                switchTo(proc);
            }
            // If the process is no longer ready (e.g., it was killed),
            // just loop and try the next entry.
            continue;
        }

        // Run queue empty — try work stealing from other cores
        if (percpu.cores_online > 1) {
            var victim: u8 = (my_core +% 1) % percpu.cores_online;
            var attempts: u8 = 0;
            while (attempts < percpu.cores_online - 1) : (attempts += 1) {
                if (victim != my_core) {
                    const stolen = my_queue.stealHalf(&percpu.percpu_array[victim].run_queue);
                    if (stolen > 0) {
                        // Update assigned_core for stolen processes
                        var peek: u32 = 0;
                        while (peek < stolen) : (peek += 1) {
                            const idx = (my_queue.head +% peek) % percpu.RUN_QUEUE_SIZE;
                            const spid = my_queue.entries[idx];
                            if (spid < MAX_PROCESSES) {
                                processes[spid].assigned_core = my_core;
                            }
                        }
                        break; // Got work, will pop on next iteration
                    }
                }
                victim = (victim +% 1) % percpu.cores_online;
            }
            // If we stole work, loop back to pop
            if (!my_queue.isEmpty()) continue;
        }

        // No ready process found — check if any are alive
        var any_alive = false;
        for (&processes) |*p| {
            if (p.state == .blocked or p.state == .zombie) {
                any_alive = true;
                break;
            }
        }

        if (any_alive) {
            // BSP: poll network
            if (my_core == 0) {
                const net = @import("net.zig");
                net.poll();
            }

            // Idle — enable interrupts and halt until an IRQ/IPI fires
            setCurrentInternal(null);
            percpu.percpu_array[my_core].idle_ticks +%= 1;
            switch (@import("builtin").cpu.arch) {
                .riscv64 => {
                    asm volatile ("csrsi sstatus, 0x2"); // SIE=1
                    asm volatile ("wfi");
                    asm volatile ("csrci sstatus, 0x2"); // SIE=0
                },
                else => {
                    asm volatile ("sti");
                    asm volatile ("hlt");
                    asm volatile ("cli");
                },
            }
            continue;
        } else {
            // On non-BSP cores, just idle forever if no processes
            if (my_core != 0) {
                setCurrentInternal(null);
                while (true) {
                    asm volatile ("sti");
                    asm volatile ("hlt");
                    asm volatile ("cli");
                    // Check if new work appeared
                    if (!my_queue.isEmpty()) break;
                }
                continue;
            }
            klog.err("\n[All processes exited. System halting.]\n");
            setCurrentInternal(null);
            cpu.halt();
        }
    }
}

/// Assembly entry point defined in entry.S — returns to userspace.
/// x86_64: IRETQ. riscv64: SRET.
/// Args: rip, rsp, flags, ret_val
extern fn resume_user_mode(rip: u64, rsp: u64, flags: u64, ret_val: u64) callconv(switch (@import("builtin").cpu.arch) {
    .x86_64 => .{ .x86_64_sysv = .{} },
    else => .c,
}) noreturn;

/// Switch to a specific process and jump to its user mode.
fn switchTo(proc: *Process) noreturn {
    setCurrentInternal(proc);
    proc.state = .running;
    // Track which cores have run this process (for TLB shootdown)
    const core_bit = @as(u128, 1) << @intCast(percpu.getCoreId());
    proc.cores_ran_on |= core_bit;
    // Also track in thread group for group-wide TLB shootdown
    if (proc.thread_group) |tg| {
        tg.lock.lock();
        tg.cores_ran_on |= core_bit;
        tg.lock.unlock();
    }

    // Set up kernel stack for this process
    syscall_entry.setKernelStack(proc.kernel_stack_top);
    gdt.setKernelStack(proc.kernel_stack_top);

    // Switch address space
    if (proc.pml4) |pml4| {
        paging.switchAddressSpace(pml4);
    }

    // Restore FS_BASE MSR for TLS (used by musl libc errno, etc.)
    if (@import("builtin").cpu.arch == .x86_64 and proc.fs_base != 0) {
        cpu.wrmsr(0xC0000100, proc.fs_base);
    }

    // Sleep delivery — check if the sleep timer has elapsed
    if (proc.pending_op == .sleep) {
        const timer = @import("timer.zig");
        const now = timer.getTicks();
        const elapsed = (now -% proc.sleep_until) < 0x8000_0000;
        if (elapsed) {
            proc.syscall_ret = 0;
            proc.pending_op = .none;
            proc.sleep_until = 0;
        } else {
            // Not yet — re-block
            proc.state = .blocked;
            setCurrentInternal(null);
            scheduleNext();
        }
    }

    // Net read delivery — address space is active, so user pointers are valid
    if (proc.pending_op == .net_read) {
        const net_mod = @import("net.zig");
        const netfs = net_mod.netfs;
        const tcp = net_mod.tcp;

        if (proc.ipc_recv_buf_ptr != 0 and proc.ipc_recv_buf_ptr < 0x0000_8000_0000_0000) {
            const fd_entry = proc.getFdEntryPtr(proc.pending_fd) orelse {
                proc.syscall_ret = 0;
                proc.pending_op = .none;
                proc.ipc_recv_buf_ptr = 0;
                proc.pending_fd = 0;
                // fall through to resume
                if (proc.saved_kernel_rsp != 0) {
                    const frame: [*]u64 = @ptrFromInt(proc.saved_kernel_rsp);
                    frame[RET_SLOT] = proc.syscall_ret;
                    proc.saved_kernel_rsp = 0;
                    syscall_entry.resume_from_kernel_frame(@intFromPtr(frame));
                } else {
                    resume_user_mode(proc.user_rip, proc.user_rsp, proc.user_rflags, proc.syscall_ret);
                }
            };

            const dest: [*]u8 = @ptrFromInt(proc.ipc_recv_buf_ptr);
            const buf_size: u16 = @intCast(@min(proc.syscall_ret, 4096));
            const result = netfs.netRead(fd_entry.net_kind, fd_entry.net_conn, dest[0..buf_size], &fd_entry.net_read_done);

            if (result) |n| {
                proc.syscall_ret = n;
            } else {
                // Still no data — re-block
                tcp.setReadWaiter(fd_entry.net_conn, @intCast(proc.pid));
                proc.state = .blocked;
                setCurrentInternal(null);
                scheduleNext();
            }
        } else {
            proc.syscall_ret = 0;
        }
        proc.ipc_recv_buf_ptr = 0;
        proc.pending_op = .none;
        proc.pending_fd = 0;
    }

    // ICMP read delivery — address space is active, so user pointers are valid
    if (proc.pending_op == .icmp_read) {
        const net_mod = @import("net.zig");
        const netfs = net_mod.netfs;
        const icmp_mod = net_mod.icmp;

        if (proc.ipc_recv_buf_ptr != 0 and proc.ipc_recv_buf_ptr < 0x0000_8000_0000_0000) {
            const fd_entry = proc.getFdEntryPtr(proc.pending_fd) orelse {
                proc.syscall_ret = 0;
                proc.pending_op = .none;
                proc.ipc_recv_buf_ptr = 0;
                proc.pending_fd = 0;
                if (proc.saved_kernel_rsp != 0) {
                    const frame: [*]u64 = @ptrFromInt(proc.saved_kernel_rsp);
                    frame[RET_SLOT] = proc.syscall_ret;
                    proc.saved_kernel_rsp = 0;
                    syscall_entry.resume_from_kernel_frame(@intFromPtr(frame));
                } else {
                    resume_user_mode(proc.user_rip, proc.user_rsp, proc.user_rflags, proc.syscall_ret);
                }
            };

            const dest: [*]u8 = @ptrFromInt(proc.ipc_recv_buf_ptr);
            const buf_size: u16 = @intCast(@min(proc.syscall_ret, 4096));
            const result = netfs.netRead(fd_entry.net_kind, fd_entry.net_conn, dest[0..buf_size], &fd_entry.net_read_done);

            if (result) |n| {
                proc.syscall_ret = n;
            } else {
                // Still no data — re-block (timeout or spurious wake)
                icmp_mod.setReadWaiter(fd_entry.net_conn, @intCast(proc.pid));
                proc.state = .blocked;
                setCurrentInternal(null);
                scheduleNext();
            }
        } else {
            proc.syscall_ret = 0;
        }
        proc.ipc_recv_buf_ptr = 0;
        proc.pending_op = .none;
        proc.pending_fd = 0;
    }

    // Net connect/listen/dns delivery — just clear pending_op (syscall_ret already set by waker)
    if (proc.pending_op == .net_connect or proc.pending_op == .net_listen or proc.pending_op == .dns_query) {
        proc.pending_op = .none;
        proc.pending_fd = 0;
    }

    // Console read delivery — address space is active, so user pointers are valid
    if (proc.pending_op == .console_read) {
        const keyboard = @import("keyboard.zig");
        if (keyboard.dataAvailable(proc.vt)) {
            if (proc.ipc_recv_buf_ptr != 0 and proc.ipc_recv_buf_ptr < 0x0000_8000_0000_0000) {
                const dest: [*]u8 = @ptrFromInt(proc.ipc_recv_buf_ptr);
                const buf_size = proc.pending_fd; // we stash the count in pending_fd
                const n = keyboard.read(proc.vt, dest, buf_size);
                proc.syscall_ret = n;
            } else {
                proc.syscall_ret = 0;
            }
            keyboard.clearWaiter(proc.vt);
        } else {
            // Data not ready yet (spurious wake) — re-block
            proc.state = .blocked;
            proc.pending_op = .console_read;
            setCurrentInternal(null);
            // Return to scheduler by re-scanning
            scheduleNext();
        }
        proc.ipc_recv_buf_ptr = 0;
        proc.pending_op = .none;
        proc.pending_fd = 0;
    }

    // Pipe read delivery — address space is active, so user pointers are valid
    if (proc.pending_op == .pipe_read) {
        const pipe_mod = @import("pipe.zig");
        const fd_entry = proc.getFdEntryPtr(proc.pending_fd) orelse {
            proc.syscall_ret = 0;
            proc.pending_op = .none;
            proc.ipc_recv_buf_ptr = 0;
            proc.pending_fd = 0;
            if (proc.saved_kernel_rsp != 0) {
                const frame: [*]u64 = @ptrFromInt(proc.saved_kernel_rsp);
                frame[RET_SLOT] = proc.syscall_ret;
                proc.saved_kernel_rsp = 0;
                syscall_entry.resume_from_kernel_frame(@intFromPtr(frame));
            } else {
                resume_user_mode(proc.user_rip, proc.user_rsp, proc.user_rflags, proc.syscall_ret);
            }
        };

        if (pipe_mod.hasDataOrEof(fd_entry.pipe_id)) {
            if (proc.ipc_recv_buf_ptr != 0 and proc.ipc_recv_buf_ptr < 0x0000_8000_0000_0000) {
                const dest: [*]u8 = @ptrFromInt(proc.ipc_recv_buf_ptr);
                const buf_size = @min(proc.syscall_ret, 4096);
                if (pipe_mod.pipeRead(fd_entry.pipe_id, dest[0..buf_size])) |n| {
                    proc.syscall_ret = n;
                } else {
                    proc.syscall_ret = 0; // EOF
                }
            } else {
                proc.syscall_ret = 0;
            }
        } else {
            // Still no data — re-block
            pipe_mod.setReadWaiter(fd_entry.pipe_id, @intCast(proc.pid));
            proc.state = .blocked;
            setCurrentInternal(null);
            scheduleNext();
        }
        proc.ipc_recv_buf_ptr = 0;
        proc.pending_op = .none;
        proc.pending_fd = 0;
    }

    // Pipe write delivery — address space is active, retry the write
    if (proc.pending_op == .pipe_write) {
        const pipe_mod = @import("pipe.zig");
        const fd_entry = proc.getFdEntryPtr(proc.pending_fd) orelse {
            proc.syscall_ret = 0;
            proc.pending_op = .none;
            proc.ipc_recv_buf_ptr = 0;
            proc.pending_fd = 0;
            if (proc.saved_kernel_rsp != 0) {
                const frame: [*]u64 = @ptrFromInt(proc.saved_kernel_rsp);
                frame[RET_SLOT] = proc.syscall_ret;
                proc.saved_kernel_rsp = 0;
                syscall_entry.resume_from_kernel_frame(@intFromPtr(frame));
            } else {
                resume_user_mode(proc.user_rip, proc.user_rsp, proc.user_rflags, proc.syscall_ret);
            }
        };

        if (pipe_mod.hasSpaceOrBroken(fd_entry.pipe_id)) {
            if (proc.ipc_recv_buf_ptr != 0 and proc.ipc_recv_buf_ptr < 0x0000_8000_0000_0000) {
                const src: [*]const u8 = @ptrFromInt(proc.ipc_recv_buf_ptr);
                const n = @min(proc.syscall_ret, 4096);
                if (pipe_mod.pipeWrite(fd_entry.pipe_id, src[0..n])) |bytes| {
                    proc.syscall_ret = bytes;
                } else {
                    proc.syscall_ret = pipe_mod.EPIPE;
                }
            } else {
                proc.syscall_ret = 0;
            }
        } else {
            // Still full — re-block
            pipe_mod.setWriteWaiter(fd_entry.pipe_id, @intCast(proc.pid));
            proc.state = .blocked;
            setCurrentInternal(null);
            scheduleNext();
        }
        proc.ipc_recv_buf_ptr = 0;
        proc.pending_op = .none;
        proc.pending_fd = 0;
    }

    // If there's a pending IPC message to deliver, do it now
    // (address space is loaded, so user pointers are valid)
    if (proc.ipc_pending_msg) |msg| {
        if (proc.ipc_recv_buf_ptr != 0) {
            if (proc.pending_op == .read or proc.pending_op == .stat) {
                // Raw data delivery for read/stat replies — copy just data, not IpcMessage wrapper
                deliverRawData(msg, proc.ipc_recv_buf_ptr);
            } else {
                deliverIpcMessage(msg, proc.ipc_recv_buf_ptr);
            }
        }
        proc.ipc_pending_msg = null;
        proc.ipc_recv_buf_ptr = 0;
        proc.pending_op = .none;
    }

    if (proc.saved_kernel_rsp != 0) {
        // Resume from blocked syscall: the process's kernel stack still has
        // the full GPR frame from entry.S. Write the return value into the
        // saved return register slot and jump to the restore/return path.
        const frame: [*]u64 = @ptrFromInt(proc.saved_kernel_rsp);
        frame[RET_SLOT] = proc.syscall_ret;
        proc.saved_kernel_rsp = 0;
        syscall_entry.resume_from_kernel_frame(@intFromPtr(frame));
    } else {
        // First run (no saved kernel frame) — use IRETQ/SRET path
        resume_user_mode(proc.user_rip, proc.user_rsp, proc.user_rflags, proc.syscall_ret);
    }
}

/// Copy raw data from an IPC message directly to a user buffer (no IpcMessage wrapper).
/// Used for read() reply delivery — user expects raw file data, not a tagged message.
fn deliverRawData(msg: *const ipc.Message, user_buf_ptr: u64) void {
    if (user_buf_ptr == 0 or user_buf_ptr >= 0x0000_8000_0000_0000) return;
    if (msg.data_len == 0) return;

    const dest: [*]u8 = @ptrFromInt(user_buf_ptr);
    @memcpy(dest[0..msg.data_len], msg.data_buf[0..msg.data_len]);
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

/// Free the user address space (page tables and user pages).
/// Safe to call even if pml4 is null.
pub fn freeUserMemory(proc: *Process) void {
    if (proc.thread_group) |tg| {
        // Thread: release group reference. Last thread frees the address space.
        _ = thread_group.releaseGroup(tg, proc);
        proc.thread_group = null;
        proc.pml4 = null;
        proc.pages_used = 0;
        proc.cores_ran_on = 0;
    } else if (proc.pml4) |pml4| {
        // Non-threaded process: free address space directly
        tlbShootdown(proc);
        // Switch to kernel page tables before freeing, so CR3 doesn't
        // point to the page tables we're about to free.
        paging.switchToKernel();
        paging.freeAddressSpace(pml4);
        proc.pml4 = null;
        proc.pages_used = 0;
        proc.cores_ran_on = 0;
    }
}

/// Free the kernel stack pages.
/// MUST NOT be called while running on this stack.
pub fn freeKernelStack(proc: *Process) void {
    if (proc.kernel_stack_top == 0) return;

    // kernel_stack_top points to the end of the stack allocation.
    // Stack base = top - KERNEL_STACK_PAGES * PAGE_SIZE.
    const stack_virt = proc.kernel_stack_top - KERNEL_STACK_PAGES * mem.PAGE_SIZE;
    const stack_phys = if (stack_virt >= mem.KERNEL_VIRT_BASE) stack_virt - mem.KERNEL_VIRT_BASE else stack_virt;

    for (0..KERNEL_STACK_PAGES) |i| {
        pmm.freePage(stack_phys + i * mem.PAGE_SIZE);
    }
    proc.kernel_stack_top = 0;
}
