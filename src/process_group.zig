/// Process group primitives for Fornax.
///
/// A process group is the kernel-level resource boundary: it tracks which
/// processes belong together, enforces aggregate page/process quotas, and
/// provides group-wide kill.  It replaces the old in-kernel Container
/// struct, keeping only the resource-tracking parts.  Policy (name, rootfs,
/// compat mode, networking, state machine) lives in userspace (cntrd).
///
/// Every process has a `group_id` field (u8):
///   - HOST_GROUP (0xFF) = host / not in any group
///   - 0..MAX_GROUPS-1   = member of that group
const klog = @import("klog.zig");
const process = @import("process.zig");
const SpinLock = @import("spinlock.zig").SpinLock;

pub const MAX_GROUPS: u8 = 16;

/// Sentinel value meaning "host process, not in any group".
pub const HOST_GROUP: u8 = 0xFF;

pub const ProcessGroup = struct {
    /// Whether this group slot is allocated.
    active: bool,
    /// Stable index (0..MAX_GROUPS-1).
    id: u8,
    /// Resource quotas for all processes in this group.
    quotas: process.ResourceQuotas,
    /// Live process count in this group (atomic).
    process_count: u16,
    /// Aggregate physical pages across all group processes (atomic).
    pages_used_total: u32,
    /// Network IP address for this group (used by sysSysinfo).
    net_ip: u32,
    /// Per-group lock for state transitions and teardown.
    lock: SpinLock,
};

var groups: [MAX_GROUPS]ProcessGroup = undefined;
var initialized: bool = false;
/// Global lock for group alloc/free (infrequent operations).
var groups_lock: SpinLock = .{};

pub fn init() void {
    for (&groups, 0..) |*g, i| {
        g.active = false;
        g.id = @intCast(i);
        g.quotas = .{};
        g.process_count = 0;
        g.pages_used_total = 0;
        g.lock = .{};
    }
    initialized = true;
    klog.info("ProcessGroups: initialized (max ");
    klog.infoDec(MAX_GROUPS);
    klog.info(")\n");
}

/// Allocate a new group slot with default quotas.
/// Returns null if all slots are in use.
pub fn alloc() ?*ProcessGroup {
    if (!initialized) return null;

    groups_lock.lock();
    defer groups_lock.unlock();

    for (&groups) |*g| {
        if (!g.active) {
            g.active = true;
            g.quotas = .{};
            g.process_count = 0;
            g.pages_used_total = 0;
            g.net_ip = 0;
            g.lock = .{};
            return g;
        }
    }
    return null;
}

/// Free a group slot.  Caller must ensure all processes are dead first.
pub fn free(g: *ProcessGroup) void {
    groups_lock.lock();
    defer groups_lock.unlock();

    g.active = false;
    g.process_count = 0;
    g.pages_used_total = 0;

    klog.info("[pgroup] Freed group ");
    klog.infoDec(g.id);
    klog.info("\n");
}

/// Look up a group by ID.  Returns null if invalid or inactive.
pub fn getById(id: u8) ?*ProcessGroup {
    if (id >= MAX_GROUPS) return null;
    const g = &groups[id];
    if (!g.active) return null;
    return g;
}

/// Get the full groups array (for iteration / devfiles).
pub fn getAll() *[MAX_GROUPS]ProcessGroup {
    return &groups;
}

/// Count active groups.
pub fn activeCount() u32 {
    var count: u32 = 0;
    for (&groups) |*g| {
        if (g.active) count += 1;
    }
    return count;
}

// ── Process/page accounting (atomic, lock-free hot path) ─────────────

/// Increment live process count.
pub fn addProcess(g: *ProcessGroup) void {
    _ = @atomicRmw(u16, &g.process_count, .Add, 1, .monotonic);
}

/// Decrement live process count.
pub fn removeProcess(g: *ProcessGroup) void {
    _ = @atomicRmw(u16, &g.process_count, .Sub, 1, .monotonic);
}

