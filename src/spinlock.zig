/// Ticket spinlock for SMP synchronization.
///
/// Uses atomic fetch_add for fairness (FIFO ordering). Each core spins
/// on `serving` until its ticket number is served. Debug builds track
/// owner core ID and panic on recursive locking.
const builtin = @import("builtin");

const cpu = switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64/cpu.zig"),
    .riscv64 => @import("arch/riscv64/cpu.zig"),
    else => struct {
        pub inline fn spinHint() void {}
    },
};

pub const SpinLock = struct {
    /// Next ticket to hand out.
    next: u32 = 0,
    /// Currently serving ticket number.
    serving: u32 = 0,
    /// Core that holds the lock (-1 = nobody). Debug only.
    owner: i8 = -1,

    pub fn lock(self: *SpinLock) void {
        const ticket = @atomicRmw(u32, &self.next, .Add, 1, .monotonic);
        while (@atomicLoad(u32, &self.serving, .acquire) != ticket) {
            cpu.spinHint();
        }
        if (builtin.mode == .Debug) {
            self.owner = coreId();
        }
    }

    pub fn unlock(self: *SpinLock) void {
        if (builtin.mode == .Debug) {
            self.owner = -1;
        }
        @atomicStore(u32, &self.serving, self.serving +% 1, .release);
    }

    /// Try to acquire without blocking. Returns true if acquired.
    pub fn tryLock(self: *SpinLock) bool {
        const current = @atomicLoad(u32, &self.next, .monotonic);
        if (@atomicLoad(u32, &self.serving, .acquire) != current) return false;
        if (@cmpxchgWeak(u32, &self.next, current, current +% 1, .acquire, .monotonic)) |_| {
            return false;
        }
        if (builtin.mode == .Debug) {
            self.owner = coreId();
        }
        return true;
    }

    pub fn isLocked(self: *const SpinLock) bool {
        return @atomicLoad(u32, &self.next, .monotonic) != @atomicLoad(u32, &self.serving, .monotonic);
    }
};

/// Get current core ID for debug owner tracking.
fn coreId() i8 {
    const percpu = @import("percpu.zig");
    return @intCast(percpu.getCoreId());
}
