/// Native Zig threading API for Fornax.
///
/// Provides Thread.spawn() and Mutex backed by the clone/futex syscalls.
const fx = @import("syscall.zig");

const THREAD_STACK_SIZE = 64 * 4096; // 256 KB stack per thread

pub const ThreadHandle = struct {
    tid: u32,
    ctid_ptr: *volatile u32,
};

/// Spawn a new thread that calls `func(arg)`.
/// Returns a ThreadHandle that can be used with join().
pub fn spawnThread(comptime func: fn (*anyopaque) callconv(.C) void, arg: ?*anyopaque) !ThreadHandle {
    // Allocate stack via mmap (MAP_ANONYMOUS | MAP_PRIVATE)
    const MAP_ANONYMOUS: u64 = 0x20;
    const MAP_PRIVATE: u64 = 0x02;
    const PROT_READ: u64 = 0x1;
    const PROT_WRITE: u64 = 0x2;

    const stack_base = fx.mmap(0, THREAD_STACK_SIZE, PROT_READ | PROT_WRITE, MAP_ANONYMOUS | MAP_PRIVATE);
    if (stack_base == 0 or stack_base > 0xFFFF_FFFF_FFFF_0000) return error.OutOfMemory;

    const stack_top = stack_base + THREAD_STACK_SIZE;

    // Set up the stack: push arg and func pointer for the child's entry stub
    // The child thread will pop these and call func(arg)
    const sp: [*]u64 = @ptrFromInt(stack_top - 16);
    sp[0] = @intFromPtr(arg);
    sp[1] = @intFromPtr(&threadEntry);

    // ctid location — thread will clear this on exit
    var ctid: u32 align(4) = 0;
    _ = &ctid;

    // Store the actual function pointer + arg in the top of the stack
    // so threadEntry can find them
    const setup: [*]u64 = @ptrFromInt(stack_top - 32);
    setup[0] = @intFromPtr(func);
    setup[1] = @intFromPtr(arg);

    const tid = fx.clone(
        stack_top - 32, // stack pointer (points to setup area)
        0, // tls (not used for Zig threads)
        @intFromPtr(&ctid), // ctid_ptr
        0, // ptid_ptr
        0, // flags
    );

    if (tid == 0) {
        // We are the child thread — this shouldn't happen in the parent's
        // execution path because clone returns child_pid to parent.
        unreachable;
    }

    if (tid > 0xFFFF_FFFF_FFFF_0000) return error.CloneFailed;

    return ThreadHandle{
        .tid = @truncate(tid),
        .ctid_ptr = &ctid,
    };
}

fn threadEntry() callconv(.C) noreturn {
    // NOTE: This is a placeholder. For native Zig threads, the actual entry
    // mechanism depends on the stack setup. The clone syscall resumes at
    // the parent's RIP with RAX=0, so musl-style stub is needed.
    // For now, native Zig threading is a stretch goal — POSIX pthread works.
    fx.exit(0);
}

/// Mutex — futex-based mutual exclusion lock.
pub const Mutex = struct {
    state: u32 align(4) = 0, // 0 = unlocked, 1 = locked

    pub fn lock(self: *Mutex) void {
        while (@cmpxchgWeak(u32, &self.state, 0, 1, .acquire, .monotonic) != null) {
            // Contended — wait on futex
            _ = fx.futex(@intFromPtr(&self.state), 0, 1, 0); // FUTEX_WAIT, val=1
        }
    }

    pub fn unlock(self: *Mutex) void {
        @atomicStore(u32, &self.state, 0, .release);
        _ = fx.futex(@intFromPtr(&self.state), 1, 1, 0); // FUTEX_WAKE, count=1
    }
};

/// Wait for a thread to exit by spinning on its ctid_ptr.
pub fn join(handle: *const ThreadHandle) void {
    // ctid_ptr is cleared and futex-woken by the kernel on thread exit
    while (@atomicLoad(u32, handle.ctid_ptr, .acquire) != 0) {
        _ = fx.futex(@intFromPtr(handle.ctid_ptr), 0, handle.tid, 0); // FUTEX_WAIT
    }
}
