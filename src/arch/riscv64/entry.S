# entry.S — Trap entry/exit for Fornax RISC-V 64-bit kernel (S-mode)
#
# All traps (exceptions, interrupts, ecalls) enter via STVEC → trap_entry.
# Uses SSCRATCH protocol: holds kernel SP when in U-mode, 0 when in S-mode.
#
# Trap frame layout (33 slots × 8 bytes = 264 bytes, padded to 272 for 16-byte alignment):
#   [sp +  0*8] = x1  (ra)
#   [sp +  1*8] = x2  (sp, user's SP)
#   [sp +  2*8] = x3  (gp)
#   [sp +  3*8] = x4  (tp)
#   [sp +  4*8] = x5  (t0)
#   [sp +  5*8] = x6  (t1)
#   [sp +  6*8] = x7  (t2)
#   [sp +  7*8] = x8  (s0/fp)
#   [sp +  8*8] = x9  (s1)
#   [sp +  9*8] = x10 (a0) — ECALL return value goes here
#   [sp + 10*8] = x11 (a1)
#   [sp + 11*8] = x12 (a2)
#   [sp + 12*8] = x13 (a3)
#   [sp + 13*8] = x14 (a4)
#   [sp + 14*8] = x15 (a5)
#   [sp + 15*8] = x16 (a6)
#   [sp + 16*8] = x17 (a7)
#   [sp + 17*8] = x18 (s2)
#   [sp + 18*8] = x19 (s3)
#   [sp + 19*8] = x20 (s4)
#   [sp + 20*8] = x21 (s5)
#   [sp + 21*8] = x22 (s6)
#   [sp + 22*8] = x23 (s7)
#   [sp + 23*8] = x24 (s8)
#   [sp + 24*8] = x25 (s9)
#   [sp + 25*8] = x26 (s10)
#   [sp + 26*8] = x27 (s11)
#   [sp + 27*8] = x28 (t3)
#   [sp + 28*8] = x29 (t4)
#   [sp + 29*8] = x30 (t5)
#   [sp + 30*8] = x31 (t6)
#   [sp + 31*8] = SEPC
#   [sp + 32*8] = SSTATUS
#   (sp + 33*8 = 264, pad to 272)

.set FRAME_SIZE, 272

.text

# =============================================================================
# _start — Kernel boot entry point (called by OpenSBI / QEMU -kernel)
# =============================================================================
# OpenSBI passes: a0 = hartid, a1 = DTB pointer
# Sets up a kernel stack and calls riscv64KernelMain(hartid, dtb_ptr).
.global _start
.align 4
_start:
    # Only boot on hart 0, park all other harts
    bnez a0, .park_hart

    # Set up kernel boot stack (16 KB, defined in boot.zig)
    la sp, __boot_stack_top

    # Clear BSS section
    la t0, __bss_start
    la t1, __bss_end
.clear_bss:
    bgeu t0, t1, .bss_done
    sd zero, 0(t0)
    addi t0, t0, 8
    j .clear_bss
.bss_done:

    # Call Zig kernel main: a0=hartid, a1=dtb_ptr (already in registers)
    call riscv64KernelMain

    # Should not return
.park_hart:
    wfi
    j .park_hart

# Provide weak BSS symbols (overridden by linker if available)
.weak __bss_start
.weak __bss_end

# =============================================================================
# trap_entry — Main trap vector (set via STVEC)
# =============================================================================
.global trap_entry
.align 4
trap_entry:
    # Swap SP and SSCRATCH. After this:
    #   If from U-mode: SP = kernel stack, SSCRATCH = user SP
    #   If from S-mode: SP = 0 (SSCRATCH was 0), SSCRATCH = kernel SP
    csrrw sp, sscratch, sp

    # Check if we came from S-mode (SSCRATCH was 0 → SP is now 0)
    bnez sp, 1f

    # From S-mode: get kernel SP back from SSCRATCH
    csrr sp, sscratch
