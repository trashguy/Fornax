/// RISC-V 64-bit CPU primitives for S-mode.
///
/// CSR operations, interrupt control, memory barriers, and MMIO access.
/// Replaces x86_64 I/O port operations with memory-mapped I/O.

// ── CSR numbers ──────────────────────────────────────────────────────
pub const CSR_SSTATUS: u12 = 0x100;
pub const CSR_SIE: u12 = 0x104;
pub const CSR_STVEC: u12 = 0x105;
pub const CSR_SSCRATCH: u12 = 0x140;
pub const CSR_SEPC: u12 = 0x141;
pub const CSR_SCAUSE: u12 = 0x142;
pub const CSR_STVAL: u12 = 0x143;
pub const CSR_SIP: u12 = 0x144;
pub const CSR_SATP: u12 = 0x180;
pub const CSR_TIME: u12 = 0xC01;

// ── SSTATUS bits ─────────────────────────────────────────────────────
pub const SSTATUS_SIE: u64 = 1 << 1; // Supervisor Interrupt Enable
pub const SSTATUS_SPIE: u64 = 1 << 5; // Previous Interrupt Enable
pub const SSTATUS_SPP: u64 = 1 << 8; // Previous Privilege (0=U, 1=S)
pub const SSTATUS_SUM: u64 = 1 << 18; // Supervisor User Memory access

// ── SIE bits ─────────────────────────────────────────────────────────
pub const SIE_SSIE: u64 = 1 << 1; // Supervisor Software Interrupt
pub const SIE_STIE: u64 = 1 << 5; // Supervisor Timer Interrupt
pub const SIE_SEIE: u64 = 1 << 9; // Supervisor External Interrupt

// ── SCAUSE codes ─────────────────────────────────────────────────────
pub const SCAUSE_INT_BIT: u64 = @as(u64, 1) << 63;
pub const SCAUSE_U_ECALL: u64 = 8;
pub const SCAUSE_S_ECALL: u64 = 9;
pub const SCAUSE_S_TIMER: u64 = SCAUSE_INT_BIT | 5;
pub const SCAUSE_S_EXTERNAL: u64 = SCAUSE_INT_BIT | 9;
pub const SCAUSE_INST_PAGE_FAULT: u64 = 12;
pub const SCAUSE_LOAD_PAGE_FAULT: u64 = 13;
pub const SCAUSE_STORE_PAGE_FAULT: u64 = 15;

// ── CPU control ──────────────────────────────────────────────────────
pub fn halt() noreturn {
    while (true) {
        asm volatile ("csrci sstatus, 0x2"); // clear SIE
        asm volatile ("wfi");
    }
}

pub fn disableInterrupts() void {
    asm volatile ("csrci sstatus, 0x2"); // clear SSTATUS.SIE (bit 1)
}

pub fn enableInterrupts() void {
    asm volatile ("csrsi sstatus, 0x2"); // set SSTATUS.SIE (bit 1)
}

/// Return true if supervisor interrupts are enabled (SSTATUS.SIE == 1).
pub fn interruptsEnabled() bool {
    const sstatus = asm volatile ("csrr %[ret], sstatus"
        : [ret] "=r" (-> u64),
    );
    return (sstatus & 0x2) != 0; // bit 1 = SIE
}

// ── CSR operations ───────────────────────────────────────────────────
pub inline fn csrRead(comptime csr: u12) u64 {
    return asm volatile ("csrr %[ret], " ++ csrName(csr)
        : [ret] "=r" (-> u64),
    );
}

