/// VMS-inspired fault supervisor.
///
/// Monitors registered file servers. When one crashes (exception in Ring 3)
/// or exits, the supervisor restarts it from the saved ELF binary, re-mounts
/// it at the same path in the root namespace, and notifies waiting clients.
///
/// Features:
/// - Exponential backoff on rapid restarts (130.1)
/// - Dependency graph — services wait for deps before restarting (130.2)
/// - Cascade restart — dependents restart when a dep restarts (130.6)
/// - Health probes via IPC activity tracking (130.4)
/// - /proc/supervisor and /proc/supervisor/ctl interface (130.5)
const klog = @import("klog.zig");
const process = @import("process.zig");
const namespace = @import("namespace.zig");
const ipc = @import("ipc.zig");
const elf = @import("elf.zig");
const pmm = @import("pmm.zig");
const mem = @import("mem.zig");
const timer = @import("timer.zig");

const paging = switch (@import("builtin").cpu.arch) {
    .x86_64 => @import("arch/x86_64/paging.zig"),
    .riscv64 => @import("arch/riscv64/paging.zig"),
    .aarch64 => @import("arch/aarch64/paging.zig"),
    else => struct {
        pub const Flags = struct {
            pub const WRITABLE: u64 = 2;
            pub const USER: u64 = 4;
        };
        pub fn mapPage(_: anytype, _: u64, _: u64, _: u64) ?void {}
        pub inline fn physPtr(phys: u64) [*]u8 {
            return @ptrFromInt(phys);
        }
    },
};

pub const MAX_SERVICES = 16;
const MAX_NAME = 64;
const MAX_MOUNT_PATH = 128;
const USER_STACK_PAGES = process.USER_STACK_PAGES;

// Backoff constants (TICKS_PER_SEC = 18)
const INITIAL_BACKOFF: u32 = 2; // ~110ms
const MAX_BACKOFF: u32 = 540; // ~30s
const STABILITY_WINDOW: u32 = 1080; // ~60s — reset counters after this
const HEALTH_CHECK_INTERVAL: u32 = 180; // ~10s
const HEALTH_WARN_THRESHOLD: u32 = 36; // ~2s without IPC activity
const HEALTH_KILL_THRESHOLD: u32 = 90; // ~5s — treat as hung

pub const ServiceState = enum(u8) {
    running,
    stopped,
    dead,
    pending_restart,
};

pub const ExtraFd = struct {
    fd_num: u32,
    entry: process.FdEntry,
};

pub const SupervisedService = struct {
    /// Human-readable service name.
    name: [MAX_NAME]u8,
    name_len: u16,
    /// ELF binary data (pointer to embedded binary in kernel image).
    elf_data: []const u8,
    /// Mount point in the root namespace.
    mount_path: [MAX_MOUNT_PATH]u8,
    mount_path_len: u16,
    /// Current process (null if dead/not yet started).
    pid: ?u32,
    /// IPC channel ID for this service.
    channel_id: ?ipc.ChannelId,
    /// How many times this service has been restarted.
    restart_count: u32,
    /// Give up after this many restarts.
    max_restarts: u32,
    /// Whether this service entry is in use.
    active: bool,

    // Backoff fields
    last_restart_tick: u32,
    backoff_ticks: u32,
    stable_since: u32,

    // Dependency fields
    depends_on: [4]u8, // indices into services[] array
    depends_on_len: u8,
    restart_on_dep: bool,

    // State tracking
    state: ServiceState,

    // Extra fd for restart (e.g., blk device fd 4 for partfs/fxfs)
    extra_fd: ?ExtraFd,

    // Health probe: last tick when IPC reply was observed
    last_ipc_tick: u32,
};

var services: [MAX_SERVICES]SupervisedService = undefined;
var initialized: bool = false;
var last_health_check: u32 = 0;

