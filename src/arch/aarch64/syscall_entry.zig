/// AArch64 SVC-based syscall entry setup.
///
/// On AArch64, user traps enter via the exception vector table in entry.S.
/// Hardware automatically switches to SP_EL1 on EL0→EL1 transition (when SPSel=1).
/// The kernel stack top is loaded into SP_EL1 via setKernelStack().
const klog = @import("../../klog.zig");
const percpu = @import("../../percpu.zig");
const syscall = @import("../../syscall.zig");
const cpu = @import("cpu.zig");

/// Kernel stack top for the current process.
/// Entry.S reads SP_EL1 directly (set via setKernelStack → msr sp_el1).
pub export var kernel_stack_top: u64 = 0;

/// Saved user context (written by entry.S, read by process.zig).
pub export var saved_user_rsp: u64 = 0;
pub export var saved_user_rip: u64 = 0;
pub export var saved_user_rflags: u64 = 0;
pub export var saved_kernel_rsp: u64 = 0;

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
/// On AArch64, we write to SP_EL1 which the hardware loads automatically
/// on EL0→EL1 transitions. But since we're already in EL1, we need to
/// temporarily switch to SP_EL0, write SP_EL1, then switch back.
/// Actually, on AArch64 we can't directly write SP_EL1 while using it.
/// Instead, we store it and entry.S uses SP (which IS SP_EL1 after SPSel=1).
/// The kernel stack is already active via SP — this function is called
/// during context switch to update SP before returning to userspace.
pub fn setKernelStack(stack_top: u64) void {
    kernel_stack_top = stack_top;
    percpu.getAsm().kernel_stack_top = stack_top;
}

pub inline fn getSavedUserRip() u64 {
    return saved_user_rip;
}

pub inline fn getSavedUserRsp() u64 {
    return saved_user_rsp;
}

pub inline fn getSavedUserRflags() u64 {
    return saved_user_rflags;
}

pub inline fn getSavedKernelRsp() u64 {
    return saved_kernel_rsp;
}

/// Syscall dispatch — called from entry.S after remapping registers.
/// AArch64 convention: x8=nr, x0-x4=args. Entry.S remaps to C ABI:
///   x0=nr, x1=arg0, x2=arg1, x3=arg2, x4=arg3, x5=arg4.
export fn syscallDispatch(nr: u64, arg0: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64) callconv(.c) u64 {
    return syscall.dispatch(nr, arg0, arg1, arg2, arg3, arg4);
}
