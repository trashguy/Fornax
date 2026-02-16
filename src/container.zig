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

const paging = switch (@import("builtin").cpu.arch) {
    .x86_64 => @import("arch/x86_64/paging.zig"),
    .riscv64 => @import("arch/riscv64/paging.zig"),
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

const MAX_CONTAINERS = 16;
const MAX_NAME = 64;
const MAX_PATH = 256;
const USER_STACK_PAGES = process.USER_STACK_PAGES;

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
    klog.info("Containers: initialized (max ");
    klog.infoDec(MAX_CONTAINERS);
    klog.info(")\n");
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

/// Start a container: create a process with isolated namespace, load ELF,
/// apply quotas.
/// `init_elf` is the raw ELF binary for the container's init process.
/// `console_channel_id` is the IPC channel for /dev/console access (optional).
pub fn start(ct: *Container, init_elf: []const u8, console_channel_id: ?ipc.ChannelId) ?u32 {
    if (ct.state != .created) return null;

    // Create the container's init process
    const proc = process.create() orelse return null;

    // Apply resource quotas
    proc.quotas = ct.quotas;

    // Create a fresh, empty namespace for isolation
    proc.ns = namespace.Namespace.init();

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
        proc.state = .dead;
        return null;
    };

    proc.user_rip = load_result.entry_point;
    proc.brk = load_result.brk;

    // Allocate user stack
    for (0..USER_STACK_PAGES) |i| {
        const page = process.allocPageForProcess(proc) orelse {
            klog.err("[container] Stack alloc failed (quota?)\n");
            proc.state = .dead;
            return null;
        };
        const ptr: [*]u8 = paging.physPtr(page);
        @memset(ptr[0..mem.PAGE_SIZE], 0);

        const virt = mem.USER_STACK_TOP - (USER_STACK_PAGES - i) * mem.PAGE_SIZE;
        paging.mapPage(proc.pml4.?, virt, page, paging.Flags.WRITABLE | paging.Flags.USER) orelse {
            klog.err("[container] Stack map failed\n");
            proc.state = .dead;
            return null;
        };
    }
    proc.user_rsp = mem.USER_STACK_INIT;

    ct.init_pid = proc.pid;
    ct.state = .running;

    klog.info("Container '");
    klog.info(ct.name[0..ct.name_len]);
    klog.info("' started (pid=");
    klog.infoDec(proc.pid);
    klog.info(", quota=");
    klog.infoDec(ct.quotas.max_memory_pages);
    klog.info(" pages)\n");

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
