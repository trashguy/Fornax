/// SYSCALL entry/exit for x86_64.
///
/// The actual assembly entry point lives in entry.S (syscall_entry).
/// This module handles MSR setup and provides the Zig dispatch function
/// called from assembly using System V ABI.
///
/// Fornax syscall convention:
///   RAX = syscall number
///   RDI, RSI, RDX, R10, R8, R9 = args
///   RAX = return value (or -errno on error)
const cpu = @import("cpu.zig");
const console = @import("../../console.zig");

/// Kernel stack top — set before entering userspace.
/// Used by the syscall entry asm to switch stacks.
pub export var kernel_stack_top: u64 = 0;

/// Saved user stack pointer during syscall.
pub export var saved_user_rsp: u64 = 0;

/// Saved user instruction pointer (from RCX).
pub export var saved_user_rip: u64 = 0;

/// Saved user RFLAGS (from R11).
pub export var saved_user_rflags: u64 = 0;

/// Saved kernel RSP after pushing the full GPR frame.
/// Used to resume blocked processes via their kernel stack.
pub export var saved_kernel_rsp: u64 = 0;

/// Assembly entry point defined in entry.S.
extern fn syscall_entry() callconv(.naked) void;

/// Resume a blocked process by restoring the GPR frame from its kernel stack.
/// The caller must write syscall_ret into frame[12] (the saved RAX slot) first.
pub extern fn resume_from_kernel_frame(saved_ksp: u64) callconv(.{ .x86_64_sysv = .{} }) noreturn;

/// Initialize the SYSCALL/SYSRET mechanism.
pub fn init() void {
    // Enable SCE (System Call Extensions) in EFER MSR
    const efer = cpu.rdmsr(cpu.MSR_EFER);
    cpu.wrmsr(cpu.MSR_EFER, efer | cpu.EFER_SCE);

    // STAR MSR: segment selectors
    // Bits [47:32] = kernel CS selector (for SYSCALL): 0x08
    // Bits [63:48] = user base selector (for SYSRET): 0x10
    //   SYSRET 64-bit: CS = 0x10 + 16 = 0x20, SS = 0x10 + 8 = 0x18
    const star: u64 = (@as(u64, 0x10) << 48) | (@as(u64, 0x08) << 32);
    cpu.wrmsr(cpu.MSR_STAR, star);

    // LSTAR MSR: syscall entry point (in entry.S)
    cpu.wrmsr(cpu.MSR_LSTAR, @intFromPtr(&syscall_entry));

    // SFMASK MSR: RFLAGS bits to clear on SYSCALL
    // Clear IF (bit 9), DF (bit 10), TF (bit 8)
    cpu.wrmsr(cpu.MSR_SFMASK, (1 << 9) | (1 << 10) | (1 << 8));

    console.puts("SYSCALL: MSRs configured\n");
}

/// Set the kernel stack for syscall entry.
pub fn setKernelStack(stack_top: u64) void {
    kernel_stack_top = stack_top;
}

/// Zig-level syscall dispatcher. Called from entry.S using System V ABI.
export fn syscallDispatch(nr: u64, arg0: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64) callconv(.{ .x86_64_sysv = .{} }) u64 {
    const syscall = @import("../../syscall.zig");
    return syscall.dispatch(nr, arg0, arg1, arg2, arg3, arg4);
}
