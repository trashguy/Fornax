// AArch64 exception vector table and trap entry/exit.
//
// Trap frame layout (36 slots x 8 = 288 bytes, 16-byte aligned):
//   [sp +  0*8] = x0    (syscall return value slot)
//   [sp +  1*8] = x1
//   ...
//   [sp + 30*8] = x30   (LR)
//   [sp + 31*8] = SP_EL0   (user stack pointer)
//   [sp + 32*8] = ELR_EL1  (user PC)
//   [sp + 33*8] = SPSR_EL1 (user PSTATE)
//   [sp + 34-35] = padding (to 288 bytes, 16-byte aligned)
//
// AArch64 advantage: hardware automatically switches to SP_EL1 on exception
// from EL0 (when SPSel=1), so no scratch register swap is needed.
// SP_EL1 is the kernel stack set via syscall_entry.setKernelStack().

#define FRAME_SIZE 288

// ──────────────────────────────────────────────────────────────────────
// Exception vector table — must be 2048-byte aligned.
// 16 entries at 128-byte intervals (32 instructions max each).
// ──────────────────────────────────────────────────────────────────────

    .section .text
    .global exception_vectors
    .balign 2048
exception_vectors:

// Group 0: Current EL with SP_EL0 (should not happen — we use SPSel=1)
    // Vector 0: Synchronous
    .balign 128
    b       unhandled_exception
    // Vector 1: IRQ
    .balign 128
    b       unhandled_exception
    // Vector 2: FIQ
    .balign 128
    b       unhandled_exception
    // Vector 3: SError
    .balign 128
    b       unhandled_exception

// Group 1: Current EL with SP_ELx (kernel-mode exceptions/IRQs)
    // Vector 4: Synchronous (kernel fault)
    .balign 128
    b       kernel_exception
    // Vector 5: IRQ (kernel-mode IRQ)
    .balign 128
    b       kernel_irq
    // Vector 6: FIQ
    .balign 128
    b       unhandled_exception
    // Vector 7: SError
    .balign 128
    b       unhandled_exception

// Group 2: Lower EL using AArch64 (user traps — our primary handlers)
    // Vector 8: Synchronous (SVC, data abort, etc.)
    .balign 128
    b       user_sync_entry
    // Vector 9: IRQ
    .balign 128
    b       user_irq_entry
    // Vector 10: FIQ
    .balign 128
    b       unhandled_exception
    // Vector 11: SError
    .balign 128
    b       unhandled_exception

// Group 3: Lower EL using AArch32 (not used)
    // Vectors 12-15
    .balign 128
    b       unhandled_exception
    .balign 128
    b       unhandled_exception
    .balign 128
    b       unhandled_exception
    .balign 128
    b       unhandled_exception

// ──────────────────────────────────────────────────────────────────────
// Unhandled exception — call Zig handler and halt
// ──────────────────────────────────────────────────────────────────────
unhandled_exception:
    b       unhandled_exception  // spin (Zig exception handler via VBAR)