1:
    # SP is now kernel stack. Allocate trap frame.
    addi sp, sp, -FRAME_SIZE

    # Save all GPRs (x1-x31)
    sd x1,   0*8(sp)
    # x2 (sp) saved below after recovering user SP
    sd x3,   2*8(sp)
    sd x4,   3*8(sp)
    sd x5,   4*8(sp)
    sd x6,   5*8(sp)
    sd x7,   6*8(sp)
    sd x8,   7*8(sp)
    sd x9,   8*8(sp)
    sd x10,  9*8(sp)
    sd x11, 10*8(sp)
    sd x12, 11*8(sp)
    sd x13, 12*8(sp)
    sd x14, 13*8(sp)
    sd x15, 14*8(sp)
    sd x16, 15*8(sp)
    sd x17, 16*8(sp)
    sd x18, 17*8(sp)
    sd x19, 18*8(sp)
    sd x20, 19*8(sp)
    sd x21, 20*8(sp)
    sd x22, 21*8(sp)
    sd x23, 22*8(sp)
    sd x24, 23*8(sp)
    sd x25, 24*8(sp)
    sd x26, 25*8(sp)
    sd x27, 26*8(sp)
    sd x28, 27*8(sp)
    sd x29, 28*8(sp)
    sd x30, 29*8(sp)
    sd x31, 30*8(sp)

    # Save user SP: read SSCRATCH (holds user SP if from U-mode)
    csrr t0, sscratch
    sd t0, 1*8(sp)

    # Save SEPC and SSTATUS
    csrr t0, sepc
    sd t0, 31*8(sp)
    csrr t0, sstatus
    sd t0, 32*8(sp)

    # Clear SSCRATCH (marks us as in S-mode for nested traps)
    csrw sscratch, zero

    # Save kernel RSP for resume_from_kernel_frame
    la t0, saved_kernel_rsp
    sd sp, 0(t0)

    # Save user context globals (for process.saveCurrentContext compatibility)
    ld t1, 31*8(sp)       # SEPC → saved_user_rip
    la t2, saved_user_rip
    sd t1, 0(t2)

    ld t1, 1*8(sp)        # user SP → saved_user_rsp
    la t2, saved_user_rsp
    sd t1, 0(t2)

    ld t1, 32*8(sp)       # SSTATUS → saved_user_rflags
    la t2, saved_user_rflags
    sd t1, 0(t2)

    # Read SCAUSE to determine trap type
    csrr t0, scause

    # Check if it's an interrupt (bit 63 set)
    bltz t0, handle_interrupt

    # Check for U-mode ECALL (cause = 8)
    li t1, 8
    beq t0, t1, handle_ecall

    # Otherwise it's an exception
    j handle_exception

# =============================================================================
# handle_ecall — User ECALL (syscall)
# =============================================================================
handle_ecall:
    # Advance SEPC past the ECALL instruction (4 bytes)
    ld t0, 31*8(sp)
    addi t0, t0, 4
    sd t0, 31*8(sp)

    # Remap registers for C calling convention:
    # Fornax ECALL: a7=nr, a0=arg0, a1=arg1, a2=arg2, a3=arg3, a4=arg4
    # C ABI call:   a0=nr, a1=arg0, a2=arg1, a3=arg2, a4=arg3, a5=arg4
    mv a5, a4
    mv a4, a3
    mv a3, a2
    mv a2, a1
    mv a1, a0
    mv a0, a7

    call syscallDispatch

    # Store return value in frame slot 9 (a0 position)
    sd a0, 9*8(sp)

    j trap_return

# =============================================================================
# handle_interrupt — Interrupt dispatch
# =============================================================================
handle_interrupt:
    csrr a0, scause
    mv a1, sp
    call handleInterruptRv
    j trap_return

# =============================================================================
# handle_exception — Exception dispatch
# =============================================================================
handle_exception:
    mv a0, sp
    csrr a1, scause
    csrr a2, stval
    call handleExceptionRv
    j trap_return