fn initService(s: *SupervisedService) void {
    s.active = false;
    s.pid = null;
    s.channel_id = null;
    s.restart_count = 0;
    s.max_restarts = 10;
    s.name_len = 0;
    s.mount_path_len = 0;
    s.last_restart_tick = 0;
    s.backoff_ticks = 0;
    s.stable_since = 0;
    s.depends_on = .{ 0, 0, 0, 0 };
    s.depends_on_len = 0;
    s.restart_on_dep = false;
    s.state = .stopped;
    s.extra_fd = null;
    s.last_ipc_tick = 0;
}

pub fn init() void {
    for (&services) |*s| {
        initService(s);
    }
    initialized = true;
    klog.info("Supervisor: initialized (max ");
    klog.infoDec(MAX_SERVICES);
    klog.info(" services)\n");
}

/// Register a file server for supervision (without spawning it).
pub fn register(name: []const u8, elf_data: []const u8, mount_path: []const u8) ?*SupervisedService {
    if (!initialized) return null;
    if (name.len > MAX_NAME or mount_path.len > MAX_MOUNT_PATH) return null;

    for (&services) |*s| {
        if (!s.active) {
            initService(s);
            @memcpy(s.name[0..name.len], name);
            s.name_len = @intCast(name.len);
            s.elf_data = elf_data;
            @memcpy(s.mount_path[0..mount_path.len], mount_path);
            s.mount_path_len = @intCast(mount_path.len);
            s.active = true;
            s.state = .stopped;
            return s;
        }
    }
    return null;
}

/// Get the index of a service in the services array.
pub fn serviceIndex(svc: *const SupervisedService) u8 {
    const base = @intFromPtr(&services[0]);
    const ptr = @intFromPtr(svc);
    return @intCast((ptr - base) / @sizeOf(SupervisedService));
}

/// Spawn a supervised file server: register, create process, load ELF,
/// set up IPC channel, mount in root namespace.
pub fn spawnService(name: []const u8, elf_data: []const u8, mount_path: []const u8) ?*SupervisedService {
    // Register the service
    const svc = register(name, elf_data, mount_path) orelse return null;

    // Spawn the process
    if (spawnServiceProcess(svc)) {
        return svc;
    } else {
        svc.active = false;
        return null;
    }
}

/// Internal: create a process for a supervised service.
fn spawnServiceProcess(svc: *SupervisedService) bool {
    // Create process
    const proc = process.create() orelse {
        klog.err("[supervisor] Failed to create process for '");
        klog.err(svc.name[0..svc.name_len]);
        klog.err("'\n");
        return false;
    };

    // Load ELF into process address space
    const load_result = elf.load(proc.pml4.?, svc.elf_data) catch {
        klog.err("[supervisor] ELF load failed for '");
        klog.err(svc.name[0..svc.name_len]);
        klog.err("'\n");
        proc.state = .dead;
        return false;
    };

    proc.user_rip = load_result.entry_point;
    proc.brk = load_result.brk;

    // Allocate user stack
    for (0..USER_STACK_PAGES) |i| {
        const page = pmm.allocPage() orelse {
            klog.err("[supervisor] Stack alloc failed for '");
            klog.err(svc.name[0..svc.name_len]);
            klog.err("'\n");
            proc.state = .dead;
            return false;
        };
        const ptr: [*]u8 = paging.physPtr(page);
        @memset(ptr[0..mem.PAGE_SIZE], 0);

        const virt = mem.USER_STACK_TOP - (USER_STACK_PAGES - i) * mem.PAGE_SIZE;
        paging.mapPage(proc.pml4.?, virt, page, paging.Flags.WRITABLE | paging.Flags.USER) orelse {
            klog.err("[supervisor] Stack map failed for '");
            klog.err(svc.name[0..svc.name_len]);
            klog.err("'\n");
            proc.state = .dead;
            return false;
        };
    }
    proc.user_rsp = mem.USER_STACK_INIT;

    // Create IPC channel for this service
    const chan_pair = ipc.channelCreate() catch {
        klog.err("[supervisor] Channel create failed for '");
        klog.err(svc.name[0..svc.name_len]);
        klog.err("'\n");
        proc.state = .dead;
        return false;
    };

    // Give the server end to the process as fd 3
    proc.setFd(3, chan_pair.server, true);

    // Set extra fd if configured (e.g., blk device as fd 4)
    if (svc.extra_fd) |efd| {
        proc.fds[efd.fd_num] = efd.entry;
    }

    // Mount the client end in the root namespace
    const root_ns = namespace.getRootNamespace();
    root_ns.mount(svc.mount_path[0..svc.mount_path_len], chan_pair.client, .{ .replace = true }) catch {
        klog.err("[supervisor] Mount failed for '");
        klog.err(svc.name[0..svc.name_len]);
        klog.err("'\n");
        proc.state = .dead;
        return false;
    };

    // Clone root namespace into the new process
    proc.parent_pid = null;
    root_ns.cloneInto(&proc.ns);

    svc.pid = proc.pid;
    svc.channel_id = chan_pair.server;
    svc.state = .running;
    svc.stable_since = timer.getTicks();
    svc.last_ipc_tick = timer.getTicks();

    // Process is fully initialized — make it runnable
    process.markReady(proc);

    klog.debug("[supervisor] Spawned '");
    klog.debug(svc.name[0..svc.name_len]);
    klog.debug("' (pid=");
    klog.debugDec(proc.pid);
    klog.debug(", channel=");
    klog.debugDec(chan_pair.server);
    klog.debug(")\n");

    return true;
}

