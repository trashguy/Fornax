/// Per-CPU data structures for SMP support.
///
/// Two-part design:
///   1. AsmState (extern struct) — 5 u64 fields at known offsets, accessed
///      from entry.S via %gs:offset (x86_64) or TP-relative (riscv64).
///   2. PerCpu — Zig-level per-core state (run queue, core ID, etc.)
///
/// GS_BASE (after swapgs in SYSCALL entry) points to asm_states[core_id].
/// Zig code uses percpu.get() for PerCpu and percpu.getAsm() for AsmState.
const builtin = @import("builtin");
const SpinLock = @import("spinlock.zig").SpinLock;
const klog = @import("klog.zig");

pub const MAX_CORES = 128;
pub const RUN_QUEUE_SIZE = 64;

// ── Assembly-accessible state (extern struct = guaranteed C layout) ────

/// Per-CPU state accessed from assembly. Fields at fixed byte offsets.
/// GS_BASE points to the active core's AsmState on x86_64.
pub const AsmState = extern struct {
    /// Top of kernel stack for syscall/interrupt entry.
    kernel_stack_top: u64 = 0, // gs:0
    /// Saved user RSP on syscall entry.
    saved_user_rsp: u64 = 0, // gs:8
    /// Saved user RIP (from RCX on SYSCALL, SEPC on riscv64).
    saved_user_rip: u64 = 0, // gs:16
    /// Saved user RFLAGS (from R11 on SYSCALL, SSTATUS on riscv64).
    saved_user_rflags: u64 = 0, // gs:24
    /// Saved kernel RSP after building GPR frame (for resume_from_kernel_frame).
    saved_kernel_rsp: u64 = 0, // gs:32
    /// Per-CPU scheduler stack top. Used by scheduleNext to avoid sharing
    /// the process kernel stack with another core that resumes the process.
    scheduler_stack_top: u64 = 0, // gs:40
};

// Offsets for use in entry.S (verified by comptime assertions below).
pub const ASM_KERNEL_STACK_TOP = 0;
pub const ASM_SAVED_USER_RSP = 8;
pub const ASM_SAVED_USER_RIP = 16;
pub const ASM_SAVED_USER_RFLAGS = 24;
pub const ASM_SAVED_KERNEL_RSP = 32;

comptime {
    if (@offsetOf(AsmState, "kernel_stack_top") != ASM_KERNEL_STACK_TOP) @compileError("AsmState offset mismatch: kernel_stack_top");
    if (@offsetOf(AsmState, "saved_user_rsp") != ASM_SAVED_USER_RSP) @compileError("AsmState offset mismatch: saved_user_rsp");
    if (@offsetOf(AsmState, "saved_user_rip") != ASM_SAVED_USER_RIP) @compileError("AsmState offset mismatch: saved_user_rip");
    if (@offsetOf(AsmState, "saved_user_rflags") != ASM_SAVED_USER_RFLAGS) @compileError("AsmState offset mismatch: saved_user_rflags");
    if (@offsetOf(AsmState, "saved_kernel_rsp") != ASM_SAVED_KERNEL_RSP) @compileError("AsmState offset mismatch: saved_kernel_rsp");
    if (@sizeOf(AsmState) != 48) @compileError("AsmState size mismatch");
}

/// Per-core AsmState array. Index by core_id. GS_BASE points into this.
pub var asm_states: [MAX_CORES]AsmState = [_]AsmState{.{}} ** MAX_CORES;

// ── Zig-level per-CPU state ───────────────────────────────────────────

