/// posix-realm — POSIX environment loader for Fornax.
///
/// This is a native Fornax program that runs BEFORE any POSIX binary.
/// The kernel loads it via PT_INTERP detection in sysSpawn. It:
///   1. Calls rfork(RFNAMEG) to isolate the namespace (Plan 9 style)
///   2. Jumps to the POSIX program's entry point
///
/// The program's original entry point is passed via RAX (syscall_ret),
/// which is placed in RAX by the kernel's resume_user_mode IRETQ path.
///
/// Linked at image_base = 0x20000000 to avoid overlap with programs at 0x40000000.

export fn _start() callconv(.naked) noreturn {
    // All inline asm — naked functions can't have runtime calls.
    //
    // On entry: RAX = program's entry point (set by kernel in syscall_ret)
    //
    // 1. Save program entry point (RAX) to R12 (callee-saved)
    // 2. rfork(RFNAMEG=0x01): SYS 25, arg in RDI
    // 3. Jump to saved program entry point
    asm volatile (
        \\  mov %%rax, %%r12           # Save program entry point
        \\  mov $25, %%eax             # SYS_rfork = 25
        \\  mov $0x01, %%edi           # RFNAMEG = 0x01
        \\  syscall
        \\  jmp *%%r12                 # Jump to POSIX program's _start
    );
    // End of naked function is implicitly unreachable
}
