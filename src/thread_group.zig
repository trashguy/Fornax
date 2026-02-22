const process = @import("process.zig");
const paging = switch (@import("builtin").cpu.arch) {
    .x86_64 => @import("arch/x86_64/paging.zig"),
    .riscv64 => @import("arch/riscv64/paging.zig"),
    else => @import("arch/x86_64/paging.zig"),
};
const namespace = @import("namespace.zig");
const SpinLock = @import("spinlock.zig").SpinLock;
const klog = @import("klog.zig");

pub const MAX_THREAD_GROUPS = 32;

/// Shared file descriptor table for threads in the same group.
pub const SharedFdTable = struct {
    fds: [process.MAX_FDS]?process.FdEntry,
    ref_count: u32,
    lock: SpinLock,
};

/// A thread group represents a shared address space and resources
/// for multiple threads (Process structs that share pml4/fds/namespace).
pub const ThreadGroup = struct {
    /// Shared page table root.
    pml4: ?*paging.PageTable,
    /// Number of live threads (when 0, address space is freed).
    ref_count: u32,
    /// Shared file descriptor table.
    fd_table: ?*SharedFdTable,
    /// Shared namespace.
    ns: ?*namespace.Namespace,
    /// Shared mmap bump allocator.
    mmap_next: u64,
    /// Shared heap break.
    brk: u64,
    /// PID of the thread group leader (first thread).
    leader_pid: u32,
    /// Protects mmap_next, brk, cores_ran_on.
    lock: SpinLock,
    /// Union of all threads' TLB footprints for group-wide shootdown.
    cores_ran_on: u128,
    /// Whether this slot is in use.
    active: bool,
};

// Static BSS pools — no heap allocation needed.
var groups: [MAX_THREAD_GROUPS]ThreadGroup linksection(".bss") = undefined;
var fd_tables: [MAX_THREAD_GROUPS]SharedFdTable linksection(".bss") = undefined;
var namespaces: [MAX_THREAD_GROUPS]namespace.Namespace linksection(".bss") = undefined;
var alloc_lock: SpinLock = .{};

pub fn init() void {
    for (&groups) |*g| {
        g.active = false;
        g.ref_count = 0;
        g.lock = .{};
    }
    for (&fd_tables) |*ft| {
        ft.ref_count = 0;
        ft.lock = .{};
        for (&ft.fds) |*fd| fd.* = null;
    }
}

/// Create a thread group from an existing leader process.
/// Transfers the leader's pml4, fds, namespace, mmap_next, brk into the group.
/// The leader process is then updated to point at the group.
pub fn createGroup(leader: *process.Process) ?*ThreadGroup {
    alloc_lock.lock();
    defer alloc_lock.unlock();

    // Find a free group slot
    var group: ?*ThreadGroup = null;
    var group_idx: usize = 0;
    for (&groups, 0..) |*g, i| {
        if (!g.active) {
            group = g;
            group_idx = i;
            break;
        }
    }
    const g = group orelse return null;

    // Initialize shared fd table from leader's fds
    const ft = &fd_tables[group_idx];
    ft.ref_count = 1;
    ft.lock = .{};
    @memcpy(&ft.fds, &leader.fds);

    // Initialize shared namespace from leader's namespace
    const ns = &namespaces[group_idx];
    leader.ns.cloneInto(ns);

    // Set up group
    g.pml4 = leader.pml4;
    g.ref_count = 1;
    g.fd_table = ft;
    g.ns = ns;
    g.mmap_next = leader.mmap_next;
    g.brk = leader.brk;
    g.leader_pid = leader.pid;
    g.lock = .{};
    g.cores_ran_on = leader.cores_ran_on;
    g.active = true;

    // Update leader to point at the group
    leader.thread_group = g;

    return g;
}

/// Increment the thread group's reference count for a new thread joining.
pub fn retainGroup(g: *ThreadGroup) void {
    g.lock.lock();
    defer g.lock.unlock();
    g.ref_count += 1;
}

/// Decrement reference count. When last thread exits, free the address space.
/// Returns true if this was the last reference (address space freed).
pub fn releaseGroup(g: *ThreadGroup, proc: *process.Process) bool {
    g.lock.lock();

    // Merge this thread's TLB footprint into the group
    g.cores_ran_on |= proc.cores_ran_on;

    if (g.ref_count > 1) {
        g.ref_count -= 1;
        g.lock.unlock();
        return false;
    }

    // Last thread — free the address space
    g.ref_count = 0;
    const pml4 = g.pml4;
    g.lock.unlock();

    if (pml4) |p| {
        // TLB shootdown for all cores that ran any thread in this group
        shootdownGroup(g);
        // Switch to kernel page tables before freeing, so CR3 doesn't
        // point to the page tables we're about to free.
        paging.switchToKernel();
        paging.freeAddressSpace(p);
    }

    // Mark group as free
    alloc_lock.lock();
    g.pml4 = null;
    g.fd_table = null;
    g.ns = null;
    g.active = false;
    alloc_lock.unlock();

    return true;
}

/// Perform TLB shootdown for all cores that ran threads in this group.
fn shootdownGroup(g: *ThreadGroup) void {
    if (@import("builtin").cpu.arch != .x86_64) return;
    const percpu = @import("percpu.zig");
    if (percpu.cores_online <= 1) return;

    const my_core = percpu.getCoreId();
    const bitmap = g.cores_ran_on;
    const apic = @import("arch/x86_64/apic.zig");
    const cpu_mod = @import("arch/x86_64/cpu.zig");

    var core: u8 = 0;
    while (core < percpu.cores_online) : (core += 1) {
        if (bitmap & (@as(u128, 1) << @intCast(core)) == 0) continue;
        if (core == my_core) {
            cpu_mod.flushTlb();
        } else {
            @atomicStore(bool, &percpu.percpu_array[core].tlb_flush_pending, true, .release);
            apic.sendIpi(apic.lapic_ids[core], apic.IPI_TLB_SHOOTDOWN);
        }
    }
}

/// Get the shared fd slice for a process (group-shared or inline).
pub fn getFdSlice(proc: *process.Process) *[process.MAX_FDS]?process.FdEntry {
    if (proc.thread_group) |tg| {
        if (tg.fd_table) |ft| return &ft.fds;
    }
    return &proc.fds;
}

/// Get the shared namespace for a process (group-shared or inline).
pub fn getNs(proc: *process.Process) *namespace.Namespace {
    if (proc.thread_group) |tg| {
        if (tg.ns) |ns| return ns;
    }
    return &proc.ns;
}

/// Lock the fd table for a process (no-op if no thread group).
pub fn lockFdTable(proc: *process.Process) void {
    if (proc.thread_group) |tg| {
        if (tg.fd_table) |ft| ft.lock.lock();
    }
}

/// Unlock the fd table for a process (no-op if no thread group).
pub fn unlockFdTable(proc: *process.Process) void {
    if (proc.thread_group) |tg| {
        if (tg.fd_table) |ft| ft.lock.unlock();
    }
}