/// Circular run queue for per-core scheduling.
/// All operations are lock-protected: push is called from any core
/// (via markReady), pop from the owning core, steal from remote cores.
pub const RunQueue = struct {
    entries: [RUN_QUEUE_SIZE]u16 = [_]u16{0} ** RUN_QUEUE_SIZE,
    head: u32 = 0,
    tail: u32 = 0,
    len: u32 = 0,
    lock: SpinLock = .{},

    pub fn push(self: *RunQueue, pid: u16) bool {
        self.lock.lock();
        defer self.lock.unlock();
        // SMP invariant: only valid process indices should be pushed.
        const process_mod = @import("process.zig");
        if (pid >= process_mod.MAX_PROCESSES) {
            const klog_mod = @import("klog.zig");
            klog_mod.err("[RQ push: bad idx ");
            klog_mod.errDec(pid);
            klog_mod.err("]\n");
            return false;
        }
        if (self.len >= RUN_QUEUE_SIZE) return false;
        self.entries[self.tail % RUN_QUEUE_SIZE] = pid;
        self.tail +%= 1;
        // Atomic store so unsynchronized isEmpty() readers see a consistent value
        @atomicStore(u32, &self.len, self.len + 1, .release);
        return true;
    }

    pub fn pop(self: *RunQueue) ?u16 {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.len == 0) return null;
        const pid = self.entries[self.head % RUN_QUEUE_SIZE];
        self.head +%= 1;
        @atomicStore(u32, &self.len, self.len - 1, .release);
        return pid;
    }

    pub fn isEmpty(self: *const RunQueue) bool {
        return @atomicLoad(u32, &self.len, .acquire) == 0;
    }

    /// Steal half of victim's queue into self.
    /// Acquires self.lock then tryLock on victim to avoid ABBA deadlock.
    /// Returns number of entries stolen.
    pub fn stealHalf(self: *RunQueue, victim: *RunQueue, target_core: u8) u32 {
        const process_mod = @import("process.zig");
        self.lock.lock();
        if (!victim.lock.tryLock()) {
            self.lock.unlock();
            return 0; // Contended — skip this victim
        }
        defer self.lock.unlock();
        defer victim.lock.unlock();

        const to_steal = victim.len / 2;
        if (to_steal == 0) return 0;

        const table = process_mod.getProcessTable();
        var stolen: u32 = 0;
        while (stolen < to_steal) : (stolen += 1) {
            if (victim.len == 0) break;
            const pid = victim.entries[victim.head % RUN_QUEUE_SIZE];
            victim.head +%= 1;
            @atomicStore(u32, &victim.len, victim.len - 1, .release);

            if (self.len >= RUN_QUEUE_SIZE) break;
            self.entries[self.tail % RUN_QUEUE_SIZE] = pid;
            self.tail +%= 1;
            @atomicStore(u32, &self.len, self.len + 1, .release);

            // Update assigned_core under lock so no unlocked read is needed
            if (pid < process_mod.MAX_PROCESSES) {
                table[pid].assigned_core = target_core;
            }
        }
        return stolen;
    }
};

/// Per-CPU kernel state. One instance per core.
pub const PerCpu = struct {
    /// Logical core ID (0 = BSP).
    core_id: u8 = 0,
    /// Currently running process (null = idle).
    /// Stored as ?*anyopaque to avoid circular dependency with process.zig.
    /// Cast to ?*Process via process.getCurrent().
    current: ?*anyopaque = null,
    /// Per-core run queue.
    run_queue: RunQueue = .{},
    /// Number of idle ticks on this core.
    idle_ticks: u64 = 0,
    /// Pending IPI bitmap (bit 0 = schedule, bit 1 = TLB shootdown).
    ipi_pending: u8 = 0,
    /// TLB shootdown: if non-zero, full TLB flush requested.
    tlb_flush_pending: bool = false,
    /// Set to true once this core is online.
    online: bool = false,
    /// Per-core statistics counters.
    ctx_switches: u64 = 0,
    syscalls: u64 = 0,
    interrupts: u64 = 0,
    /// Guard against recursive kernel faults during recovery.
    in_fault_recovery: bool = false,
};

/// Array of per-CPU data. Index by core_id.
pub var percpu_array: [MAX_CORES]PerCpu = [_]PerCpu{.{}} ** MAX_CORES;

/// Number of cores currently online.
pub var cores_online: u8 = 0;

// ── Init + accessors ──────────────────────────────────────────────────