# =============================================================================
# trap_return — Restore context and return (SRET)
# =============================================================================
.global trap_return
trap_return:
    # Restore SSTATUS
    ld t0, 32*8(sp)
    csrw sstatus, t0

    # Restore SEPC
    ld t0, 31*8(sp)
    csrw sepc, t0

    # Check if returning to U-mode (SSTATUS.SPP == 0)
    ld t0, 32*8(sp)
    li t1, 0x100       # SPP bit (bit 8)
    and t0, t0, t1
    bnez t0, 1f

    # Returning to U-mode: set SSCRATCH = kernel stack top
    la t0, kernel_stack_top
    ld t0, 0(t0)
    csrw sscratch, t0
1:
    # Restore all GPRs except x2 (sp)
    ld x1,   0*8(sp)
    ld x3,   2*8(sp)
    ld x4,   3*8(sp)
    ld x5,   4*8(sp)
    ld x6,   5*8(sp)
    ld x7,   6*8(sp)
    ld x8,   7*8(sp)
    ld x9,   8*8(sp)
    ld x10,  9*8(sp)
    ld x11, 10*8(sp)
    ld x12, 11*8(sp)
    ld x13, 12*8(sp)
    ld x14, 13*8(sp)
    ld x15, 14*8(sp)
    ld x16, 15*8(sp)
    ld x17, 16*8(sp)
    ld x18, 17*8(sp)
    ld x19, 18*8(sp)
    ld x20, 19*8(sp)
    ld x21, 20*8(sp)
    ld x22, 21*8(sp)
    ld x23, 22*8(sp)
    ld x24, 23*8(sp)
    ld x25, 24*8(sp)
    ld x26, 25*8(sp)
    ld x27, 26*8(sp)
    ld x28, 27*8(sp)
    ld x29, 28*8(sp)
    ld x30, 29*8(sp)
    ld x31, 30*8(sp)

    # Restore user SP from frame (overwrites kernel sp with user sp)
    ld sp, 1*8(sp)

    sret

# =============================================================================
# resume_from_kernel_frame — Resume a blocked process
# =============================================================================
# Called from switchTo when a process was blocked in a syscall.
# C ABI arg: a0 = saved kernel RSP (points to trap frame base)

.global resume_from_kernel_frame
.align 4
resume_from_kernel_frame:
    mv sp, a0
    j trap_return

# =============================================================================
# resume_user_mode — First-run return to userspace via SRET
# =============================================================================
# Used for processes that have never entered a syscall (no saved frame).
# C ABI args: a0=entry_rip, a1=user_sp, a2=sstatus, a3=ret_val

.global resume_user_mode
.align 4
resume_user_mode:
    # a0=entry_rip, a1=user_sp, a2=sstatus, a3=ret_val
    # Set SEPC = entry point
    csrw sepc, a0

    # Set SSTATUS for U-mode return (SPP=0, SPIE=1)
    csrw sstatus, a2

    # Set SSCRATCH = kernel stack top (for next trap entry)
    la t0, kernel_stack_top
    ld t0, 0(t0)
    csrw sscratch, t0

    # Set SP = user stack, a0 = return value
    mv sp, a1
    mv a0, a3

    # Clear all other registers for clean userspace entry
    li ra, 0
    li gp, 0
    li tp, 0
    li t0, 0
    li t1, 0
    li t2, 0
    li s0, 0
    li s1, 0
    # a0 already set (return value)
    li a1, 0
    li a2, 0
    li a3, 0
    li a4, 0
    li a5, 0
    li a6, 0
    li a7, 0
    li s2, 0
    li s3, 0
    li s4, 0
    li s5, 0
    li s6, 0
    li s7, 0
    li s8, 0
    li s9, 0
    li s10, 0
    li s11, 0
    li t3, 0
    li t4, 0
    li t5, 0
    li t6, 0

    sret
