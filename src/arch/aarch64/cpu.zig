/// AArch64 CPU primitives for EL1 (kernel mode).
///
/// System register access, interrupt control, memory barriers, MMIO access,
/// and PSCI power management calls via HVC.

// ── CPU control ──────────────────────────────────────────────────────

pub fn halt() noreturn {
    while (true) {
        asm volatile ("msr daifset, #0xF"); // mask all
        asm volatile ("wfi");
    }
}

pub fn disableInterrupts() void {
    asm volatile ("msr daifset, #0xF");
}

pub fn enableInterrupts() void {
    asm volatile ("msr daifclr, #0xF");
}

pub inline fn spinHint() void {
    asm volatile ("yield");
}

/// Single WFI — yields the core so QEMU can process pending device I/O.
pub inline fn hltOnce() void {
    asm volatile ("wfi");
}

// ── Memory barriers ──────────────────────────────────────────────────

pub fn isb() void {
    asm volatile ("isb");
}

pub fn dsb() void {
    asm volatile ("dsb sy");
}

pub fn dmb() void {
    asm volatile ("dmb sy");
}

// ── System register access ───────────────────────────────────────────

pub fn readEsr() u64 {
    return asm volatile ("mrs %[ret], esr_el1"
        : [ret] "=r" (-> u64),
    );
}

pub fn readElr() u64 {
    return asm volatile ("mrs %[ret], elr_el1"
        : [ret] "=r" (-> u64),
    );
}

pub fn readFar() u64 {
    return asm volatile ("mrs %[ret], far_el1"
        : [ret] "=r" (-> u64),
    );
}

pub fn readMidr() u64 {
    return asm volatile ("mrs %[ret], midr_el1"
        : [ret] "=r" (-> u64),
    );
}

pub fn readSctlr() u64 {
    return asm volatile ("mrs %[ret], sctlr_el1"
        : [ret] "=r" (-> u64),
    );
}

pub fn writeSctlr(val: u64) void {
    asm volatile ("msr sctlr_el1, %[val]"
        :
        : [val] "r" (val),
    );
}

pub fn readTcr() u64 {
    return asm volatile ("mrs %[ret], tcr_el1"
        : [ret] "=r" (-> u64),
    );
}

pub fn writeTcr(val: u64) void {
    asm volatile ("msr tcr_el1, %[val]"
        :
        : [val] "r" (val),
    );
}

pub fn readMair() u64 {
    return asm volatile ("mrs %[ret], mair_el1"
        : [ret] "=r" (-> u64),
    );
}

pub fn writeMair(val: u64) void {
    asm volatile ("msr mair_el1, %[val]"
        :
        : [val] "r" (val),
    );
}

pub fn readTtbr0() u64 {
    return asm volatile ("mrs %[ret], ttbr0_el1"
        : [ret] "=r" (-> u64),
    );
}

pub fn writeTtbr0(val: u64) void {
    asm volatile ("msr ttbr0_el1, %[val]"
        :
        : [val] "r" (val),
    );
}

pub fn readTtbr1() u64 {
    return asm volatile ("mrs %[ret], ttbr1_el1"
        : [ret] "=r" (-> u64),
    );
}

pub fn writeTtbr1(val: u64) void {
    asm volatile ("msr ttbr1_el1, %[val]"
        :
        : [val] "r" (val),
    );
}

/// Invalidate entire TLB (all ASIDs).
pub fn tlbiAll() void {
    asm volatile ("tlbi vmalle1is" ::: .{ .memory = true });
    dsb();
    isb();
}

// ── Generic Timer registers ─────────────────────────────────────────

/// Read timer frequency (CNTFRQ_EL0).
pub fn readCntfrq() u64 {
    return asm volatile ("mrs %[ret], cntfrq_el0"
        : [ret] "=r" (-> u64),
    );
}

/// Read virtual counter (CNTVCT_EL0) — monotonic timestamp.
pub fn readCntvct() u64 {
    return asm volatile ("mrs %[ret], cntvct_el0"
        : [ret] "=r" (-> u64),
    );
}

/// Write physical timer value (CNTP_TVAL_EL0) — re-arm timer.
pub fn writeCntpTval(val: u32) void {
    asm volatile ("msr cntp_tval_el0, %[val]"
        :
        : [val] "r" (@as(u64, val)),
    );
}

