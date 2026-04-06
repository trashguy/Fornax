# crt0.S — musl-compatible C startup for Fornax POSIX programs (riscv64)
#
# 1. Isolates namespace via rfork(RFNAMEG) — POSIX realm boundary
# 2. Builds a Linux-style stack layout from Fornax's ARGV_BASE + AUXV_BASE
# 3. Calls musl's __libc_start_main(main, argc, argv, 0, 0, 0)

.set ARGV_BASE, 0x3FFFEFF000
.set AUXV_BASE, 0x3FFFEFE000
.set SYS_RFORK, 11
.set SYS_SHUTDOWN, 25
.set RFNAMEG, 0x08

.text
.global _start
.align 4
_start:
    # Zero frame pointer
    li s0, 0

    # Isolate namespace (Plan 9 RFNAMEG) — POSIX realm boundary.
    li a7, SYS_RFORK
    li a0, RFNAMEG
    ecall
    bltz a0, .Lrfork_fail

    # Load ARGV_BASE and AUXV_BASE
    li s1, 0x3FFFEFF000       # ARGV_BASE (riscv64 Sv39)
    li s2, 0x3FFFEFE000       # AUXV_BASE
    ld s3, 0(s1)                # s3 = argc

    # Find end of auxv (pairs of u64 until AT_NULL=0)
    mv s4, s2                   # s4 = scan pointer
.Lfind_auxv_end:
    ld t0, 0(s4)
    beqz t0, .Lfound_end
    addi s4, s4, 16
    j .Lfind_auxv_end
.Lfound_end:
    addi s4, s4, 16             # include the AT_NULL terminator pair

    # Push auxv entries in reverse onto the stack
.Lauxv_loop:
    beq s4, s2, .Lauxv_done
    addi s4, s4, -8
    ld t0, 0(s4)
    addi sp, sp, -8
    sd t0, 0(sp)
    j .Lauxv_loop
.Lauxv_done:

    # envp NULL terminator
    addi sp, sp, -8
    sd zero, 0(sp)

    # argv NULL terminator
    addi sp, sp, -8
    sd zero, 0(sp)

    # Push argv pointers in reverse order
    addi s5, s1, 8              # s5 = &argv[0]
    slli t1, s3, 3              # t1 = argc * 8
    add s6, s5, t1              # s6 = past last argv pointer
.Largv_loop:
    beq s6, s5, .Largv_done
    addi s6, s6, -8
    ld t0, 0(s6)
    addi sp, sp, -8
    sd t0, 0(sp)
    j .Largv_loop
.Largv_done:

    # Push argc
    addi sp, sp, -8
    sd s3, 0(sp)

    # Set up arguments for __libc_start_main(main, argc, argv, init, fini, ldso)
    ld a1, 0(sp)                # a1 = argc
    addi a2, sp, 8              # a2 = argv
    la a0, main                 # a0 = main function pointer
    li a3, 0                    # a3 = init = 0
    li a4, 0                    # a4 = fini = 0
    li a5, 0                    # a5 = ldso = 0

    # 16-byte align stack
    andi sp, sp, -16

    call __libc_start_main
    unimp

.Lrfork_fail:
    li a7, SYS_SHUTDOWN
    li a0, 1
    ecall
    unimp
