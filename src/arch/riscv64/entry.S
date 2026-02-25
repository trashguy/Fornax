# entry.S — Trap entry/exit for Fornax RISC-V 64-bit kernel (S-mode)
#
# SMP protocol: SSCRATCH holds &asm_states[hartid] (percpu pointer) when in
# U-mode, 0 when in S-mode. TP = percpu pointer in S-mode.
#
# On trap entry from U-mode:
#   csrrw tp, sscratch, tp → tp=percpu, sscratch=user_tp
#   Load kernel SP from percpu, save user SP to percpu.
#
# On trap entry from S-mode:
#   csrrw tp, sscratch, tp → tp=0 (sscratch was 0), sscratch=kernel_tp
#   Restore kernel tp from sscratch, use existing SP.
#
# Trap frame layout (33 slots × 8 bytes = 264 bytes, padded to 272 for 16-byte alignment):
#   [sp +  0*8] = x1  (ra)
#   [sp +  1*8] = x2  (sp, user's SP)
#   [sp +  2*8] = x3  (gp)
#   [sp +  3*8] = x4  (tp, user's TP)
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

# AsmState offsets (must match percpu.zig AsmState extern struct)
.set ASM_KERNEL_STACK_TOP,  0
.set ASM_SAVED_USER_RSP,    8
.set ASM_SAVED_USER_RIP,   16
.set ASM_SAVED_USER_RFLAGS, 24
.set ASM_SAVED_KERNEL_RSP, 32

.text

# =============================================================================
# _start — Kernel boot entry point (called by OpenSBI / QEMU -kernel)
# =============================================================================
# OpenSBI passes: a0 = hartid, a1 = DTB pointer
# Only the boot hart (any hartid) enters here. Others started via SBI HSM.
.global _start
.align 4
_start:
    # OpenSBI may start all harts. Non-boot harts must stop themselves
    # via SBI HSM hart_stop so they can be restarted later via hart_start.
    # We use a simple lock: the first hart to atomically swap the flag wins.
    la t0, _boot_hart_claimed
    li t1, 1
    amoswap.w.aq t2, t1, (t0)
    bnez t2, .stop_hart           # Another hart already claimed boot

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
    j .halt_hart

.stop_hart:
    # Call SBI HSM hart_stop (EID=0x48534D, FID=1)
    # This puts the hart in STOPPED state so it can be restarted via hart_start.
    li a7, 0x48534D
    li a6, 1
    ecall

    # If hart_stop returns (shouldn't happen), fall through to halt
.halt_hart:
    wfi
    j .halt_hart

# Provide weak BSS symbols (overridden by linker if available)
.weak __bss_start
.weak __bss_end

# Atomic flag for boot hart selection (in .data, not cleared by BSS init)
.section .data
.align 4
_boot_hart_claimed:
    .word 0

# =============================================================================
# ap_entry_asm — AP entry point for SBI hart_start (naked trampoline)
# =============================================================================
# SBI starts hart with: a0=hartid, a1=priv_val (core_id), SATP=0 (paging OFF).
# No stack is set up. We must set SP before calling any Zig function.
#
# Global variables (set by BSP before hart_start):
#   ap_stack_top  — physical stack top for this AP
#   ap_bsp_satp   — BSP's SATP value for enabling paging
.text
.global ap_entry_asm
.align 4
ap_entry_asm:
    # a0 = hartid, a1 = core_id (priv_val from sbi_hart_start)

    # Load physical stack top from global (BSP set this before hart_start)
    la t0, ap_stack_top
    ld sp, 0(t0)

    # Enable paging with BSP's page tables
    la t0, ap_bsp_satp
    ld t1, 0(t0)
    csrw 384, t1               # CSR_SATP = 0x180 = 384 decimal
    sfence.vma

    # Convert SP from physical to higher-half virtual address.
    # KERNEL_VIRT_BASE = 0xFFFF_8000_0000_0000 = (-1) << 47
    # Must do this BEFORE calling Zig — otherwise the function prologue
    # sets s0 (frame pointer) to the physical stack, while callees use
    # the virtual SP, causing stack frame aliasing corruption.
    li t2, -1
    slli t2, t2, 47
    add sp, sp, t2

    # Call Zig AP init function with virtual stack ready.
    # apEntryZig(hartid=a0, core_id=a1) — C calling convention is fine now.
    call apEntryZig

    # Should not return
    wfi
    j .-4