/// Common handler for service failure (crash or exit).
fn handleServiceFailure(s: *SupervisedService, reason: []const u8) void {
    klog.warn("[supervisor] Service '");
    klog.warn(s.name[0..s.name_len]);
    klog.warn("' ");
    klog.warn(reason);
    klog.warn(" (pid=");
    if (s.pid) |p| klog.warnDec(p);
    klog.warn(", restarts=");
    klog.warnDec(s.restart_count);
    klog.warn(")\n");

    if (s.restart_count >= s.max_restarts) {
        klog.err("[supervisor] Max restarts exceeded for '");
        klog.err(s.name[0..s.name_len]);
        klog.err("', giving up\n");
        s.pid = null;
        s.state = .dead;
        return;
    }

    s.restart_count += 1;

    // Exponential backoff
    const now = timer.getTicks();
    if (s.backoff_ticks == 0) {
        s.backoff_ticks = INITIAL_BACKOFF;
    }

    // Check if we need to defer restart
    const elapsed = now -% s.last_restart_tick;
    if (elapsed < s.backoff_ticks and s.last_restart_tick != 0) {
        // Too soon — defer restart
        s.state = .pending_restart;
        klog.debug("[supervisor] Deferring restart of '");
        klog.debug(s.name[0..s.name_len]);
        klog.debug("' (backoff=");
        klog.debugDec(s.backoff_ticks);
        klog.debug(" ticks)\n");
        return;
    }

    // Try to restart now
    attemptRestart(s);
}

/// Called by the exception handler when a userspace process faults.
/// If the faulting process is a supervised service, restart it.
/// Returns true if the fault was handled (service will be restarted).
pub fn handleProcessFault(pid: u32) bool {
    if (!initialized) return false;

    for (&services) |*s| {
        if (!s.active) continue;
        if (s.pid == pid) {
            handleServiceFailure(s, "crashed");
            return true;
        }
    }
    return false;
}

/// Called from sysExit when a process exits normally.
/// A supervised service exiting (even with status 0) is a failure.
/// Returns true if the exit was handled by the supervisor.
pub fn handleProcessExit(pid: u32) bool {
    if (!initialized) return false;

    for (&services) |*s| {
        if (!s.active) continue;
        if (s.pid == pid) {
            if (s.state == .stopped) {
                // Intentionally stopped — don't restart
                s.pid = null;
                return true;
            }
            handleServiceFailure(s, "exited");
            return true;
        }
    }
    return false;
}