/// Add pages to aggregate total.
pub fn addPages(g: *ProcessGroup, count: u32) void {
    _ = @atomicRmw(u32, &g.pages_used_total, .Add, count, .monotonic);
}

/// Subtract pages from aggregate total.
pub fn subPages(g: *ProcessGroup, count: u32) void {
    _ = @atomicRmw(u32, &g.pages_used_total, .Sub, count, .monotonic);
}

/// Check whether the group quota allows more pages.
pub fn canAllocPage(g: *const ProcessGroup) bool {
    const used = @atomicLoad(u32, &@constCast(g).pages_used_total, .monotonic);
    return used < g.quotas.max_memory_pages;
}

/// Check whether the group quota allows more child processes.
pub fn canSpawnProcess(g: *const ProcessGroup) bool {
    const count = @atomicLoad(u16, &@constCast(g).process_count, .monotonic);
    return count < g.quotas.max_children;
}

// ── Group-wide kill ──────────────────────────────────────────────────

/// Kill all processes in the group.
pub fn killAll(g: *ProcessGroup) void {
    killAllExcept(g, null);
}

/// Kill all processes in the group, optionally excluding one PID
/// (e.g. the init being cleaned up in sysExit).
///
/// SMP-safe: uses CAS for blocked/ready processes, marks running
/// processes as zombies for deferred reclamation.
pub fn killAllExcept(g: *ProcessGroup, except_pid: ?u32) void {
    const ether_mod = @import("ether.zig");
    const pipe_mod = @import("pipe.zig");
    const tg_mod = @import("thread_group.zig");
    const table = process.getProcessTable();
    for (table) |*p| {
        if (p.group_id != g.id) continue;
        if (except_pid) |ep| {
            if (p.pid == ep) continue;
        }
        // Use atomic state transition for SMP safety (mirrors killChildren).
        // On SMP, a process may be .running on another core mid-syscall;
        // we must not touch its FDs or free resources while it executes.
        const state = @atomicLoad(process.ProcessState, &p.state, .acquire);
        switch (state) {
            .blocked, .ready => {
                // Safe to clean up -- process is not executing on any core.
                // CAS ensures another core doesn't start it between check and kill.
                if (@cmpxchgStrong(process.ProcessState, &p.state, state, .dead, .seq_cst, .seq_cst) == null) {
                    // Clean up ether, pipe, and IPC fds before killing.
                    // Thread groups share the fd table, so getFdSlice returns
                    // the shared table -- setting entries to null prevents
                    // double-free when we process sibling threads.
                    const fds = tg_mod.getFdSlice(p);
                    for (0..process.MAX_FDS) |i| {
                        if (fds[i]) |entry| {
                            if (entry.fd_type == .dev_ether) {
                                ether_mod.freeClient(entry.ether_client);
                                fds[i] = null;
                            } else if (entry.fd_type == .pipe) {
                                if (entry.pipe_is_read) {
                                    pipe_mod.closeReadEnd(entry.pipe_id);
                                } else {
                                    pipe_mod.closeWriteEnd(entry.pipe_id);
                                }
                                fds[i] = null;
                            } else if (entry.fd_type == .ipc) {
                                // IPC fds: null to prevent stale channel refs.
                                // Don't send T_CLOSE -- the server may also be
                                // dying in this same group teardown.
                                fds[i] = null;
                            }
                        }
                    }
                } else {
                    // State changed between load and CAS -- process transitioned
                    // on another core. Mark as zombie orphan for safe reclamation.
                    p.parent_pid = null;
                }
            },
            .running => {
                // Process is executing on another core -- cannot safely
                // access its FDs or free memory. Mark as zombie orphan;
                // process.create() will reclaim the slot once the core
                // finishes with it.
                @atomicStore(process.ProcessState, &p.state, .zombie, .release);
                p.parent_pid = null;
            },
            .zombie, .dead => {
                // Already dying -- just orphan for reclamation
                p.parent_pid = null;
            },
            .free => {},
        }
    }
}