.section .data
.align 8
.global ap_stack_top
ap_stack_top:
    .quad 0

.global ap_bsp_satp
ap_bsp_satp:
    .quad 0

# =============================================================================
# trap_entry — Main trap vector (set via STVEC)
# =============================================================================
# SMP protocol:
#   U-mode: SSCRATCH = &asm_states[core_id], TP = user TLS
#   S-mode: SSCRATCH = 0, TP = &asm_states[core_id]
.global trap_entry
.align 4
trap_entry:
    # Swap TP and SSCRATCH.
    # From U-mode: TP = percpu ptr, SSCRATCH = user TP
    # From S-mode: TP = 0 (SSCRATCH was 0), SSCRATCH = kernel TP
    csrrw tp, sscratch, tp

    bnez tp, .from_umode

    # ── From S-mode ──
    # TP is 0 (was SSCRATCH), SSCRATCH now holds kernel TP
    csrr tp, sscratch          # Restore kernel TP
    csrw sscratch, zero        # Re-mark S-mode
    # SP is already kernel stack — save original SP before allocating frame
    addi sp, sp, -FRAME_SIZE
    # Save ORIGINAL SP (before frame alloc) so trap_return restores correctly.
    # Without this, every S-mode interrupt permanently leaks 272 bytes of stack.
    addi t0, sp, FRAME_SIZE
    sd t0, 1*8(sp)
    # TP slot: save kernel TP (will be restored as TP on return)
    sd tp, 3*8(sp)
    j .save_regs

.from_umode:
    # ── From U-mode ──
    # TP = percpu AsmState ptr, SSCRATCH = user TP
    # Save user SP to percpu, load kernel SP
    sd sp, ASM_SAVED_USER_RSP(tp)    # save user SP
    ld sp, ASM_KERNEL_STACK_TOP(tp)  # load kernel SP
    addi sp, sp, -FRAME_SIZE

    # Save user SP from percpu to frame
    ld t0, ASM_SAVED_USER_RSP(tp)
    sd t0, 1*8(sp)

    # Save user TP (from SSCRATCH) to frame
    csrr t0, sscratch
    sd t0, 3*8(sp)

