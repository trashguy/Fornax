/// Container primitives for Fornax.
///
/// A Fornax container is NOT a new kernel concept — it's a combination
/// of existing primitives:
///   - Namespace (isolated file tree via rfork + bind + mount)
///   - Resource quotas (CPU, memory, IPC limits)
///   - Root filesystem (mounted at / in the container's namespace)
///
/// Creating a container:
///   1. rfork(RFNAMEG | RFMEM | ...)  — new process with cloned namespace
///   2. bind("/container/rootfs", "/", REPLACE)  — new root
///   3. mount(console_channel, "/dev/console")  — give it a console
///   4. exec("/init")  — run container's init
const klog = @import("klog.zig");
const process = @import("process.zig");
const namespace = @import("namespace.zig");
const ipc = @import("ipc.zig");
const elf = @import("elf.zig");
const pmm = @import("pmm.zig");
const mem = @import("mem.zig");
const SpinLock = @import("spinlock.zig").SpinLock;

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

pub const MAX_CONTAINERS = 16;
pub const MAX_NAME = 64;
pub const MAX_PATH = 256;
const USER_STACK_PAGES = process.USER_STACK_PAGES;

/// 0xFF means "host" (not in any container).
pub const HOST_CONTAINER: u8 = 0xFF;

pub const CompatMode = enum(u8) {
    fornax = 0, // Native Fornax binaries
    linux = 1, // Linux syscall translation
};

pub const Container = struct {
    /// Human-readable container name.
    name: [MAX_NAME]u8,
    name_len: u16,
    /// The init process inside this container.
    init_pid: ?u32,
    /// Path to the root filesystem image/directory.
    rootfs_path: [MAX_PATH]u8,
    rootfs_path_len: u16,
    /// Resource quotas for all processes in this container.
    quotas: process.ResourceQuotas,
    /// Whether this container slot is allocated.
    active: bool,
    /// Container state.
    state: ContainerState,
    /// Stable index (0..MAX_CONTAINERS-1).
    id: u8,
    /// Compatibility mode for binaries in this container.
    compat: CompatMode,
    /// PID of the container's dedicated netd instance.
    netd_pid: ?u32,
    /// Bridge virtual port index.
    bridge_port: ?u8,
    /// Live process count in this container (atomic).
    process_count: u16,
    /// Aggregate pages across all container processes (atomic).
    pages_used_total: u32,
    /// Assigned internal IP (e.g. 10.0.1.x, network byte order).
    net_ip: u32,
    /// Default command (from Containerfile CMD).
    cmd: [MAX_PATH]u8,
    cmd_len: u16,
    /// Per-container lock for state transitions.
    lock: SpinLock,
};

pub const ContainerState = enum(u8) {
    free = 0,
    created = 1, // configured but not started
    running = 2, // init process running
    stopped = 3, // init process exited
    failed = 4, // init process crashed
};

var containers: [MAX_CONTAINERS]Container = undefined;
var initialized: bool = false;
/// Global lock for container create/destroy (infrequent operations).
var containers_lock: SpinLock = .{};

pub fn init() void {
    for (&containers, 0..) |*c, i| {
        c.active = false;
        c.init_pid = null;
        c.state = .free;
        c.name_len = 0;
        c.rootfs_path_len = 0;
        c.id = @intCast(i);
        c.compat = .fornax;
        c.netd_pid = null;
        c.bridge_port = null;
        c.process_count = 0;
        c.pages_used_total = 0;
        c.net_ip = 0;
        c.cmd_len = 0;
        c.lock = .{};
    }
    initialized = true;
    klog.info("Containers: initialized (max ");
    klog.infoDec(MAX_CONTAINERS);
    klog.info(")\n");
}

/// Create a new container configuration. Returns the container or null if full.
pub fn create(name: []const u8, rootfs_path: []const u8, quotas: process.ResourceQuotas) ?*Container {
    if (!initialized) return null;
    if (name.len > MAX_NAME or rootfs_path.len > MAX_PATH) return null;

    containers_lock.lock();
    defer containers_lock.unlock();

    for (&containers) |*c| {
        if (!c.active) {
            @memcpy(c.name[0..name.len], name);
            c.name_len = @intCast(name.len);
            @memcpy(c.rootfs_path[0..rootfs_path.len], rootfs_path);
            c.rootfs_path_len = @intCast(rootfs_path.len);
            c.quotas = quotas;
            c.init_pid = null;
            c.state = .created;
            c.active = true;
            c.compat = .fornax;
            c.netd_pid = null;
            c.bridge_port = null;
            c.process_count = 0;
            c.pages_used_total = 0;
            c.net_ip = 0;
            c.cmd_len = 0;
            return c;
        }
    }
    return null;
}

