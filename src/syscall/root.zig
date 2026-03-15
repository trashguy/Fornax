/// Fornax Plan 9-inspired syscall interface.
///
/// Syscall numbers — NOT Linux-compatible. Fornax has its own ABI.
/// Convention: RAX=nr, RDI=a0, RSI=a1, RDX=a2, R10=a3, R8=a4
const std = @import("std");
const process = @import("../process.zig");
const ipc = @import("../ipc.zig");
const namespace = @import("../namespace.zig");
const klog = @import("../klog.zig");

// --- Submodules ---
pub const fs = @import("fs.zig");
pub const proc = @import("proc.zig");
pub const ipc_handlers = @import("ipc_handlers.zig");
pub const mem_handlers = @import("mem.zig");
pub const ns = @import("ns.zig");
pub const proc_setup = @import("proc_setup.zig");

pub const SYS = enum(u64) {
    open = 0,
    create = 1,
    read = 2,
    write = 3,
    close = 4,
    stat = 5,
    seek = 6,
    remove = 7,
    mount = 8,
    bind = 9,
    unmount = 10,
    rfork = 11,
    exec = 12,
    wait = 13,
    exit = 14,
    pipe = 15,
    brk = 16,
    ipc_recv = 17,
    ipc_reply = 18,
    spawn = 19,
    pread = 20,
    pwrite = 21,
    klog = 22,
    sysinfo = 23,
    sleep = 24,
    shutdown = 25,
    getpid = 26,
    rename = 27,
    truncate = 28,
    wstat = 29,
    setuid = 30,
    getuid = 31,
    mmap = 32,
    munmap = 33,
    dup = 34,
    dup2 = 35,
    arch_prctl = 36,
    clone = 37,
    futex = 38,
    ipc_pair = 39,
    shmem_create_dma = 40,
    thread_exit = 41,
    writev = 42,
    shmem_create = 43,
    shmem_map = 44,
    shmem_destroy = 45,
    proc_setup = 46,
    mmap_device = 47,
    irq_alloc = 48,
    shmem_phys = 49,
};

/// Error return values.
pub const ENOSYS: u64 = @bitCast(@as(i64, -1));
pub const EBADF: u64 = @bitCast(@as(i64, -9));
pub const EFAULT: u64 = @bitCast(@as(i64, -14));
pub const ENOENT: u64 = @bitCast(@as(i64, -2));
pub const EMFILE: u64 = @bitCast(@as(i64, -24));
pub const EIO: u64 = @bitCast(@as(i64, -5));
pub const ENOMEM: u64 = @bitCast(@as(i64, -12));
pub const EACCES: u64 = @bitCast(@as(i64, -13));
pub const EINVAL: u64 = @bitCast(@as(i64, -22));

// --- Shared helpers ---

pub fn writeU32LE(buf: *[4]u8, val: u32) void {
    buf[0] = @truncate(val);
    buf[1] = @truncate(val >> 8);
    buf[2] = @truncate(val >> 16);
    buf[3] = @truncate(val >> 24);
}

pub fn writeU64LE(buf: *[8]u8, val: u64) void {
    buf[0] = @truncate(val);
    buf[1] = @truncate(val >> 8);
    buf[2] = @truncate(val >> 16);
    buf[3] = @truncate(val >> 24);
    buf[4] = @truncate(val >> 32);
    buf[5] = @truncate(val >> 40);
    buf[6] = @truncate(val >> 48);
    buf[7] = @truncate(val >> 56);
}

pub fn readU32LE(buf: *const [4]u8) u32 {
    return @as(u32, buf[0]) |
        (@as(u32, buf[1]) << 8) |
        (@as(u32, buf[2]) << 16) |
        (@as(u32, buf[3]) << 24);
}

