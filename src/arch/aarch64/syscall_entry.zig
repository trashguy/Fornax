/// AArch64 SVC-based syscall entry setup.
///
/// On AArch64, user traps enter via the exception vector table in entry.S.
/// Hardware automatically switches to SP_EL1 on EL0→EL1 transition (when SPSel=1).
/// The kernel stack top is loaded into SP_EL1 via setKernelStack().
///
/// SMP: entry.S saves user context via TPIDR_EL1 → per-CPU AsmState.
/// Getters read from percpu, not globals.
const klog = @import("../../klog.zig");
const percpu = @import("../../percpu.zig");
const syscall = @import("../../syscall.zig");
const cpu = @import("cpu.zig");

/// Assembly entry points from entry.S.
pub extern fn resume_from_kernel_frame(saved_ksp: u64) callconv(.c) noreturn;

/// Initialize trap handling for AArch64.
pub fn init() void {
    // Set VBAR_EL1 to our vector table
    const vbar = @intFromPtr(&exception_vectors);
    asm volatile ("msr vbar_el1, %[vbar]"
        :
        : [vbar] "r" (vbar),
    );
    cpu.isb();

    // Ensure SPSel = 1 (use SP_EL1 in EL1 mode)
    asm volatile ("msr spsel, #1");
    cpu.isb();

    klog.info("aarch64: SVC trap entry configured\n");
}

extern const exception_vectors: u8;

/// Set the kernel stack for trap entry.
/// On AArch64, SP_EL1 is the active kernel stack. This function updates
/// the per-CPU AsmState so resume_user_mode reads the correct value.
pub fn setKernelStack(stack_top: u64) void {
    percpu.getAsm().kernel_stack_top = stack_top;
}

pub inline fn getSavedUserRip() u64 {
    return percpu.getAsm().saved_user_rip;
}

pub inline fn getSavedUserRsp() u64 {
    return percpu.getAsm().saved_user_rsp;
}

pub inline fn getSavedUserRflags() u64 {
    return percpu.getAsm().saved_user_rflags;
}

pub inline fn getSavedKernelRsp() u64 {
    return percpu.getAsm().saved_kernel_rsp;
}

/// Syscall dispatch — called from entry.S after remapping registers.
/// AArch64 convention: x8=nr, x0-x4=args. Entry.S remaps to C ABI:
///   x0=nr, x1=arg0, x2=arg1, x3=arg2, x4=arg3, x5=arg4.
export fn syscallDispatch(nr: u64, arg0: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64) callconv(.c) u64 {
    return syscall.dispatch(nr, arg0, arg1, arg2, arg3, arg4);
}
