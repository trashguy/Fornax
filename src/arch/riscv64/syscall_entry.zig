/// ECALL entry/exit for RISC-V 64-bit.
///
/// The actual trap entry point lives in entry.S (trap_entry).
/// This module handles STVEC setup and provides the Zig dispatch function
/// called from assembly using RISC-V C ABI.
///
/// Fornax ECALL convention:
///   a7 = syscall number
///   a0, a1, a2, a3, a4 = args
///   a0 = return value
const cpu = @import("cpu.zig");
const klog = @import("../../klog.zig");

/// Kernel stack top — set before entering userspace.
/// Used by the trap entry asm to switch stacks.
pub export var kernel_stack_top: u64 = 0;

/// Saved user stack pointer during trap.
pub export var saved_user_rsp: u64 = 0;

/// Saved user instruction pointer (SEPC).
pub export var saved_user_rip: u64 = 0;

/// Saved user SSTATUS (mapped to "rflags" name for process.zig compatibility).
pub export var saved_user_rflags: u64 = 0;

/// Saved kernel RSP after building the trap frame.
/// Used to resume blocked processes via their kernel stack.
pub export var saved_kernel_rsp: u64 = 0;

/// Assembly entry point defined in entry.S.
extern fn trap_entry() callconv(.naked) void;

/// Resume a blocked process by restoring the trap frame from its kernel stack.
/// The caller must write syscall_ret into frame[9] (the saved a0 slot) first.
pub extern fn resume_from_kernel_frame(saved_ksp: u64) callconv(.c) noreturn;

/// Initialize the trap handling mechanism.
pub fn init() void {
    // Set STVEC = trap_entry (direct mode, aligned to 4 bytes → mode bits = 0)
    cpu.csrWrite(cpu.CSR_STVEC, @intFromPtr(&trap_entry));

    // Enable supervisor interrupts: SEIE (external), STIE (timer), SSIE (software)
    cpu.csrSet(cpu.CSR_SIE, cpu.SIE_SEIE | cpu.SIE_STIE | cpu.SIE_SSIE);

    // Set SSTATUS.SUM = 1 so S-mode can access U-mode pages.
    // Fornax kernel runs with user page tables (no CR3 switch on syscall),
    // so we need SUM to read/write user memory from kernel code.
    cpu.csrSet(cpu.CSR_SSTATUS, cpu.SSTATUS_SUM);

    klog.info("STVEC: trap entry configured\n");
}

/// Set the kernel stack for trap entry.
pub fn setKernelStack(stack_top: u64) void {
    kernel_stack_top = stack_top;
    // Also update SSCRATCH for the next trap entry from U-mode
    cpu.csrWrite(cpu.CSR_SSCRATCH, stack_top);
}

/// Zig-level syscall dispatcher. Called from entry.S using C ABI.
export fn syscallDispatch(nr: u64, arg0: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64) callconv(.c) u64 {
    const syscall = @import("../../syscall.zig");
    return syscall.dispatch(nr, arg0, arg1, arg2, arg3, arg4);
}
