# crt0.S — musl-compatible C startup for Fornax POSIX programs (x86_64)
#
# 1. Isolates namespace via rfork(RFNAMEG) — POSIX realm boundary
# 2. Builds a Linux-style stack layout from Fornax's ARGV_BASE + AUXV_BASE
# 3. Calls musl's __libc_start_main(main, argc, argv, 0, 0, 0)

.set ARGV_BASE, 0x7FFFFFEFF000
.set AUXV_BASE, 0x7FFFFFEFE000
.set SYS_RFORK, 11
.set RFNAMEG, 0x08

.text
.global _start
.align 16
_start:
    xorl %ebp, %ebp

    # Isolate namespace (Plan 9 RFNAMEG) — POSIX realm boundary.
    movl $SYS_RFORK, %eax
    movl $RFNAMEG, %edi
    syscall

    # Load argc and argv info from ARGV_BASE
    movabs $ARGV_BASE, %r12
    movabs $AUXV_BASE, %r15
    movq (%r12), %rbx              # argc

    # Find end of auxv (pairs of u64 until AT_NULL=0)
    movq %r15, %r14
.Lfind_auxv_end:
    cmpq $0, (%r14)
    je .Lfound_end
    addq $16, %r14
    jmp .Lfind_auxv_end
.Lfound_end:
    addq $16, %r14                 # include the AT_NULL terminator pair

    # Push auxv entries in reverse onto the stack
.Lauxv_loop:
    cmpq %r15, %r14
    je .Lauxv_done
    subq $8, %r14
    pushq (%r14)
    jmp .Lauxv_loop
.Lauxv_done:

    # envp NULL terminator
    pushq $0

    # argv NULL terminator
    pushq $0

    # Push argv pointers in reverse order
    leaq 8(%r12), %r13             # &argv[0]
    leaq (%r13,%rbx,8), %r14       # past last argv pointer
.Largv_loop:
    cmpq %r13, %r14
    je .Largv_done
    subq $8, %r14
    pushq (%r14)
    jmp .Largv_loop
.Largv_done:

    # Push argc
    pushq %rbx

    # RSP now points to: [argc][argv0]...[argvN][NULL][envp_NULL][auxv...][AT_NULL]
    # Set up arguments for __libc_start_main(main, argc, argv, init, fini, ldso)
    movq (%rsp), %rsi              # RSI = argc (2nd arg)
    leaq 8(%rsp), %rdx             # RDX = argv (3rd arg)
    leaq main(%rip), %rdi          # RDI = main function pointer (1st arg)
    xorl %ecx, %ecx               # RCX = init = 0 (4th arg)
    xorl %r8d, %r8d               # R8  = fini = 0 (5th arg)
    xorl %r9d, %r9d               # R9  = ldso = 0 (6th arg)
    andq $-16, %rsp                # 16-byte align
    call __libc_start_main
    ud2
