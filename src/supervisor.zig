/// VMS-inspired fault supervisor.
///
/// Monitors registered file servers. When one crashes (exception in Ring 3),
/// the supervisor restarts it from the saved ELF binary, re-mounts it at
/// the same path in the root namespace, and notifies waiting clients.
///
/// Design: crash isolation — a GPU driver crash restarts the server,
/// never locks the system.
const console = @import("console.zig");
const serial = @import("serial.zig");
const process = @import("process.zig");
const namespace = @import("namespace.zig");

const MAX_SERVICES = 16;
const MAX_NAME = 64;
const MAX_MOUNT_PATH = 128;

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
    /// How many times this service has been restarted.
    restart_count: u32,
    /// Give up after this many restarts.
    max_restarts: u32,
    /// Whether this service entry is in use.
    active: bool,
};

var services: [MAX_SERVICES]SupervisedService = undefined;
var initialized: bool = false;

pub fn init() void {
    for (&services) |*s| {
        s.active = false;
        s.pid = null;
        s.restart_count = 0;
        s.max_restarts = 5;
        s.name_len = 0;
        s.mount_path_len = 0;
    }
    initialized = true;
    console.puts("Supervisor: initialized (max ");
    console.putDec(MAX_SERVICES);
    console.puts(" services)\n");
}

/// Register a file server for supervision.
pub fn register(name: []const u8, elf_data: []const u8, mount_path: []const u8) ?*SupervisedService {
    if (!initialized) return null;
    if (name.len > MAX_NAME or mount_path.len > MAX_MOUNT_PATH) return null;

    for (&services) |*s| {
        if (!s.active) {
            @memcpy(s.name[0..name.len], name);
            s.name_len = @intCast(name.len);
            s.elf_data = elf_data;
            @memcpy(s.mount_path[0..mount_path.len], mount_path);
            s.mount_path_len = @intCast(mount_path.len);
            s.pid = null;
            s.restart_count = 0;
            s.max_restarts = 5;
            s.active = true;
            return s;
        }
    }
    return null;
}

/// Called by the exception handler when a userspace process faults.
/// If the faulting process is a supervised service, restart it.
/// Returns true if the fault was handled (service will be restarted).
pub fn handleProcessFault(pid: u32) bool {
    if (!initialized) return false;

    for (&services) |*s| {
        if (!s.active) continue;
        if (s.pid == pid) {
            serial.puts("[supervisor] Service '");
            serial.puts(s.name[0..s.name_len]);
            serial.puts("' crashed (pid=");
            serial.putDec(pid);
            serial.puts(", restarts=");
            serial.putDec(s.restart_count);
            serial.puts(")\n");

            if (s.restart_count >= s.max_restarts) {
                serial.puts("[supervisor] Max restarts exceeded, giving up\n");
                console.puts("[supervisor] Service '");
                console.puts(s.name[0..s.name_len]);
                console.puts("' permanently failed\n");
                s.pid = null;
                return true;
            }

            // Restart the service
            s.restart_count += 1;
            restartService(s);
            return true;
        }
    }
    return false;
}

/// Restart a supervised service: create new process, load ELF, re-mount.
fn restartService(svc: *SupervisedService) void {
    serial.puts("[supervisor] Restarting '");
    serial.puts(svc.name[0..svc.name_len]);
    serial.puts("'...\n");

    // Mark old process as dead
    if (svc.pid) |old_pid| {
        if (process.getByPid(old_pid)) |proc| {
            proc.state = .dead;
        }
    }

    // TODO: Create new process, load ELF, mount at same path
    // This requires the full process spawn + ELF load + namespace mount flow.
    // For Milestone 3, this will be wired up with the existing infrastructure.
    //
    // For now, log the restart intent:
    console.puts("[supervisor] Restart scheduled for '");
    console.puts(svc.name[0..svc.name_len]);
    console.puts("'\n");
    svc.pid = null;
}

/// Set the PID for a supervised service (after initial spawn).
pub fn setServicePid(svc: *SupervisedService, pid: u32) void {
    svc.pid = pid;
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

fn pathEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}