/// Attempt to restart a service, checking dependencies first.
fn attemptRestart(svc: *SupervisedService) void {
    // Check dependencies are alive
    for (0..svc.depends_on_len) |i| {
        const dep_idx = svc.depends_on[i];
        if (dep_idx >= MAX_SERVICES) continue;
        const dep = &services[dep_idx];
        if (!dep.active or dep.state != .running) {
            // Dependency not ready — defer
            svc.state = .pending_restart;
            klog.debug("[supervisor] Deferring '");
            klog.debug(svc.name[0..svc.name_len]);
            klog.debug("' — waiting for dep '");
            klog.debug(dep.name[0..dep.name_len]);
            klog.debug("'\n");
            return;
        }
    }

    restartService(svc);

    // Cascade: restart dependents
    if (svc.state == .running) {
        cascadeRestart(serviceIndex(svc), 0);
    }
}

/// Restart a supervised service: mark old dead, create new process, load ELF, re-mount.
fn restartService(svc: *SupervisedService) void {
    klog.debug("[supervisor] Restarting '");
    klog.debug(svc.name[0..svc.name_len]);
    klog.debug("'...\n");

    // Mark old process as dead
    if (svc.pid) |old_pid| {
        if (process.getByPid(old_pid)) |proc| {
            proc.state = .dead;
        }
    }

    svc.last_restart_tick = timer.getTicks();
    // Double backoff for next time (cap at MAX_BACKOFF)
    if (svc.backoff_ticks < MAX_BACKOFF) {
        svc.backoff_ticks = @min(svc.backoff_ticks * 2, MAX_BACKOFF);
    }

    // Spawn new process with same ELF and mount path
    if (spawnServiceProcess(svc)) {
        klog.info("[supervisor] Restarted '");
        klog.info(svc.name[0..svc.name_len]);
        klog.info("' (restart #");
        klog.infoDec(svc.restart_count);
        klog.info(")\n");
    } else {
        klog.err("[supervisor] Failed to restart '");
        klog.err(svc.name[0..svc.name_len]);
        klog.err("'\n");
        svc.pid = null;
        svc.state = .dead;
    }
}

/// Cascade restart: find dependents of the given service and restart them.
/// Depth-limited to 3 levels to prevent infinite loops.
fn cascadeRestart(dep_idx: u8, depth: u8) void {
    if (depth >= 3) return;

    for (&services) |*s| {
        if (!s.active) continue;
        if (!s.restart_on_dep) continue;

        // Check if this service depends on the restarted one
        for (0..s.depends_on_len) |i| {
            if (s.depends_on[i] == dep_idx) {
                klog.info("[supervisor] Cascade: restarting '");
                klog.info(s.name[0..s.name_len]);
                klog.info("' (depends on restarted service)\n");

                // Mark old process dead
                if (s.pid) |old_pid| {
                    if (process.getByPid(old_pid)) |proc| {
                        process.killChildren(proc.pid);
                        proc.state = .dead;
                    }
                }

                s.restart_count += 1;
                restartService(s);

                // Recurse for transitive dependents
                if (s.state == .running) {
                    cascadeRestart(serviceIndex(s), depth + 1);
                }
                break;
            }
        }
    }
}

/// Called from timer IRQ handler to process pending restarts and stability resets.
pub fn timerTick(ticks: u32) void {
    if (!initialized) return;

    for (&services) |*s| {
        if (!s.active) continue;

        switch (s.state) {
            .pending_restart => {
                // Check if backoff period has elapsed
                const elapsed = ticks -% s.last_restart_tick;
                if (elapsed >= s.backoff_ticks or s.last_restart_tick == 0) {
                    attemptRestart(s);
                }
            },
            .running => {
                // Stability window: if service has been running long enough,
                // reset restart count and backoff
                if (s.restart_count > 0) {
                    const uptime = ticks -% s.stable_since;
                    if (uptime >= STABILITY_WINDOW) {
                        klog.debug("[supervisor] Service '");
                        klog.debug(s.name[0..s.name_len]);
                        klog.debug("' stable — resetting counters\n");
                        s.restart_count = 0;
                        s.backoff_ticks = 0;
                    }
                }
            },
            .stopped, .dead => {},
        }
    }

    // Health probe check (every ~10s)
    const since_check = ticks -% last_health_check;
    if (since_check >= HEALTH_CHECK_INTERVAL) {
        last_health_check = ticks;
        checkHealth(ticks);
    }
}

