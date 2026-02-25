# crt0.S — musl-compatible C startup for Fornax POSIX programs (aarch64)
#
# 1. Isolates namespace via rfork(RFNAMEG) — POSIX realm boundary
# 2. Builds a Linux-style stack layout from Fornax's ARGV_BASE + AUXV_BASE
# 3. Calls musl's __libc_start_main(main, argc, argv, 0, 0, 0)

.set SYS_RFORK, 11
.set SYS_SHUTDOWN, 25
.set RFNAMEG, 0x08

.text
.global _start
.align 4
_start:
    // Zero frame pointer
    mov x29, xzr

    // Isolate namespace (Plan 9 RFNAMEG) — POSIX realm boundary.
    mov x8, #SYS_RFORK
    mov x0, #RFNAMEG
    svc #0
    tbnz x0, #63, .Lrfork_fail

    // Load ARGV_BASE (0x7FFFFFEFF000)
    movz x19, #0xF000
    movk x19, #0xFEF, lsl #16
    movk x19, #0xFFFF, lsl #32
    movk x19, #0x7FFF, lsl #48

    // Load AUXV_BASE (0x7FFFFFEFE000)
    movz x20, #0xE000
    movk x20, #0xFEF, lsl #16
    movk x20, #0xFFFF, lsl #32
    movk x20, #0x7FFF, lsl #48

    // Load argc
    ldr x21, [x19]              // x21 = argc

    // Find end of auxv (pairs of u64 until AT_NULL=0)
    mov x22, x20                // x22 = scan pointer
.Lfind_auxv_end:
    ldr x9, [x22]
    cbz x9, .Lfound_end
    add x22, x22, #16
    b .Lfind_auxv_end
.Lfound_end:
    add x22, x22, #16          // include the AT_NULL terminator pair

    // Push auxv entries in reverse onto the stack
.Lauxv_loop:
    cmp x22, x20
    b.eq .Lauxv_done
    sub x22, x22, #8
    ldr x9, [x22]
    str x9, [sp, #-8]!
    b .Lauxv_loop
.Lauxv_done:

    // envp NULL terminator
    str xzr, [sp, #-8]!

    // argv NULL terminator
    str xzr, [sp, #-8]!

    // Push argv pointers in reverse order
    add x23, x19, #8           // x23 = &argv[0]
    add x24, x23, x21, lsl #3  // x24 = past last argv pointer
.Largv_loop:
    cmp x24, x23
    b.eq .Largv_done
    sub x24, x24, #8
    ldr x9, [x24]
    str x9, [sp, #-8]!
    b .Largv_loop
.Largv_done:

    // Push argc
    str x21, [sp, #-8]!

    // Set up arguments for __libc_start_main(main, argc, argv, init, fini, ldso)
    ldr x1, [sp]               // x1 = argc
    add x2, sp, #8             // x2 = argv
    adrp x0, main
    add x0, x0, :lo12:main     // x0 = main function pointer
    mov x3, xzr                // x3 = init = 0
    mov x4, xzr                // x4 = fini = 0
    mov x5, xzr                // x5 = ldso = 0

    // 16-byte align stack
    mov x9, sp
    and x9, x9, #~15
    mov sp, x9

    bl __libc_start_main
    brk #0

.Lrfork_fail:
    mov x8, #SYS_SHUTDOWN
    mov x0, #1
    svc #0
    brk #0