/// Allocate a container slot with no name/rootfs (used by /cntr/clone).
/// Caller configures fields via ctl writes.
pub fn allocSlot() ?*Container {
    if (!initialized) return null;

    containers_lock.lock();
    defer containers_lock.unlock();

    for (&containers) |*c| {
        if (!c.active) {
            @memset(&c.name, 0);
            c.name_len = 0;
            @memset(&c.rootfs_path, 0);
            c.rootfs_path_len = 0;
            c.quotas = .{};
            c.init_pid = null;
            c.state = .created;
            c.active = true;
            c.compat = .fornax;
            c.netd_pid = null;
            c.bridge_port = null;
            c.process_count = 0;
            c.pages_used_total = 0;
            c.net_ip = 0;
            @memset(&c.cmd, 0);
            c.cmd_len = 0;
            return c;
        }
    }
    return null;
}

/// Get container by ID. Returns null if invalid or inactive.
pub fn getById(id: u8) ?*Container {
    if (id >= MAX_CONTAINERS) return null;
    const c = &containers[id];
    if (!c.active) return null;
    return c;
}

/// Get the containers array (for iteration).
pub fn getAll() *[MAX_CONTAINERS]Container {
    return &containers;
}

/// Increment process count (atomic, no lock needed on hot path).
pub fn addProcess(ct: *Container) void {
    _ = @atomicRmw(u16, &ct.process_count, .Add, 1, .monotonic);
}

/// Decrement process count (atomic).
pub fn removeProcess(ct: *Container) void {
    _ = @atomicRmw(u16, &ct.process_count, .Sub, 1, .monotonic);
}

/// Add pages to container aggregate (atomic).
pub fn addPages(ct: *Container, count: u32) void {
    _ = @atomicRmw(u32, &ct.pages_used_total, .Add, count, .monotonic);
}

/// Subtract pages from container aggregate (atomic).
pub fn subPages(ct: *Container, count: u32) void {
    _ = @atomicRmw(u32, &ct.pages_used_total, .Sub, count, .monotonic);
}

/// Check if the container quota allows more pages.
pub fn canAllocPage(ct: *const Container) bool {
    const used = @atomicLoad(u32, &@constCast(ct).pages_used_total, .monotonic);
    return used < ct.quotas.max_memory_pages;
}

/// Check if the container quota allows more child processes.
pub fn canSpawnProcess(ct: *const Container) bool {
    const count = @atomicLoad(u16, &@constCast(ct).process_count, .monotonic);
    return count < ct.quotas.max_children;
}

/// Kill all processes in a container.
pub fn killAllProcesses(ct: *Container) void {
    killAllProcessesExcept(ct, null);
}

/// Kill all processes in a container, cleaning up ether devices and pipes.
/// Optionally excludes a specific process (e.g., the init being cleaned up in sysExit).
pub fn killAllProcessesExcept(ct: *Container, except_pid: ?u32) void {
    const ether_mod = @import("ether.zig");
    const pipe_mod = @import("pipe.zig");
    const tg_mod = @import("thread_group.zig");
    const table = process.getProcessTable();
    for (table) |*p| {
        if (p.container_id != ct.id) continue;
        if (except_pid) |ep| {
            if (p.pid == ep) continue;
        }
        // Use atomic state transition for SMP safety (mirrors killChildren).
        // On SMP, a process may be .running on another core mid-syscall;
        // we must not touch its FDs or free resources while it executes.
        const state = @atomicLoad(process.ProcessState, &p.state, .acquire);
        switch (state) {
            .blocked, .ready => {
                // Safe to clean up — process is not executing on any core.
                // CAS ensures another core doesn't start it between check and kill.
                if (@cmpxchgStrong(process.ProcessState, &p.state, state, .dead, .seq_cst, .seq_cst) == null) {
                    // Clean up ether, pipe, and IPC fds before killing.
                    // Thread groups share the fd table, so getFdSlice returns
                    // the shared table — setting entries to null prevents
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
                                // Don't send T_CLOSE — the server may also be
                                // dying in this same container teardown.
                                fds[i] = null;
                            }
                        }
                    }
                } else {
                    // State changed between load and CAS — process transitioned
                    // on another core. Mark as zombie orphan for safe reclamation.
                    p.parent_pid = null;
                }
            },
            .running => {
                // Process is executing on another core — cannot safely
                // access its FDs or free memory. Mark as zombie orphan;
                // process.create() will reclaim the slot once the core
                // finishes with it.
                @atomicStore(process.ProcessState, &p.state, .zombie, .release);
                p.parent_pid = null;
            },
            .zombie, .dead => {
                // Already dying — just orphan for reclamation
                p.parent_pid = null;
            },
            .free => {},
        }
    }
}

/// Destroy a container: stop all processes, free the slot.
pub fn destroy(ct: *Container) void {
    ct.lock.lock();
    defer ct.lock.unlock();

    if (ct.state == .running) {
        killAllProcesses(ct);
    }
    ct.state = .free;
    ct.active = false;
    ct.init_pid = null;
    ct.netd_pid = null;
    ct.process_count = 0;
    ct.pages_used_total = 0;

    klog.info("[container] Destroyed container ");
    klog.infoDec(ct.id);
    klog.info("\n");
}

