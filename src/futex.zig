const process = @import("process.zig");
const SpinLock = @import("spinlock.zig").SpinLock;
const klog = @import("klog.zig");

pub const MAX_FUTEX_WAITERS = 128;

const FutexWaiter = struct {
    proc_index: u16,
    addr: u64, // user virtual address
    pml4_phys: u64, // address space identity (physical PML4 addr)
    active: bool,
};

var waiters: [MAX_FUTEX_WAITERS]FutexWaiter linksection(".bss") = undefined;
var futex_lock: SpinLock = .{};
var initialized: bool = false;

fn ensureInit() void {
    if (!initialized) {
        for (&waiters) |*w| {
            w.active = false;
        }
        initialized = true;
    }
}

/// Futex wait: if *addr == expected_val, block the caller.
/// Returns 0 on wake, or EAGAIN (0xFFFF...FFF5) if *addr != expected_val.
pub fn wait(proc: *process.Process, addr: u64, expected_val: u32) u64 {
    ensureInit();
    const EAGAIN: u64 = 0xFFFF_FFFF_FFFF_FFF5;

    if (addr == 0 or addr >= 0x0000_8000_0000_0000) return EAGAIN;

    // Read the current value at the user address.
    // The caller's CR3 is loaded, so user pointers are valid.
    const user_ptr: *const u32 = @ptrFromInt(addr);
    const current_val = user_ptr.*;

    if (current_val != expected_val) return EAGAIN;

    // Get the PML4 physical address for address space identity
    const pml4_phys: u64 = if (proc.thread_group) |tg|
        (if (tg.pml4) |p| @intFromPtr(p) else 0)
    else
        (if (proc.pml4) |p| @intFromPtr(p) else 0);

    futex_lock.lock();

    // Find a free waiter slot
    var slot: ?*FutexWaiter = null;
    for (&waiters) |*w| {
        if (!w.active) {
            slot = w;
            break;
        }
    }

    if (slot) |w| {
        w.proc_index = process.procIndex(proc);
        w.addr = addr;
        w.pml4_phys = pml4_phys;
        w.active = true;
    } else {
        futex_lock.unlock();
        return EAGAIN; // No free slots
    }

    // Block the process
    proc.state = .blocked;
    proc.pending_op = .none;
    proc.syscall_ret = 0;
    futex_lock.unlock();

    process.scheduleNext();
}

/// Futex wake: wake up to `count` waiters on the given address.
/// Returns the number of waiters woken.
pub fn wake(proc: *process.Process, addr: u64, count: u32) u64 {
    ensureInit();
    if (addr == 0) return 0;

    // Get the PML4 physical address for address space identity
    const pml4_phys: u64 = if (proc.thread_group) |tg|
        (if (tg.pml4) |p| @intFromPtr(p) else 0)
    else
        (if (proc.pml4) |p| @intFromPtr(p) else 0);

    futex_lock.lock();
    defer futex_lock.unlock();

    var woken: u64 = 0;
    for (&waiters) |*w| {
        if (woken >= count) break;
        if (w.active and w.addr == addr and w.pml4_phys == pml4_phys) {
            w.active = false;
            // Wake the blocked process
            const table = process.getProcessTable();
            const target = &table[w.proc_index];
            if (target.state == .blocked) {
                target.syscall_ret = 0;
                process.markReady(target);
            }
            woken += 1;
        }
    }

    return woken;
}

/// Wake a single waiter on a specific address (used by CLONE_CHILD_CLEARTID).
pub fn wakeOne(pml4_phys: u64, addr: u64) void {
    ensureInit();
    if (addr == 0) return;

    futex_lock.lock();
    defer futex_lock.unlock();

    for (&waiters) |*w| {
        if (w.active and w.addr == addr and w.pml4_phys == pml4_phys) {
            w.active = false;
            const table = process.getProcessTable();
            const target = &table[w.proc_index];
            if (target.state == .blocked) {
                target.syscall_ret = 0;
                process.markReady(target);
            }
            return;
        }
    }
}
