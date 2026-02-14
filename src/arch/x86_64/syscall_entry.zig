/// SYSCALL entry/exit for x86_64.
///
/// When SYSCALL executes:
///   - RCX = user RIP (return address)
///   - R11 = user RFLAGS
///   - CS/SS loaded from STAR MSR
///   - RIP loaded from LSTAR MSR
///   - RSP is NOT changed — still points to user stack
///
/// Fornax syscall convention:
///   RAX = syscall number
///   RDI, RSI, RDX, R10, R8, R9 = args
///   RAX = return value (or -errno on error)
const cpu = @import("cpu.zig");
const gdt = @import("gdt.zig");
const console = @import("../../console.zig");

/// Kernel stack top — set before entering userspace.
/// Used by the syscall entry to switch stacks.
export var kernel_stack_top: u64 = 0;

/// Saved user stack pointer during syscall.
export var saved_user_rsp: u64 = 0;

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

    // LSTAR MSR: syscall entry point
    const handler_addr = @intFromPtr(&syscallEntry);
    cpu.wrmsr(cpu.MSR_LSTAR, handler_addr);

    // SFMASK MSR: RFLAGS bits to clear on SYSCALL
    // Clear IF (bit 9), DF (bit 10), TF (bit 8)
    cpu.wrmsr(cpu.MSR_SFMASK, (1 << 9) | (1 << 10) | (1 << 8));

    console.puts("SYSCALL: MSRs configured\n");
}

/// Set the kernel stack for syscall entry.
pub fn setKernelStack(stack_top: u64) void {
    kernel_stack_top = stack_top;
}

/// SYSCALL entry point (naked).
fn syscallEntry() callconv(.naked) void {
    asm volatile (
    // We're in Ring 0 but still on user stack. Interrupts are off (SFMASK cleared IF).
    //
    // Save user RSP, switch to kernel stack.
    // We use the global kernel_stack_top since we don't have per-CPU areas yet.
        \\mov %%rsp, saved_user_rsp(%%rip)
        \\mov kernel_stack_top(%%rip), %%rsp
        \\
        // Push user context onto kernel stack
        \\push saved_user_rsp(%%rip)  // user RSP
        \\push %%rcx                   // user RIP
        \\push %%r11                   // user RFLAGS
        \\
        // Save callee-saved registers (Zig/C calling convention)
        \\push %%rbx
        \\push %%rbp
        \\push %%r12
        \\push %%r13
        \\push %%r14
        \\push %%r15
        \\
        // Prepare arguments for syscallDispatch(nr, a0, a1, a2, a3, a4)
        // Zig C ABI: RDI, RSI, RDX, RCX, R8, R9
        // Current: RAX=nr, RDI=a0, RSI=a1, RDX=a2, R10=a3, R8=a4
        // Need:    RDI=nr, RSI=a0, RDX=a1, RCX=a2, R8=a3, R9=a4
        \\mov %%r8, %%r9              // a4: R8 → R9
        \\mov %%r10, %%r8             // a3: R10 → R8
        \\mov %%rdx, %%rcx            // a2: RDX → RCX
        \\mov %%rsi, %%rdx            // a1: RSI → RDX
        \\mov %%rdi, %%rsi            // a0: RDI → RSI
        \\mov %%rax, %%rdi            // nr: RAX → RDI
        \\
        \\call syscallDispatch
        \\
        // RAX = return value, already in place for SYSRET
        \\
        // Restore callee-saved registers
        \\pop %%r15
        \\pop %%r14
        \\pop %%r13
        \\pop %%r12
        \\pop %%rbp
        \\pop %%rbx
        \\
        // Restore user context
        \\pop %%r11                   // user RFLAGS
        \\pop %%rcx                   // user RIP
        \\pop %%rsp                   // user RSP
        \\
        \\sysretq
    );
}

/// Zig-level syscall dispatcher. Called from asm entry.
export fn syscallDispatch(nr: u64, arg0: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64) callconv(.c) u64 {
    const syscall = @import("../../syscall.zig");
    return syscall.dispatch(nr, arg0, arg1, arg2, arg3, arg4);
}