/// Start a container: create a process with isolated namespace, load ELF,
/// apply quotas.
/// `init_elf` is the raw ELF binary for the container's init process.
/// `console_channel_id` is the IPC channel for /dev/console access (optional).
pub fn start(ct: *Container, init_elf: []const u8, console_channel_id: ?ipc.ChannelId) ?u32 {
    if (ct.state != .created) {
        klog.err("[container] start: state is not .created\n");
        return null;
    }

    // Create the container's init process
    const proc = process.create() orelse {
        klog.err("[container] start: process.create() failed\n");
        return null;
    };

    // Re-parent: container init has no parent so it survives when
    // the management tool (fnx run -d) exits and calls killChildren.
    proc.parent_pid = null;

    // Apply resource quotas
    proc.quotas = ct.quotas;

    // Create a fresh, empty namespace for isolation
    proc.ns = namespace.Namespace.init();

    // Mount root filesystem with prefix for rootfs isolation.
    // The container sees "/" but IPC messages prepend the rootfs path.
    // Ensure prefix ends with '/' so that prefix + suffix forms a valid path
    // (e.g. prefix="/var/lib/fnx/images/X/rootfs/" + suffix="tmp/msg.txt").
    if (ct.rootfs_path_len > 0) {
        const root_ns = namespace.getRootNamespace();
        if (root_ns.resolve("/")) |root_res| {
            var prefix_buf: [MAX_PATH + 1]u8 = undefined;
            var prefix_len = ct.rootfs_path_len;
            @memcpy(prefix_buf[0..prefix_len], ct.rootfs_path[0..prefix_len]);
            if (prefix_len > 0 and prefix_buf[prefix_len - 1] != '/') {
                prefix_buf[prefix_len] = '/';
                prefix_len += 1;
            }
            proc.ns.mountWithPrefix("/", root_res.channel_id, .{ .replace = true }, prefix_buf[0..prefix_len]) catch {
                klog.err("[container] Failed to mount rootfs\n");
            };
        }
    }

    // Mount /dev/console if a channel was provided
    if (console_channel_id) |chan_id| {
        proc.ns.mount("/dev/console", chan_id, .{}) catch {
            klog.err("[container] Failed to mount /dev/console\n");
        };
    }

    // Load ELF into process address space
    const load_result = elf.load(proc.pml4.?, init_elf) catch {
        klog.err("[container] ELF load failed for '");
        klog.err(ct.name[0..ct.name_len]);
        klog.err("'\n");
        proc.state = .free;
        return null;
    };

    proc.user_rip = load_result.entry_point;
    proc.brk = load_result.brk;

    // Allocate user stack
    for (0..USER_STACK_PAGES) |i| {
        const page = process.allocPageForProcess(proc) orelse {
            klog.err("[container] Stack alloc failed (quota?)\n");
            proc.state = .free;
            return null;
        };
        const ptr: [*]u8 = paging.physPtr(page);
        @memset(ptr[0..mem.PAGE_SIZE], 0);

        const virt = mem.USER_STACK_TOP - (USER_STACK_PAGES - i) * mem.PAGE_SIZE;
        paging.mapPage(proc.pml4.?, virt, page, paging.Flags.WRITABLE | paging.Flags.USER) orelse {
            klog.err("[container] Stack map failed\n");
            proc.state = .free;
            return null;
        };
    }
    proc.user_rsp = mem.USER_STACK_INIT;

    // Track container association
    proc.container_id = ct.id;
    proc.compat = @intFromEnum(ct.compat);
    addProcess(ct);

    ct.init_pid = proc.pid;
    ct.state = .running;

    klog.info("Container '");
    klog.info(ct.name[0..ct.name_len]);
    klog.info("' started (pid=");
    klog.infoDec(proc.pid);
    klog.info(", quota=");
    klog.infoDec(ct.quotas.max_memory_pages);
    klog.info(" pages)\n");

    // NOTE: caller must set up argv/auxv and call process.markReady()
    // after this function returns. Do NOT markReady here — on SMP,
    // the process can be scheduled before argv is configured.
    return proc.pid;
}

/// Stop a container (kill all its processes).
pub fn stop(ct: *Container) void {
    if (ct.state != .running) return;
    killAllProcesses(ct);
    ct.state = .stopped;
    ct.init_pid = null;
}

/// Find a container by name.
pub fn findByName(name: []const u8) ?*Container {
    for (&containers) |*c| {
        if (c.active and c.name_len == name.len) {
            if (strEqual(c.name[0..c.name_len], name)) return c;
        }
    }
    return null;
}

/// Count active containers.
pub fn activeCount() u32 {
    var count: u32 = 0;
    for (&containers) |*c| {
        if (c.active) count += 1;
    }
    return count;
}

fn strEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}