// ──────────────────────────────────────────────────────────────────────
// Kernel-mode exception (vector 4) — save minimal state and call handler
// ──────────────────────────────────────────────────────────────────────
kernel_exception:
    // Save caller-saved registers for the Zig handler call
    stp     x29, x30, [sp, #-16]!
    mrs     x0, esr_el1
    mrs     x1, elr_el1
    mrs     x2, far_el1
    bl      handleKernelException
    ldp     x29, x30, [sp], #16
    eret

// ──────────────────────────────────────────────────────────────────────
// Kernel-mode IRQ (vector 5) — save caller-saved and dispatch
// ──────────────────────────────────────────────────────────────────────
kernel_irq:
    stp     x29, x30, [sp, #-16]!
    stp     x0, x1, [sp, #-16]!
    stp     x2, x3, [sp, #-16]!
    stp     x4, x5, [sp, #-16]!
    stp     x6, x7, [sp, #-16]!
    stp     x8, x9, [sp, #-16]!
    stp     x10, x11, [sp, #-16]!
    stp     x12, x13, [sp, #-16]!
    stp     x14, x15, [sp, #-16]!
    stp     x16, x17, [sp, #-16]!
    stp     x18, x19, [sp, #-16]!  // save x18 too (platform register)
    bl      handleInterruptAa64
    ldp     x18, x19, [sp], #16
    ldp     x16, x17, [sp], #16
    ldp     x14, x15, [sp], #16
    ldp     x12, x13, [sp], #16
    ldp     x10, x11, [sp], #16
    ldp     x8, x9, [sp], #16
    ldp     x6, x7, [sp], #16
    ldp     x4, x5, [sp], #16
    ldp     x2, x3, [sp], #16
    ldp     x0, x1, [sp], #16
    ldp     x29, x30, [sp], #16
    eret

// ──────────────────────────────────────────────────────────────────────
// User synchronous exception entry (vector 8)
// Handles SVC (syscalls), data aborts, instruction aborts, etc.
// ──────────────────────────────────────────────────────────────────────
user_sync_entry:
    // SP is already SP_EL1 (kernel stack) — hardware switched on EL0→EL1 trap
    sub     sp, sp, #FRAME_SIZE

    // Save x0-x30
    stp     x0,  x1,  [sp, #0*8]
    stp     x2,  x3,  [sp, #2*8]
    stp     x4,  x5,  [sp, #4*8]
    stp     x6,  x7,  [sp, #6*8]
    stp     x8,  x9,  [sp, #8*8]
    stp     x10, x11, [sp, #10*8]
    stp     x12, x13, [sp, #12*8]
    stp     x14, x15, [sp, #14*8]
    stp     x16, x17, [sp, #16*8]
    stp     x18, x19, [sp, #18*8]
    stp     x20, x21, [sp, #20*8]
    stp     x22, x23, [sp, #22*8]
    stp     x24, x25, [sp, #24*8]
    stp     x26, x27, [sp, #26*8]
    stp     x28, x29, [sp, #28*8]
    str     x30,      [sp, #30*8]

    // Save SP_EL0 (user stack pointer)
    mrs     x0, sp_el0
    str     x0, [sp, #31*8]

    // Save ELR_EL1 (user PC)
    mrs     x0, elr_el1
    str     x0, [sp, #32*8]

    // Save SPSR_EL1 (user PSTATE)
    mrs     x0, spsr_el1
    str     x0, [sp, #33*8]

    // Save per-CPU state via TPIDR_EL1 (per-CPU AsmState pointer)
    mrs     x1, tpidr_el1                     // per-CPU AsmState ptr
    mov     x0, sp
    str     x0, [x1, #32]                     // saved_kernel_rsp
    ldr     x0, [sp, #32*8]                   // ELR_EL1
    str     x0, [x1, #16]                     // saved_user_rip
    ldr     x0, [sp, #31*8]                   // SP_EL0
    str     x0, [x1, #8]                      // saved_user_rsp
    ldr     x0, [sp, #33*8]                   // SPSR_EL1
    str     x0, [x1, #24]                     // saved_user_rflags

    // Check exception class (ESR_EL1 bits [31:26])
    mrs     x0, esr_el1
    lsr     x0, x0, #26
    and     x0, x0, #0x3F

    cmp     x0, #0x15          // EC = 0x15 → SVC from AArch64
    b.eq    handle_svc

    // Not SVC — synchronous exception (data/instruction abort, etc.)
    mrs     x0, esr_el1
    mrs     x1, elr_el1
    mrs     x2, far_el1
    mov     x3, sp              // frame pointer
    bl      handleUserException
    b       trap_return

handle_svc:
    // SVC syscall dispatch
    // AArch64 Fornax convention: x8=syscall number, x0-x4=args
    // C ABI for syscallDispatch: x0=nr, x1-x5=args
    ldr     x5, [sp, #4*8]     // arg4 (original x4)
    ldr     x4, [sp, #3*8]     // arg3 (original x3)
    ldr     x3, [sp, #2*8]     // arg2 (original x2)
    ldr     x2, [sp, #1*8]     // arg1 (original x1)
    ldr     x1, [sp, #0*8]     // arg0 (original x0)
    ldr     x0, [sp, #8*8]     // syscall nr (original x8)
    bl      syscallDispatch

    // Store return value in frame x0 slot
    str     x0, [sp, #0*8]

    // NOTE: On AArch64, hardware sets ELR_EL1 to the instruction AFTER
    // the SVC (preferred return address). No manual advance needed.
    // This differs from RISC-V ecall where EPC points AT the instruction.

    b       trap_return

// ──────────────────────────────────────────────────────────────────────
// User IRQ entry (vector 9)
// ──────────────────────────────────────────────────────────────────────
user_irq_entry:
    sub     sp, sp, #FRAME_SIZE

    // Save all registers (same as user_sync_entry)
    stp     x0,  x1,  [sp, #0*8]
    stp     x2,  x3,  [sp, #2*8]
    stp     x4,  x5,  [sp, #4*8]
    stp     x6,  x7,  [sp, #6*8]
    stp     x8,  x9,  [sp, #8*8]
    stp     x10, x11, [sp, #10*8]
    stp     x12, x13, [sp, #12*8]
    stp     x14, x15, [sp, #14*8]
    stp     x16, x17, [sp, #16*8]
    stp     x18, x19, [sp, #18*8]
    stp     x20, x21, [sp, #20*8]
    stp     x22, x23, [sp, #22*8]
    stp     x24, x25, [sp, #24*8]
    stp     x26, x27, [sp, #26*8]
    stp     x28, x29, [sp, #28*8]
    str     x30,      [sp, #30*8]

    mrs     x0, sp_el0
    str     x0, [sp, #31*8]
    mrs     x0, elr_el1
    str     x0, [sp, #32*8]
    mrs     x0, spsr_el1
    str     x0, [sp, #33*8]

    // Save per-CPU state via TPIDR_EL1
    mrs     x1, tpidr_el1
    mov     x0, sp
    str     x0, [x1, #32]                     // saved_kernel_rsp
    ldr     x0, [sp, #32*8]
    str     x0, [x1, #16]                     // saved_user_rip
    ldr     x0, [sp, #31*8]
    str     x0, [x1, #8]                      // saved_user_rsp
    ldr     x0, [sp, #33*8]
    str     x0, [x1, #24]                     // saved_user_rflags

    // Dispatch interrupt
    bl      handleInterruptAa64

    b       trap_return

// ──────────────────────────────────────────────────────────────────────
// trap_return — restore context and eret to user mode
// ──────────────────────────────────────────────────────────────────────
    .global trap_return
trap_return:
    // Restore SPSR_EL1
    ldr     x0, [sp, #33*8]
    msr     spsr_el1, x0

    // Restore ELR_EL1
    ldr     x0, [sp, #32*8]
    msr     elr_el1, x0

    // Restore SP_EL0
    ldr     x0, [sp, #31*8]
    msr     sp_el0, x0

    // Restore x30
    ldr     x30, [sp, #30*8]

    // Restore x0-x29
    ldp     x28, x29, [sp, #28*8]
    ldp     x26, x27, [sp, #26*8]
    ldp     x24, x25, [sp, #24*8]
    ldp     x22, x23, [sp, #22*8]
    ldp     x20, x21, [sp, #20*8]
    ldp     x18, x19, [sp, #18*8]
    ldp     x16, x17, [sp, #16*8]
    ldp     x14, x15, [sp, #14*8]
    ldp     x12, x13, [sp, #12*8]
    ldp     x10, x11, [sp, #10*8]
    ldp     x8,  x9,  [sp, #8*8]
    ldp     x6,  x7,  [sp, #6*8]
    ldp     x4,  x5,  [sp, #4*8]
    ldp     x2,  x3,  [sp, #2*8]
    ldp     x0,  x1,  [sp, #0*8]

    // Deallocate frame
    add     sp, sp, #FRAME_SIZE

    eret

// ──────────────────────────────────────────────────────────────────────
// resume_user_mode — first-time entry to user mode (never entered kernel via trap)
// x0 = entry_rip, x1 = user_sp, x2 = spsr, x3 = return_value
// ──────────────────────────────────────────────────────────────────────
    .global resume_user_mode
resume_user_mode:
    msr     elr_el1, x0         // set return address
    msr     spsr_el1, x2        // set saved PSTATE
    msr     sp_el0, x1          // set user stack pointer

    // Set SP_EL1 to this process's kernel stack top so the next
    // EL0→EL1 trap uses the correct kernel stack (not the scheduler's).
    mrs     x4, tpidr_el1
    ldr     x4, [x4, #0]                      // ASM_KERNEL_STACK_TOP
    mov     sp, x4

    // Return value in x0
    mov     x0, x3

    // Clear all other registers for clean userspace entry
    mov     x1, #0
    mov     x2, #0
    mov     x3, #0
    mov     x4, #0
    mov     x5, #0
    mov     x6, #0
    mov     x7, #0
    mov     x8, #0
    mov     x9, #0
    mov     x10, #0
    mov     x11, #0
    mov     x12, #0
    mov     x13, #0
    mov     x14, #0
    mov     x15, #0
    mov     x16, #0
    mov     x17, #0
    mov     x18, #0
    mov     x19, #0
    mov     x20, #0
    mov     x21, #0
    mov     x22, #0
    mov     x23, #0
    mov     x24, #0
    mov     x25, #0
    mov     x26, #0
    mov     x27, #0
    mov     x28, #0
    mov     x29, #0
    mov     x30, #0

    eret

// ──────────────────────────────────────────────────────────────────────
// resume_from_kernel_frame — resume a blocked process from its saved kernel stack
// x0 = saved kernel RSP (points to trap frame base)
// ──────────────────────────────────────────────────────────────────────
    .global resume_from_kernel_frame
resume_from_kernel_frame:
    mov     sp, x0
    b       trap_return

// ──────────────────────────────────────────────────────────────────────
// ap_entry_asm — AP entry point for PSCI CPU_ON (naked trampoline)
// ──────────────────────────────────────────────────────────────────────
// PSCI delivers AP at EL1 with MMU OFF, x0 = context_id (core_id).
// BSP sets globals: ap_stack_top (phys), ap_ttbr0, ap_ttbr1, ap_mair,
// ap_tcr, ap_sctlr.
//
// Sequence: set SP, configure MMU, enable MMU, convert SP to virtual, call Zig.
    .global ap_entry_asm
    .balign 64
ap_entry_asm:
    // x0 = core_id (context_id from PSCI CPU_ON)
    // Save core_id in x19 (callee-saved, survives function calls)
    mov     x19, x0

    // Load physical stack top
    adrp    x1, ap_stack_top
    add     x1, x1, :lo12:ap_stack_top
    ldr     x1, [x1]
    mov     sp, x1

    // Configure MAIR_EL1
    adrp    x1, ap_mair
    add     x1, x1, :lo12:ap_mair
    ldr     x1, [x1]
    msr     mair_el1, x1

    // Configure TCR_EL1
    adrp    x1, ap_tcr
    add     x1, x1, :lo12:ap_tcr
    ldr     x1, [x1]
    msr     tcr_el1, x1

    // Set TTBR0_EL1 (identity map — needed for PC-relative code after MMU on)
    adrp    x1, ap_ttbr0
    add     x1, x1, :lo12:ap_ttbr0
    ldr     x1, [x1]
    msr     ttbr0_el1, x1

    // Set TTBR1_EL1 (higher-half kernel map)
    adrp    x1, ap_ttbr1
    add     x1, x1, :lo12:ap_ttbr1
    ldr     x1, [x1]
    msr     ttbr1_el1, x1

    // Synchronize
    isb
    tlbi    vmalle1is
    dsb     sy
    isb

    // Enable MMU via SCTLR_EL1
    adrp    x1, ap_sctlr
    add     x1, x1, :lo12:ap_sctlr
    ldr     x1, [x1]
    msr     sctlr_el1, x1
    isb

    // Convert SP from physical to higher-half virtual address.
    // KERNEL_VIRT_BASE = 0xFFFF_8000_0000_0000
    // Must do this BEFORE calling Zig — function prologue sets frame pointer
    // from SP. Changing SP mid-function corrupts stack frames.
    mov     x1, #0x8000
    movk    x1, #0xFFFF, lsl #16
    lsl     x1, x1, #32             // x1 = 0xFFFF_8000_0000_0000
    add     sp, sp, x1

    // Use SP_EL1 in EL1 mode
    msr     spsel, #1
    isb

    // Call Zig AP init: apEntryZig(core_id)
    mov     x0, x19
    bl      apEntryZig

    // Should not return
1:  wfi
    b       1b

// AP trampoline data — written by BSP before PSCI CPU_ON
    .section .data
    .balign 8
    .global ap_stack_top
ap_stack_top:
    .quad 0

    .global ap_ttbr0
ap_ttbr0:
    .quad 0

    .global ap_ttbr1
ap_ttbr1:
    .quad 0

    .global ap_mair
ap_mair:
    .quad 0

    .global ap_tcr
ap_tcr:
    .quad 0

    .global ap_sctlr
ap_sctlr:
    .quad 0
