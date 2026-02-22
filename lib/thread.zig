/// Native Zig threading API for Fornax.
///
/// Provides spawnThread() and Mutex backed by the clone/futex syscalls.
/// The clone wrapper uses inline asm to handle the child's first execution:
/// parent returns child PID, child pops func/arg from stack, calls func, exits.
const fx = @import("syscall.zig");
const arch = @import("builtin").cpu.arch;

const THREAD_STACK_SIZE = 64 * 4096; // 256 KB stack per thread

pub const ThreadHandle = struct {
    tid: u32,
    ctid_ptr: *volatile u32,
};

/// Spawn a new thread that calls `func(arg)`.
/// Returns a ThreadHandle that can be used with join().
pub fn spawnThread(comptime func: fn (*anyopaque) callconv(.c) void, arg: ?*anyopaque) !ThreadHandle {
    // Allocate stack via mmap (MAP_ANONYMOUS | MAP_PRIVATE)
    const MAP_ANONYMOUS: u64 = 0x20;
    const MAP_PRIVATE: u64 = 0x02;
    const PROT_READ: u64 = 0x1;
    const PROT_WRITE: u64 = 0x2;

    const stack_base = fx.mmap(0, THREAD_STACK_SIZE, PROT_READ | PROT_WRITE, MAP_ANONYMOUS | MAP_PRIVATE);
    if (stack_base == 0 or stack_base > 0xFFFF_FFFF_FFFF_0000) return error.OutOfMemory;

    const stack_top = stack_base + THREAD_STACK_SIZE;

    // Store ctid at the base of the stack (persistent shared memory, not on parent's stack)
    const ctid_ptr: *volatile u32 = @ptrFromInt(stack_base);
    ctid_ptr.* = 0;

    // Set up child stack: func and arg at the top.
    // After clone, child RSP = stack_top - 16.
    //   [RSP + 0] = func address
    //   [RSP + 8] = arg pointer
    // Child pops these in asm and calls func(arg).
    const setup: [*]u64 = @ptrFromInt(stack_top - 16);
    setup[0] = @intFromPtr(&func);
    setup[1] = @intFromPtr(arg);

    const child_rsp = stack_top - 16;
    const ctid_addr = @intFromPtr(ctid_ptr);

    // Raw clone syscall with inline asm that handles the child case.
    // Parent path: returns child PID (RAX > 0).
    // Child path: pops func/arg, calls func(arg), exits (never returns).
    const tid: u64 = switch (arch) {
        .x86_64 => asm volatile (
        // Clone syscall
            \\ syscall
            \\ testq %%rax, %%rax
            \\ jnz 1f
            // ── Child path ──
            \\ xorl %%ebp, %%ebp
            \\ popq %%r12
            \\ popq %%rdi
            \\ callq *%%r12
            \\ movl $14, %%eax
            \\ xorl %%edi, %%edi
            \\ syscall
            \\ 1:
            : [ret] "={rax}" (-> u64),
            : [nr] "{rax}" (@intFromEnum(fx.SYS.clone)),
              [a0] "{rdi}" (child_rsp),
              [a1] "{rsi}" (@as(u64, 0)),
              [a2] "{rdx}" (ctid_addr),
              [a3] "{r10}" (@as(u64, 0)),
              [a4] "{r8}" (@as(u64, 0)),
            : .{ .rcx = true, .r11 = true, .memory = true }),
        .riscv64 => asm volatile (
            \\ ecall
            \\ bnez a0, 1f
            // ── Child path ──
            \\ ld t0, 0(sp)
            \\ ld a0, 8(sp)
            \\ addi sp, sp, 16
            \\ jalr t0
            \\ li a7, 14
            \\ li a0, 0
            \\ ecall
            \\ 1:
            : [ret] "={x10}" (-> u64),
            : [nr] "{x17}" (@intFromEnum(fx.SYS.clone)),
              [a0] "{x10}" (child_rsp),
              [a1] "{x11}" (@as(u64, 0)),
              [a2] "{x12}" (ctid_addr),
              [a3] "{x13}" (@as(u64, 0)),
              [a4] "{x14}" (@as(u64, 0)),
            : .{ .memory = true }),
        else => @compileError("unsupported arch for spawnThread"),
    };

    if (tid > 0xFFFF_FFFF_FFFF_0000) return error.CloneFailed;

    return ThreadHandle{
        .tid = @truncate(tid),
        .ctid_ptr = ctid_ptr,
    };
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
