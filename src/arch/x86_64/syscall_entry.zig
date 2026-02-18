/// SYSCALL entry/exit for x86_64.
///
/// The actual assembly entry point lives in entry.S (syscall_entry).
/// This module handles MSR setup and provides the Zig dispatch function
/// called from assembly using System V ABI.
///
/// Per-CPU state (kernel_stack_top, saved_user_*, saved_kernel_rsp)
/// lives in percpu.AsmState, accessed via %gs segment override in entry.S.
///
/// Fornax syscall convention:
///   RAX = syscall number
///   RDI, RSI, RDX, R10, R8, R9 = args
///   RAX = return value (or -errno on error)
const cpu = @import("cpu.zig");
const klog = @import("../../klog.zig");
const percpu = @import("../../percpu.zig");

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

    klog.info("SYSCALL: MSRs configured\n");
}

/// Set the kernel stack for syscall entry (stored in per-CPU AsmState).
pub fn setKernelStack(stack_top: u64) void {
    percpu.getAsm().kernel_stack_top = stack_top;
}

/// Read saved user RIP from per-CPU AsmState.
pub inline fn getSavedUserRip() u64 {
    return percpu.getAsm().saved_user_rip;
}

/// Read saved user RSP from per-CPU AsmState.
pub inline fn getSavedUserRsp() u64 {
    return percpu.getAsm().saved_user_rsp;
}

/// Read saved user RFLAGS from per-CPU AsmState.
pub inline fn getSavedUserRflags() u64 {
    return percpu.getAsm().saved_user_rflags;
}

/// Read saved kernel RSP from per-CPU AsmState.
pub inline fn getSavedKernelRsp() u64 {
    return percpu.getAsm().saved_kernel_rsp;
}

/// Zig-level syscall dispatcher. Called from entry.S using System V ABI.
export fn syscallDispatch(nr: u64, arg0: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64) callconv(.{ .x86_64_sysv = .{} }) u64 {
    const syscall = @import("../../syscall.zig");
    return syscall.dispatch(nr, arg0, arg1, arg2, arg3, arg4);
}
