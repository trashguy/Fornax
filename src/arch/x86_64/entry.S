# entry.S — Hardware-boundary entry points for Fornax x86_64 kernel
#
# Three entry points:
#   1. syscall_entry          — SYSCALL handler (Ring 3 → Ring 0)
#   2. isr_stub_N             — Exception handlers (vectors 0-31)
#   3. resume_user_mode       — First-run return to userspace via IRETQ
#   4. resume_from_kernel_frame — Resume blocked process via saved kernel stack
#
# All calls to Zig dispatch functions use System V AMD64 ABI:
#   args: RDI, RSI, RDX, RCX, R8, R9
#   return: RAX
#   callee-saved: RBX, RBP, R12-R15

# Segment selectors (GDT index | RPL=3)
.set USER_CS, 0x23   # 0x20 | 3
.set USER_DS, 0x1B   # 0x18 | 3

.text

# =============================================================================
# SYSCALL entry point
# =============================================================================
# Hardware state on SYSCALL:
#   RCX = user RIP, R11 = user RFLAGS
#   CS/SS from STAR MSR, RIP from LSTAR MSR
#   RSP unchanged (still user stack), IF cleared by SFMASK
#
# Fornax syscall convention:
#   RAX = syscall number
#   RDI, RSI, RDX, R10, R8 = args 0-4

.global syscall_entry
.align 16
syscall_entry:
    # Save user context to globals (still on user stack, interrupts off)
    movq %rsp, saved_user_rsp(%rip)
    movq %rcx, saved_user_rip(%rip)
    movq %r11, saved_user_rflags(%rip)

    # Switch to kernel stack
    movq kernel_stack_top(%rip), %rsp

    # Push ALL user registers for perfect restoration on return.
    # Stack frame layout (16 entries, 128 bytes):
    #   [rsp + 15*8] = user RSP
    #   [rsp + 14*8] = user RIP  (RCX)
    #   [rsp + 13*8] = user RFLAGS (R11)
    #   [rsp + 12*8] = RAX  (syscall nr, overwritten with return value)
    #   [rsp + 11*8] = RDI
    #   [rsp + 10*8] = RSI
    #   [rsp +  9*8] = RDX
    #   [rsp +  8*8] = R8
    #   [rsp +  7*8] = R9
    #   [rsp +  6*8] = R10
    #   [rsp +  5*8] = RBX
    #   [rsp +  4*8] = RBP
    #   [rsp +  3*8] = R12
    #   [rsp +  2*8] = R13
    #   [rsp +  1*8] = R14
    #   [rsp +  0*8] = R15
    pushq saved_user_rsp(%rip)
    pushq %rcx
    pushq %r11
    pushq %rax
    pushq %rdi
    pushq %rsi
    pushq %rdx
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %rbx
    pushq %rbp
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15

    # Save kernel RSP (pointing to bottom of frame) for blocking syscall resume
    movq %rsp, saved_kernel_rsp(%rip)

    # Translate Fornax syscall convention → SysV calling convention
    # From: RAX=nr, RDI=a0, RSI=a1, RDX=a2, R10=a3, R8=a4
    # To:   RDI=nr, RSI=a0, RDX=a1, RCX=a2, R8=a3,  R9=a4
    movq %r8, %r9
    movq %r10, %r8
    movq %rdx, %rcx
    movq %rsi, %rdx
    movq %rdi, %rsi
    movq %rax, %rdi

    call syscallDispatch

    # RAX = return value — overwrite saved RAX slot on the stack
    movq %rax, 12*8(%rsp)

    # Fall through to shared return path
.global syscall_return_path
syscall_return_path:
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbp
    popq %rbx
    popq %r10
    popq %r9
    popq %r8
    popq %rdx
    popq %rsi
    popq %rdi
    popq %rax
    popq %r11
    popq %rcx
    popq %rsp

    sysretq

# =============================================================================
# resume_from_kernel_frame — Resume a blocked process
# =============================================================================
# Called from switchTo when a process was blocked in a syscall.
# The kernel stack still has the full GPR frame from when the process entered.
# The caller must have already written syscall_ret into frame[12] (RAX slot).
#
# SysV arg: RDI = saved kernel RSP (points to R15 at bottom of frame)

.global resume_from_kernel_frame
.align 16
resume_from_kernel_frame:
    movq %rdi, %rsp
    jmp syscall_return_path

