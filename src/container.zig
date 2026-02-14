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
const console = @import("console.zig");
const process = @import("process.zig");
const namespace = @import("namespace.zig");
const ipc = @import("ipc.zig");

const MAX_CONTAINERS = 16;
const MAX_NAME = 64;
const MAX_PATH = 256;

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
    /// Whether this container is active.
    active: bool,
    /// Container state.
    state: ContainerState,
};

pub const ContainerState = enum {
    free,
    created, // configured but not started
    running, // init process running
    stopped, // init process exited
    failed, // init process crashed
};

var containers: [MAX_CONTAINERS]Container = undefined;
var initialized: bool = false;

pub fn init() void {
    for (&containers) |*c| {
        c.active = false;
        c.init_pid = null;
        c.state = .free;
        c.name_len = 0;
        c.rootfs_path_len = 0;
    }
    initialized = true;
    console.puts("Containers: initialized (max ");
    console.putDec(MAX_CONTAINERS);
    console.puts(")\n");
}

/// Create a new container configuration.
pub fn create(name: []const u8, rootfs_path: []const u8, quotas: process.ResourceQuotas) ?*Container {
    if (!initialized) return null;
    if (name.len > MAX_NAME or rootfs_path.len > MAX_PATH) return null;

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
            return c;
        }
    }
    return null;
}

/// Start a container: create a process with isolated namespace.
/// Returns the init process PID, or null on failure.
pub fn start(ct: *Container) ?u32 {
    if (ct.state != .created) return null;

    // Create the container's init process
    const proc = process.create() orelse return null;

    // Apply resource quotas
    proc.quotas = ct.quotas;

    // The container's namespace starts as a clone of root, then will be
    // modified by the container startup to bind the rootfs and mount
    // required services.
    // For now, the namespace is already cloned in process.create().

    ct.init_pid = proc.pid;
    ct.state = .running;

    console.puts("Container '");
    console.puts(ct.name[0..ct.name_len]);
    console.puts("' started (pid=");
    console.putDec(proc.pid);
    console.puts(")\n");

    return proc.pid;
}

/// Stop a container (kill its init process).
pub fn stop(ct: *Container) void {
    if (ct.state != .running) return;
    if (ct.init_pid) |pid| {
        if (process.getByPid(pid)) |proc| {
            proc.state = .dead;
        }
    }
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

fn strEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}