.save_regs:
    # Save all GPRs (except SP@slot1 and TP@slot3, already saved)
    sd x1,   0*8(sp)           # ra
    sd x3,   2*8(sp)           # gp
    sd x5,   4*8(sp)           # t0
    sd x6,   5*8(sp)           # t1
    sd x7,   6*8(sp)           # t2
    sd x8,   7*8(sp)           # s0/fp
    sd x9,   8*8(sp)           # s1
    sd x10,  9*8(sp)           # a0
    sd x11, 10*8(sp)           # a1
    sd x12, 11*8(sp)           # a2
    sd x13, 12*8(sp)           # a3
    sd x14, 13*8(sp)           # a4
    sd x15, 14*8(sp)           # a5
    sd x16, 15*8(sp)           # a6
    sd x17, 16*8(sp)           # a7
    sd x18, 17*8(sp)           # s2
    sd x19, 18*8(sp)           # s3
    sd x20, 19*8(sp)           # s4
    sd x21, 20*8(sp)           # s5
    sd x22, 21*8(sp)           # s6
    sd x23, 22*8(sp)           # s7
    sd x24, 23*8(sp)           # s8
    sd x25, 24*8(sp)           # s9
    sd x26, 25*8(sp)           # s10
    sd x27, 26*8(sp)           # s11
    sd x28, 27*8(sp)           # t3
    sd x29, 28*8(sp)           # t4
    sd x30, 29*8(sp)           # t5
    sd x31, 30*8(sp)           # t6

    # Save SEPC and SSTATUS
    csrr t0, sepc
    sd t0, 31*8(sp)
    csrr t0, sstatus
    sd t0, 32*8(sp)

    # Mark S-mode: SSCRATCH = 0
    csrw sscratch, zero

    # Save to percpu AsmState fields (for process.zig compatibility)
    ld t1, 31*8(sp)
    sd t1, ASM_SAVED_USER_RIP(tp)      # saved_user_rip = SEPC
    ld t1, 1*8(sp)
    sd t1, ASM_SAVED_USER_RSP(tp)      # saved_user_rsp = user SP
    ld t1, 32*8(sp)
    sd t1, ASM_SAVED_USER_RFLAGS(tp)   # saved_user_rflags = SSTATUS
    sd sp, ASM_SAVED_KERNEL_RSP(tp)    # saved_kernel_rsp = frame base

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
    # Restore SSTATUS and SEPC
    ld t0, 32*8(sp)
    csrw sstatus, t0
    ld t0, 31*8(sp)
    csrw sepc, t0

    # Check if returning to U-mode (SSTATUS.SPP == 0)
    ld t0, 32*8(sp)
    li t1, 0x100       # SPP bit (bit 8)
    and t0, t0, t1
    bnez t0, .smode_return

    # ── Returning to U-mode ──
    # Save kernel TP (percpu ptr) to SSCRATCH for next trap entry
    csrw sscratch, tp

    # Restore all GPRs
    ld x1,   0*8(sp)           # ra
    ld x3,   2*8(sp)           # gp
    # x4 (tp) restored below as user TP
    ld x5,   4*8(sp)           # t0
    ld x6,   5*8(sp)           # t1
    ld x7,   6*8(sp)           # t2
    ld x8,   7*8(sp)           # s0/fp
    ld x9,   8*8(sp)           # s1
    ld x10,  9*8(sp)           # a0
    ld x11, 10*8(sp)           # a1
    ld x12, 11*8(sp)           # a2
    ld x13, 12*8(sp)           # a3
    ld x14, 13*8(sp)           # a4
    ld x15, 14*8(sp)           # a5
    ld x16, 15*8(sp)           # a6
    ld x17, 16*8(sp)           # a7
    ld x18, 17*8(sp)           # s2
    ld x19, 18*8(sp)           # s3
    ld x20, 19*8(sp)           # s4
    ld x21, 20*8(sp)           # s5
    ld x22, 21*8(sp)           # s6
    ld x23, 22*8(sp)           # s7
    ld x24, 23*8(sp)           # s8
    ld x25, 24*8(sp)           # s9
    ld x26, 25*8(sp)           # s10
    ld x27, 26*8(sp)           # s11
    ld x28, 27*8(sp)           # t3
    ld x29, 28*8(sp)           # t4
    ld x30, 29*8(sp)           # t5
    ld x31, 30*8(sp)           # t6

    # Restore user TP from frame[3]
    ld x4, 3*8(sp)

    # Restore user SP from frame (overwrites kernel sp with user sp)
    ld sp, 1*8(sp)

    sret

.smode_return:
    # ── Returning to S-mode ──
    # SSCRATCH stays 0 (S-mode marker)
    # TP stays as kernel percpu ptr (frame[3] = kernel TP for S-mode traps)

    # Restore all GPRs
    ld x1,   0*8(sp)
    ld x3,   2*8(sp)
    ld x4,   3*8(sp)           # tp = kernel tp
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
# C ABI args: a0=entry_rip, a1=user_sp, a2=sstatus, a3=ret_val, a4=user_tp

.global resume_user_mode
.align 4
resume_user_mode:
    # a0=entry_rip, a1=user_sp, a2=sstatus, a3=ret_val, a4=user_tp
    # Set SEPC = entry point
    csrw sepc, a0

    # Set SSTATUS for U-mode return (SPP=0, SPIE=1)
    csrw sstatus, a2

    # Save kernel TP (percpu ptr) to SSCRATCH for next trap entry
    csrw sscratch, tp

    # Set SP = user stack, a0 = return value
    mv sp, a1
    mv a0, a3

    # Set TP = user TLS pointer (5th arg)
    mv tp, a4

    # Clear all other registers for clean userspace entry
    li ra, 0
    li gp, 0
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