/// Write physical timer control (CNTP_CTL_EL0).
/// Bit 0 = ENABLE, Bit 1 = IMASK (mask interrupt).
pub fn writeCntpCtl(val: u32) void {
    asm volatile ("msr cntp_ctl_el0, %[val]"
        :
        : [val] "r" (@as(u64, val)),
    );
}

// ── MMIO access (replaces I/O ports) ─────────────────────────────────

pub fn mmioRead8(addr: u64) u8 {
    return @as(*volatile u8, @ptrFromInt(addr)).*;
}

pub fn mmioWrite8(addr: u64, val: u8) void {
    @as(*volatile u8, @ptrFromInt(addr)).* = val;
}

pub fn mmioRead16(addr: u64) u16 {
    return @as(*volatile u16, @ptrFromInt(addr)).*;
}

pub fn mmioWrite16(addr: u64, val: u16) void {
    @as(*volatile u16, @ptrFromInt(addr)).* = val;
}

pub fn mmioRead32(addr: u64) u32 {
    return @as(*volatile u32, @ptrFromInt(addr)).*;
}

pub fn mmioWrite32(addr: u64, val: u32) void {
    @as(*volatile u32, @ptrFromInt(addr)).* = val;
}

// ── PSCI power management (via HVC) ──────────────────────────────────

/// PSCI SYSTEM_OFF (0x84000008) — power off.
pub fn acpiShutdown() noreturn {
    asm volatile (
        \\mov x0, #0x8400
        \\lsl x0, x0, #16
        \\add x0, x0, #0x0008
        \\hvc #0
    );
    halt();
}

/// PSCI SYSTEM_RESET (0x84000009) — warm reboot.
pub fn resetSystem() noreturn {
    asm volatile (
        \\mov x0, #0x8400
        \\lsl x0, x0, #16
        \\add x0, x0, #0x0009
        \\hvc #0
    );
    halt();
}

/// PSCI CPU_ON (0xC4000003) — start a secondary CPU.
/// target_cpu = MPIDR affinity value, entry_point = physical address,
/// context_id = opaque value passed to the target CPU.
/// Returns 0 on success, negative PSCI error code on failure.
pub fn psciCpuOn(target_cpu: u64, entry_point: u64, context_id: u64) i64 {
    return asm volatile (
        \\hvc #0
        : [ret] "={x0}" (-> i64),
        : [fid] "{x0}" (@as(u64, 0xC4000003)),
          [cpu] "{x1}" (target_cpu),
          [ep] "{x2}" (entry_point),
          [ctx] "{x3}" (context_id),
        : .{.memory = true});
}

/// PSCI AFFINITY_INFO (0xC4000004) — query CPU power state.
/// Returns 0=ON, 1=OFF, 2=ON_PENDING.
pub fn psciAffinityInfo(target_cpu: u64) i64 {
    return asm volatile (
        \\hvc #0
        : [ret] "={x0}" (-> i64),
        : [fid] "{x0}" (@as(u64, 0xC4000004)),
          [cpu] "{x1}" (target_cpu),
          [aff] "{x2}" (@as(u64, 0)), // lowest affinity level
        : .{.memory = true});
}

// ── Per-CPU register (TPIDR_EL1) ────────────────────────────────────

/// Read TPIDR_EL1 — kernel-only per-CPU pointer register.
pub inline fn readTpidrEl1() u64 {
    return asm volatile ("mrs %[ret], tpidr_el1"
        : [ret] "=r" (-> u64),
    );
}

/// Write TPIDR_EL1 — set per-CPU pointer for this core.
pub inline fn writeTpidrEl1(val: u64) void {
    asm volatile ("msr tpidr_el1, %[val]"
        :
        : [val] "r" (val),
    );
}

// ── MPIDR (core identification) ─────────────────────────────────────

/// Read MPIDR_EL1 — multiprocessor affinity register.
/// On QEMU virt, bits [7:0] (Aff0) = core ID.
pub inline fn readMpidr() u64 {
    return asm volatile ("mrs %[ret], mpidr_el1"
        : [ret] "=r" (-> u64),
    );
}

// ── TLB flush (naming consistency with x86_64/riscv64) ──────────────

/// Flush entire TLB — alias for tlbiAll().
pub fn flushTlb() void {
    tlbiAll();
}