/// Initialize BSP (core 0) per-CPU state.
/// Called once during early boot, before any scheduling.
pub fn init() void {
    percpu_array[0].core_id = 0;
    percpu_array[0].online = true;
    cores_online = 1;

    if (builtin.cpu.arch == .x86_64) {
        const cpu = @import("arch/x86_64/cpu.zig");
        // KERNEL_GS_BASE (MSR 0xC0000102): swapgs swaps GS_BASE ↔ KERNEL_GS_BASE.
        // On SYSCALL entry, swapgs loads GS_BASE from this MSR.
        const MSR_KERNEL_GS_BASE = 0xC0000102;
        cpu.wrmsr(MSR_KERNEL_GS_BASE, @intFromPtr(&asm_states[0]));
        // Also set GS_BASE directly for initial kernel context (before first swapgs).
        const MSR_GS_BASE = 0xC0000101;
        cpu.wrmsr(MSR_GS_BASE, @intFromPtr(&asm_states[0]));
    } else if (builtin.cpu.arch == .riscv64) {
        // Set TP = &asm_states[0] for BSP. Entry.S uses TP as percpu pointer.
        asm volatile ("mv tp, %[v]"
            :
            : [v] "r" (@intFromPtr(&asm_states[0])),
        );
        // Also set SSCRATCH for first trap entry from U-mode
        const rv_cpu = @import("arch/riscv64/cpu.zig");
        rv_cpu.csrWrite(rv_cpu.CSR_SSCRATCH, @intFromPtr(&asm_states[0]));
    }

    // Allocate per-CPU scheduler stack for BSP.
    // scheduleNext runs on this stack to avoid sharing the process kernel
    // stack with another core that may resume the blocked process.
    // Must match KERNEL_STACK_PAGES since the scheduler calls deep functions
    // (switchTo, net.poll, stealHalf, etc.).
    const process = @import("process.zig");
    const pmm = @import("pmm.zig");
    const mem_mod = @import("mem.zig");
    const paging = switch (builtin.cpu.arch) {
        .x86_64 => @import("arch/x86_64/paging.zig"),
        .riscv64 => @import("arch/riscv64/paging.zig"),
        .aarch64 => @import("arch/aarch64/paging.zig"),
        else => unreachable,
    };
    if (pmm.allocContiguousPages(process.KERNEL_STACK_PAGES)) |phys_base| {
        const virt_base = @intFromPtr(paging.physPtr(phys_base));
        const virt_top = virt_base + process.KERNEL_STACK_PAGES * mem_mod.PAGE_SIZE;
        asm_states[0].scheduler_stack_top = virt_top;
    }

    klog.info("Per-CPU init: BSP (core 0) online.\n");
}

/// Get the current core's ID.
pub noinline fn getCoreId() u8 {
    if (builtin.cpu.arch == .x86_64) {
        // Before percpu.init() sets GS_BASE, we're on BSP (core 0)
        if (cores_online == 0) return 0;
        // Read GS_BASE MSR (0xC0000101), which points to asm_states[core_id].
        // Compute index from pointer offset into the asm_states array.
        const cpu = @import("arch/x86_64/cpu.zig");
        const gs_base = cpu.rdmsr(0xC0000101);
        const base = @intFromPtr(&asm_states[0]);
        const offset = gs_base -% base;
        const idx = offset / @sizeOf(AsmState);
        if (idx >= MAX_CORES) {
            // GS_BASE is corrupt — dump diagnostic and halt this core.
            // Returning a wrong core ID causes cascading cross-core corruption
            // (e.g. setKernelStack writing to wrong core's AsmState).
            const serial = @import("serial.zig");
            const process = @import("process.zig");
            serial.putChar('\n');
            serial.putChar('G');
            serial.putChar('S');
            serial.putChar('!');
            // GS_BASE, KERNEL_GS_BASE, base, LAPIC ID
            process.inlineHex(gs_base);
            serial.putChar(' ');
            process.inlineHex(cpu.rdmsr(0xC0000102)); // KERNEL_GS_BASE
            serial.putChar(' ');
            process.inlineHex(base);
            serial.putChar(' ');
            // Read LAPIC ID (MMIO at 0xFEE00020, bits 24-31)
            const lapic_id: u32 = asm volatile (
                "movl 0xFEE00020, %[out]"
                : [out] "=r" (-> u32),
            );
            process.inlineHex(lapic_id >> 24);
            serial.putChar('\n');
            // Halt this core — can't safely continue with wrong GS
            while (true) {
                asm volatile ("cli");
                asm volatile ("hlt");
            }
        }
        return @intCast(idx);
    } else if (builtin.cpu.arch == .riscv64) {
        // Before percpu.init() sets TP, we're on BSP (core 0)
        if (cores_online == 0) return 0;
        // TP = &asm_states[core_id]. Compute index from pointer offset.
        const tp_val = asm volatile ("mv %[out], tp"
            : [out] "=r" (-> u64),
        );
        const base = @intFromPtr(&asm_states[0]);
        const offset = tp_val -% base;
        const idx = offset / @sizeOf(AsmState);
        if (idx >= MAX_CORES) {
            // TP is corrupt — dump diagnostic and halt this core.
            const serial = @import("serial.zig");
            const process = @import("process.zig");
            serial.putChar('\n');
            serial.putChar('T');
            serial.putChar('P');
            serial.putChar('!');
            process.inlineHex(tp_val);
            serial.putChar(' ');
            process.inlineHex(base);
            serial.putChar('\n');
            const rv_cpu = @import("arch/riscv64/cpu.zig");
            rv_cpu.halt();
        }
        return @intCast(idx);
    } else {
        // aarch64 etc: single-core for now
        return 0;
    }
}

/// Get the current core's PerCpu struct.
pub inline fn get() *PerCpu {
    return &percpu_array[getCoreId()];
}

/// Get the current core's AsmState.
pub inline fn getAsm() *AsmState {
    return &asm_states[getCoreId()];
}