# =============================================================================
# ISR stubs — Exception entry (vectors 0-31)
# =============================================================================
# Each stub pushes a dummy error code (if CPU didn't) and the vector number,
# then jumps to isr_common which saves all GPRs and calls the Zig handler.

.macro ISR_NOERR vector
.align 16
isr_stub_\vector :
    pushq $0
    pushq $\vector
    jmp isr_common
.endm

.macro ISR_ERR vector
.align 16
isr_stub_\vector :
    # CPU already pushed error code
    pushq $\vector
    jmp isr_common
.endm

ISR_NOERR 0       # Division Error
ISR_NOERR 1       # Debug
ISR_NOERR 2       # NMI
ISR_NOERR 3       # Breakpoint
ISR_NOERR 4       # Overflow
ISR_NOERR 5       # Bound Range Exceeded
ISR_NOERR 6       # Invalid Opcode
ISR_NOERR 7       # Device Not Available
ISR_ERR   8       # Double Fault
ISR_NOERR 9       # Coprocessor Segment Overrun
ISR_ERR   10      # Invalid TSS
ISR_ERR   11      # Segment Not Present
ISR_ERR   12      # Stack-Segment Fault
ISR_ERR   13      # General Protection Fault
ISR_ERR   14      # Page Fault
ISR_NOERR 15      # Reserved
ISR_NOERR 16      # x87 Floating-Point
ISR_ERR   17      # Alignment Check
ISR_NOERR 18      # Machine Check
ISR_NOERR 19      # SIMD Floating-Point
ISR_NOERR 20      # Virtualization
ISR_ERR   21      # Control Protection
ISR_NOERR 22      # Reserved
ISR_NOERR 23      # Reserved
ISR_NOERR 24      # Reserved
ISR_NOERR 25      # Reserved
ISR_NOERR 26      # Reserved
ISR_NOERR 27      # Reserved
ISR_NOERR 28      # Hypervisor Injection
ISR_ERR   29      # VMM Communication
ISR_ERR   30      # Security Exception
ISR_NOERR 31      # Reserved

.align 16
isr_common:
    # Save all GPRs to build ExceptionFrame on stack
    pushq %rax
    pushq %rbx
    pushq %rcx
    pushq %rdx
    pushq %rsi
    pushq %rdi
    pushq %rbp
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %r11
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15

    # SysV arg 1: pointer to ExceptionFrame
    movq %rsp, %rdi
    call handleExceptionWrapper

    # Restore all GPRs
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %r11
    popq %r10
    popq %r9
    popq %r8
    popq %rbp
    popq %rdi
    popq %rsi
    popq %rdx
    popq %rcx
    popq %rbx
    popq %rax

    # Skip vector + error code (16 bytes)
    addq $16, %rsp

    iretq

# ISR stub address table (for IDT initialization from Zig)
.align 8
.global isr_stub_table
isr_stub_table:
    .quad isr_stub_0,  isr_stub_1,  isr_stub_2,  isr_stub_3
    .quad isr_stub_4,  isr_stub_5,  isr_stub_6,  isr_stub_7
    .quad isr_stub_8,  isr_stub_9,  isr_stub_10, isr_stub_11
    .quad isr_stub_12, isr_stub_13, isr_stub_14, isr_stub_15
    .quad isr_stub_16, isr_stub_17, isr_stub_18, isr_stub_19
    .quad isr_stub_20, isr_stub_21, isr_stub_22, isr_stub_23
    .quad isr_stub_24, isr_stub_25, isr_stub_26, isr_stub_27
    .quad isr_stub_28, isr_stub_29, isr_stub_30, isr_stub_31

# =============================================================================
# resume_user_mode — First-run return to userspace via IRETQ
# =============================================================================
# Used only for processes that have never entered a syscall (no saved frame).
# SysV args: RDI=rip, RSI=rsp, RDX=rflags, RCX=ret_val

.global resume_user_mode
.align 16
resume_user_mode:
    movq %rcx, %rax              # return value → RAX for userspace

    # Build IRETQ frame on stack
    pushq $USER_DS               # SS
    pushq %rsi                   # RSP
    pushq %rdx                   # RFLAGS
    pushq $USER_CS               # CS
    pushq %rdi                   # RIP

    iretq
