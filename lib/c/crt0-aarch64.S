# crt0.S — Freestanding C startup for Fornax (aarch64)
#
# Loads argc/argv from ARGV_BASE, aligns stack, calls main(), exits.

.set SYS_EXIT, 14

.text
.global _start
.align 4
_start:
    // Zero frame pointer
    mov x29, xzr

    // Load ARGV_BASE address (0x7FFFFFEFF000)
    movz x9, #0xF000
    movk x9, #0xFEF, lsl #16
    movk x9, #0xFFFF, lsl #32
    movk x9, #0x7FFF, lsl #48

    // Load argc from ARGV_BASE
    ldr x0, [x9]                // argc in x0 (first arg to main)

    // argv = ARGV_BASE + 8
    add x1, x9, #8              // argv in x1 (second arg to main)

    // Align stack to 16 bytes
    mov x10, sp
    and x10, x10, #~15
    mov sp, x10

    bl main

    // Exit with main's return value (in x0)
    mov x8, #SYS_EXIT
    svc #0
    brk #0
