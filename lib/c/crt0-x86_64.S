# crt0.S — Freestanding C startup for Fornax (x86_64)
#
# Loads argc/argv from ARGV_BASE, aligns stack, calls main(), exits.

.set SYS_EXIT, 14
.set ARGV_BASE, 0x7FFFFFEFF000

.text
.global _start
.align 16
_start:
    xorl %ebp, %ebp

    # Load argc from ARGV_BASE
    movabs $ARGV_BASE, %rdi
    movq (%rdi), %rdi           # argc in RDI (first arg to main)

    # argv = ARGV_BASE + 8
    movabs $ARGV_BASE, %rsi
    addq $8, %rsi               # argv in RSI (second arg to main)

    # Align stack to 16 bytes (call will push 8-byte return address)
    andq $-16, %rsp
    subq $8, %rsp

    call main

    # Exit with main's return value
    movq %rax, %rdi
    movq $SYS_EXIT, %rax
    syscall
    ud2