pub inline fn csrWrite(comptime csr: u12, val: u64) void {
    asm volatile ("csrw " ++ csrName(csr) ++ ", %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn csrSet(comptime csr: u12, bits: u64) void {
    asm volatile ("csrs " ++ csrName(csr) ++ ", %[bits]"
        :
        : [bits] "r" (bits),
    );
}

pub inline fn csrClear(comptime csr: u12, bits: u64) void {
    asm volatile ("csrc " ++ csrName(csr) ++ ", %[bits]"
        :
        : [bits] "r" (bits),
    );
}

fn csrName(comptime csr: u12) *const [comptime_int_str_len(csr)]u8 {
    return comptime blk: {
        var buf: [comptime_int_str_len(csr)]u8 = undefined;
        const n = csr;
        var val = n;
        var i: usize = buf.len;
        while (i > 0) {
            i -= 1;
            buf[i] = '0' + @as(u8, @intCast(val % 10));
            val /= 10;
        }
        const result = buf;
        break :blk &result;
    };
}

fn comptime_int_str_len(comptime n: u12) usize {
    if (n == 0) return 1;
    var val: u32 = n;
    var len: usize = 0;
    while (val > 0) {
        val /= 10;
        len += 1;
    }
    return len;
}

pub inline fn spinHint() void {
    asm volatile ("nop");
}

/// Single WFI — yields the hart so QEMU can process pending device I/O.
pub inline fn hltOnce() void {
    asm volatile ("wfi");
}

// ── Memory barriers ──────────────────────────────────────────────────
pub fn fence() void {
    asm volatile ("fence rw, rw" ::: .{ .memory = true });
}

pub fn fenceI() void {
    asm volatile ("fence.i" ::: .{ .memory = true });
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

// ── SBI calls (ecall from S-mode to M-mode/SBI firmware) ─────────────
/// SBI set_timer — programs the next timer interrupt.
pub fn sbiSetTimer(stime_value: u64) void {
    asm volatile ("ecall"
        :
        : [a7] "{a7}" (@as(u64, 0x54494D45)), // SBI extension: TIME
          [a6] "{a6}" (@as(u64, 0)), // function: set_timer
          [a0] "{a0}" (stime_value),
        : .{ .memory = true }
    );
}

/// Read the `time` CSR (maps to mtime on QEMU virt).
pub inline fn rdtime() u64 {
    return asm volatile ("rdtime %[ret]"
        : [ret] "=r" (-> u64),
    );
}

/// SBI SRST shutdown (reset_type=0, reason=0).
pub fn acpiShutdown() noreturn {
    asm volatile ("ecall"
        :
        : [a7] "{a7}" (@as(u64, 0x53525354)), // SBI extension: SRST
          [a6] "{a6}" (@as(u64, 0)), // function: system_reset
          [a0] "{a0}" (@as(u64, 0)), // reset_type: shutdown
          [a1] "{a1}" (@as(u64, 0)), // reason: no reason
        : .{ .memory = true }
    );
    halt();
}

/// SBI SRST reboot (reset_type=1, reason=0).
pub fn resetSystem() noreturn {
    asm volatile ("ecall"
        :
        : [a7] "{a7}" (@as(u64, 0x53525354)), // SBI extension: SRST
          [a6] "{a6}" (@as(u64, 0)), // function: system_reset
          [a0] "{a0}" (@as(u64, 1)), // reset_type: warm reboot
          [a1] "{a1}" (@as(u64, 0)), // reason: no reason
        : .{ .memory = true }
    );
    halt();
}

/// SBI base extension call — returns (error, value) in a0/a1.
pub fn sbiBaseCall(fid: u64) struct { err: i64, val: u64 } {
    var err: i64 = undefined;
    var val: u64 = undefined;
    asm volatile ("ecall"
        : [a0] "={a0}" (err),
          [a1] "={a1}" (val),
        : [a7] "{a7}" (@as(u64, 0x10)), // SBI extension: BASE
          [a6] "{a6}" (fid),
        : .{ .memory = true }
    );
    return .{ .err = err, .val = val };
}

/// SBI get_mvendorid (base extension FID 4).
pub fn sbiGetMvendorid() u64 {
    const r = sbiBaseCall(4);
    return if (r.err == 0) r.val else 0;
}

/// SBI get_marchid (base extension FID 5).
pub fn sbiGetMarchid() u64 {
    const r = sbiBaseCall(5);
    return if (r.err == 0) r.val else 0;
}

/// SBI get_mimpid (base extension FID 6).
pub fn sbiGetMimpid() u64 {
    const r = sbiBaseCall(6);
    return if (r.err == 0) r.val else 0;
}

// ── SBI HSM (Hart State Management) ──────────────────────────────────
// Extension ID 0x48534D ("HSM")

/// SBI HSM hart_start — start a hart at the given physical address.
/// Returns 0 on success, SBI error code otherwise.
pub fn sbiHartStart(hartid: u64, start_addr: u64, priv_val: u64) i64 {
    var err: i64 = undefined;
    asm volatile ("ecall"
        : [a0] "={a0}" (err),
        : [a7] "{a7}" (@as(u64, 0x48534D)), // SBI extension: HSM
          [a6] "{a6}" (@as(u64, 0)), // function: hart_start
          [arg0] "{a0}" (hartid),
          [arg1] "{a1}" (start_addr),
          [arg2] "{a2}" (priv_val),
        : .{ .memory = true }
    );
    return err;
}

/// SBI HSM hart_get_status — query the state of a hart.
/// Returns: 0=STARTED, 1=STOPPED, 2=START_PENDING, 3=STOP_PENDING, etc.
/// Returns negative SBI error on failure.
pub fn sbiHartGetStatus(hartid: u64) i64 {
    var err: i64 = undefined;
    var val: i64 = undefined;
    asm volatile ("ecall"
        : [a0] "={a0}" (err),
          [a1] "={a1}" (val),
        : [a7] "{a7}" (@as(u64, 0x48534D)), // SBI extension: HSM
          [a6] "{a6}" (@as(u64, 2)), // function: hart_get_status
          [arg0] "{a0}" (hartid),
        : .{ .memory = true }
    );
    if (err < 0) return err; // SBI error
    return val; // Hart status
}

// ── SBI sPI (Send IPI) ──────────────────────────────────────────────
// Extension ID 0x735049 ("sPI")

/// SBI send IPI — send software interrupt to harts specified by mask.
/// hart_mask: bitmask of harts relative to hart_mask_base.
pub fn sbiSendIpi(hart_mask: u64, hart_mask_base: u64) void {
    asm volatile ("ecall"
        :
        : [a7] "{a7}" (@as(u64, 0x735049)), // SBI extension: sPI
          [a6] "{a6}" (@as(u64, 0)), // function: send_ipi
          [a0] "{a0}" (hart_mask),
          [a1] "{a1}" (hart_mask_base),
        : .{ .memory = true }
    );
}

// ── SCAUSE software interrupt ────────────────────────────────────────
pub const SCAUSE_S_SOFT: u64 = SCAUSE_INT_BIT | 1;

/// Full TLB flush (all ASIDs, all addresses).
pub inline fn sfenceVma() void {
    asm volatile ("sfence.vma" ::: .{ .memory = true });
}
