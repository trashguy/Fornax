/* Linker script for Fornax RISC-V 64-bit kernel.
 *
 * QEMU virt RAM starts at 0x80000000. OpenSBI occupies the first 2MB.
 * Kernel loads at 0x80200000.
 */
ENTRY(_start)

SECTIONS
{
    . = 0x80200000;

    .text : ALIGN(4K) {
        *(.text .text.*)
    }

    .rodata : ALIGN(4K) {
        *(.rodata .rodata.*)
    }

    .data : ALIGN(4K) {
        *(.data .data.*)
        *(.sdata .sdata.*)
    }

    __bss_start = .;
    .bss : ALIGN(4K) {
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
    }
    __bss_end = .;

    /DISCARD/ : {
        *(.eh_frame)
        *(.comment)
        *(.note*)
        *(.riscv.attributes)
    }
}