/// Send a client message on a channel and wake the server if it's blocked in recv.
pub fn sendToServer(chan: *ipc.Channel, proc_arg: *process.Process) void {
    chan.lock.lock();
    defer chan.lock.unlock();

    // Enqueue this client's message in the ring buffer
    @import("../trace.zig").trace(.ipc_send, proc_arg.pid);
    if (!chan.client.enqueue(proc_arg.pid, &proc_arg.ipc_msg)) {
        // Queue full — leave process blocked, it will be retried
        // when a slot opens (on next sysIpcReply)
        klog.debug("[sendToServer: QUEUE FULL for pid=");
        klog.debugDec(proc_arg.pid);
        klog.debug("]\n");
        return;
    }

    // Fast path: if a server thread is waiting for a message, wake it directly.
    // Loop to skip stale entries (dead/free processes left by fault recovery).
    var delivered = false;
    while (chan.client.server_waiter_count > 0) {
        if (chan.client.popServerWaiter()) |server_pid_u16| {
            const server_pid: u32 = server_pid_u16;
            // Clear legacy fields if they point to this server — prevents
            // a subsequent sendToServer from double-waking via legacy path.
            if (chan.client.blocked_pid == server_pid) {
                chan.client.recv_waiting = false;
                chan.client.blocked_pid = 0;
            }
            if (process.getByPid(server_pid)) |server_proc| {
                // Skip dead/free processes (stale server_waiters entry)
                if (server_proc.state == .dead or server_proc.state == .free) continue;
                // Skip processes that are already running or ready (re-enqueued
                // by fault recovery while still in server_waiters)
                if (server_proc.state == .running or server_proc.state == .ready) continue;
                // Dequeue the entry we just enqueued and deliver it
                if (chan.client.dequeue()) |entry| {
                    if (entry.msg_ptr) |msg_ptr| {
                        server_proc.ipc_pending_msg = msg_ptr;
                    }
                    server_proc.ipc_serving_client = entry.pid;
                }
                // Set return value BEFORE markReady — another core could
                // schedule this process immediately after markReady/IPI.
                server_proc.syscall_ret = 0;
                process.markReady(server_proc);
                delivered = true;
            } else {
                // PID not found — skip stale entry
                continue;
            }
        }
        break; // Popped an entry (delivered or not), stop looping
    }

    if (!delivered and chan.client.recv_waiting and chan.client.blocked_pid != 0) {
        // Legacy single-server fast path (fallback when server_waiters is full)
        if (process.getByPid(chan.client.blocked_pid)) |server_proc| {
            if (server_proc.state != .dead and server_proc.state != .free) {
                if (chan.client.dequeue()) |entry| {
                    if (entry.msg_ptr) |msg_ptr| {
                        server_proc.ipc_pending_msg = msg_ptr;
                    }
                    server_proc.ipc_serving_client = entry.pid;
                }
                server_proc.syscall_ret = 0;
                process.markReady(server_proc);
            }
            chan.client.recv_waiting = false;
            chan.client.blocked_pid = 0;
        }
    }
}

pub fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

/// Userspace FdMapping: which parent fd maps to which child fd.
pub const FdMapping = extern struct {
    child_fd: u32,
    parent_fd: u32,
};

// --- Re-exports for backward compatibility (linux_compat.zig uses syscall.sysRead, etc.) ---
pub const sysWrite = fs.sysWrite;
pub const sysWritev = fs.sysWritev;
pub const sysRead = fs.sysRead;
pub const sysOpen = fs.sysOpen;
pub const sysCreate = fs.sysCreate;
pub const sysClose = fs.sysClose;
pub const sysSeek = fs.sysSeek;
pub const sysStat = fs.sysStat;
pub const sysRemove = fs.sysRemove;
pub const sysRename = fs.sysRename;
pub const sysTruncate = fs.sysTruncate;
pub const sysWstat = fs.sysWstat;
pub const sysPipe = fs.sysPipe;
pub const sysPread = fs.sysPread;
pub const sysPwrite = fs.sysPwrite;

pub const sysExit = proc.sysExit;
pub const sysThreadExit = proc.sysThreadExit;
pub const sysWait = proc.sysWait;
pub const sysGetpid = proc.sysGetpid;
pub const sysSpawn = proc.sysSpawn;
pub const sysExec = proc.sysExec;
pub const sysRfork = proc.sysRfork;
pub const sysClone = proc.sysClone;
pub const sysBrk = proc.sysBrk;
pub const sysSetuid = proc.sysSetuid;
pub const sysGetuid = proc.sysGetuid;

pub const sysIpcRecv = ipc_handlers.sysIpcRecv;
pub const sysIpcReply = ipc_handlers.sysIpcReply;
pub const sysIpcPair = ipc_handlers.sysIpcPair;
pub const sysFutex = ipc_handlers.sysFutex;

pub const sysMmap = mem_handlers.sysMmap;
pub const sysMunmap = mem_handlers.sysMunmap;
pub const sysDup = mem_handlers.sysDup;
pub const sysDup2 = mem_handlers.sysDup2;
pub const sysArchPrctl = mem_handlers.sysArchPrctl;
pub const sysShmemCreate = mem_handlers.sysShmemCreate;
pub const sysShmemCreateDma = mem_handlers.sysShmemCreateDma;
pub const sysShmemMap = mem_handlers.sysShmemMap;
pub const sysShmemDestroy = mem_handlers.sysShmemDestroy;

pub const sysMount = ns.sysMount;
pub const sysBind = ns.sysBind;
pub const sysUnmount = ns.sysUnmount;
pub const sysKlog = ns.sysKlog;
pub const sysSysinfo = ns.sysSysinfo;
pub const sysSleep = ns.sysSleep;
pub const sysShutdown = ns.sysShutdown;

pub const sysProcSetup = proc_setup.sysProcSetup;
pub const sysMmapDevice = mem_handlers.sysMmapDevice;
pub const sysIrqAlloc = mem_handlers.sysIrqAlloc;
pub const sysShmemPhys = mem_handlers.sysShmemPhys;