/// Check service health via IPC activity.
fn checkHealth(ticks: u32) void {
    for (&services) |*s| {
        if (!s.active or s.state != .running) continue;
        if (s.pid == null) continue;

        const pid = s.pid.?;
        const proc = process.getByPid(pid) orelse continue;

        // Only check services that have pending IPC clients
        if (s.channel_id) |chan_id| {
            if (ipc.getChannel(chan_id)) |chan| {
                chan.lock.lock();
                const has_pending = chan.client.pending_count > 0;
                chan.lock.unlock();

                if (has_pending) {
                    const idle = ticks -% s.last_ipc_tick;
                    if (idle >= HEALTH_KILL_THRESHOLD) {
                        klog.warn("[supervisor] Service '");
                        klog.warn(s.name[0..s.name_len]);
                        klog.warn("' appears hung (no IPC for ");
                        klog.warnDec(idle / timer.TICKS_PER_SEC);
                        klog.warn("s) — restarting\n");

                        // Kill the hung process
                        process.killChildren(proc.pid);
                        proc.state = .dead;
                        handleServiceFailure(s, "hung");
                    } else if (idle >= HEALTH_WARN_THRESHOLD) {
                        klog.debug("[supervisor] Service '");
                        klog.debug(s.name[0..s.name_len]);
                        klog.debug("' slow (");
                        klog.debugDec(idle / timer.TICKS_PER_SEC);
                        klog.debug("s without IPC reply)\n");
                    }
                }
            }
        }
    }
}

/// Called from sysIpcReply to track IPC activity for health probes.
pub fn updateActivity(pid: u32) void {
    if (!initialized) return;

    for (&services) |*s| {
        if (!s.active) continue;
        if (s.pid == pid) {
            s.last_ipc_tick = timer.getTicks();
            return;
        }
    }
}

/// Set the PID for a supervised service (after initial spawn).
pub fn setServicePid(svc: *SupervisedService, pid: u32) void {
    svc.pid = pid;
    svc.state = .running;
    svc.stable_since = timer.getTicks();
    svc.last_ipc_tick = timer.getTicks();
}

/// Get a supervised service by name.
pub fn findByName(name: []const u8) ?*SupervisedService {
    for (&services) |*s| {
        if (s.active and s.name_len == name.len) {
            if (pathEqual(s.name[0..s.name_len], name)) return s;
        }
    }
    return null;
}

/// Get services array for inspection (used by devfiles).
pub fn getServices() *[MAX_SERVICES]SupervisedService {
    return &services;
}

/// Stop a service (don't restart).
pub fn stopService(svc: *SupervisedService) void {
    svc.state = .stopped;
    if (svc.pid) |pid| {
        if (process.getByPid(pid)) |proc| {
            process.killChildren(proc.pid);
            proc.state = .dead;
        }
    }
    svc.pid = null;
    klog.info("[supervisor] Stopped '");
    klog.info(svc.name[0..svc.name_len]);
    klog.info("'\n");
}

/// Start a stopped service.
pub fn startService(svc: *SupervisedService) void {
    if (svc.state != .stopped and svc.state != .dead) return;
    svc.state = .pending_restart;
    svc.last_restart_tick = 0; // Allow immediate restart
    svc.backoff_ticks = 0;
    attemptRestart(svc);
}

/// Reset restart counters for a service.
pub fn resetService(svc: *SupervisedService) void {
    svc.restart_count = 0;
    svc.backoff_ticks = 0;
    svc.stable_since = timer.getTicks();
    klog.info("[supervisor] Reset counters for '");
    klog.info(svc.name[0..svc.name_len]);
    klog.info("'\n");
}

fn pathEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}
