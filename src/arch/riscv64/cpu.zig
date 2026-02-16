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