/// Main syscall dispatch. Called from arch-specific entry point.
pub fn dispatch(nr: u64, arg0: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64) u64 {
    // Save user context to the current process at the start of every syscall.
    // This snapshots RIP/RSP/RFLAGS so blocking syscalls can schedule away.
    process.saveCurrentContext();

    // Increment per-core syscall counter
    {
        const percpu = @import("../percpu.zig");
        const core_id = percpu.getCoreId();
        percpu.percpu_array[core_id].syscalls += 1;
    }

    @import("../trace.zig").trace(.syscall_enter, @truncate(nr));

    // Wake deferred child thread from clone(). The parent must make several
    // syscalls (exchanging control messages, setting test state) before the
    // child thread's shared state is initialized.
    {
        const cur = process.getCurrent() orelse return ENOSYS;
        if (cur.pending_child_wake != 0) {
            if (cur.child_wake_countdown > 1) {
                cur.child_wake_countdown -= 1;
            } else {
                if (process.getByPid(cur.pending_child_wake)) |child| {
                    process.markReady(child);
                }
                cur.pending_child_wake = 0;
                cur.child_wake_countdown = 0;
            }
        }
    }

    // Linux compat: if process has compat=1, route to Linux syscall translation
    {
        const cur_proc = process.getCurrent() orelse return ENOSYS;
        if (cur_proc.compat == 1) {
            const has_containers = @import("build_options").containers;
            if (comptime has_containers) {
                const linux_compat = @import("../linux_compat.zig");
                return linux_compat.linuxDispatch(nr, arg0, arg1, arg2, arg3, arg4);
            }
            return ENOSYS;
        }
    }

    const sys = std.meta.intToEnum(SYS, nr) catch {
        klog.warn("syscall: unknown nr=");
        klog.warnDec(nr);
        klog.warn("\n");
        return ENOSYS;
    };

    const result = switch (sys) {
        .write => sysWrite(arg0, arg1, arg2),
        .exit => sysExit(arg0),
        .open => sysOpen(arg0, arg1),
        .read => sysRead(arg0, arg1, arg2),
        .close => sysClose(arg0),
        .ipc_recv => sysIpcRecv(arg0, arg1),
        .ipc_reply => sysIpcReply(arg0, arg1),
        .create => sysCreate(arg0, arg1, arg2),
        .stat => sysStat(arg0, arg1),
        .remove => sysRemove(arg0, arg1),
        .seek => sysSeek(arg0, arg1, arg2),
        .exec => sysExec(arg0, arg1, arg2),
        .wait => sysWait(arg0, arg1),
        .spawn => sysSpawn(arg0, arg1, arg2, arg3, arg4),
        .brk => sysBrk(arg0),
        .pipe => sysPipe(arg0),
        .pread => sysPread(arg0, arg1, arg2, arg3),
        .pwrite => sysPwrite(arg0, arg1, arg2, arg3),
        .klog => ns.sysKlog(arg0, arg1, arg2),
        .sysinfo => sysSysinfo(arg0),
        .sleep => sysSleep(arg0),
        .shutdown => sysShutdown(arg0),
        .getpid => sysGetpid(arg0),
        .rename => sysRename(arg0, arg1, arg2, arg3),
        .truncate => sysTruncate(arg0, arg1),
        .wstat => sysWstat(arg0, arg1, arg2, arg3, arg4),
        .setuid => sysSetuid(arg0, arg1),
        .getuid => sysGetuid(),
        .mmap => sysMmap(arg0, arg1, arg2, arg3),
        .munmap => sysMunmap(arg0, arg1),
        .dup => sysDup(arg0),
        .dup2 => sysDup2(arg0, arg1),
        .arch_prctl => sysArchPrctl(arg0, arg1),
        .rfork => sysRfork(arg0),
        .clone => sysClone(arg0, arg1, arg2, arg3, arg4),
        .futex => sysFutex(arg0, arg1, arg2, arg3),
        .mount => sysMount(arg0, arg1, arg2, arg3),
        .bind => sysBind(arg0, arg1, arg2, arg3),
        .unmount => sysUnmount(arg0, arg1),
        .ipc_pair => sysIpcPair(arg0),
        .shmem_create_dma => sysShmemCreateDma(arg0, arg1),
        .thread_exit => sysThreadExit(arg0),
        .writev => sysWritev(arg0, arg1, arg2),
        .shmem_create => sysShmemCreate(arg0),
        .shmem_map => sysShmemMap(arg0),
        .shmem_destroy => sysShmemDestroy(arg0),
        .proc_setup => sysProcSetup(arg0, arg1, arg2, arg3, arg4),
        .mmap_device => sysMmapDevice(arg0, arg1, arg2, arg3),
        .irq_alloc => sysIrqAlloc(arg0, arg1, arg2),
        .shmem_phys => sysShmemPhys(arg0, arg1),
    };

    @import("../trace.zig").trace(.syscall_exit, @truncate(nr));
    return result;
}
