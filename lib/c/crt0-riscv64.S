# crt0.S — Freestanding C startup for Fornax (riscv64)
#
# Loads argc/argv from ARGV_BASE, aligns stack, calls main(), exits.

.set SYS_EXIT, 14
.set ARGV_BASE, 0x7FFFFFEFF000

.text
.global _start
.align 4
_start:
    # Zero frame pointer
    li s0, 0

    # Load ARGV_BASE address
    li t0, 0x7FFFFFEFF000

    # Load argc from ARGV_BASE
    ld a0, 0(t0)                # argc in a0 (first arg to main)

    # argv = ARGV_BASE + 8
    addi a1, t0, 8              # argv in a1 (second arg to main)

    # Align stack to 16 bytes
    andi sp, sp, -16

    call main

    # Exit with main's return value (in a0)
    mv a0, a0                  # exit code already in a0
    li a7, SYS_EXIT
    ecall
    unimp
