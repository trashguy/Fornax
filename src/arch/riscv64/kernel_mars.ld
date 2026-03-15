/* Linker script for Fornax RISC-V 64-bit kernel — Milk-V Mars (JH7110).
 *
 * JH7110 DDR starts at 0x40000000. OpenSBI occupies the first 2MB.
 * Kernel loads at 0x40200000 (U-Boot kernel_addr_r).
 */
ENTRY(_start)

SECTIONS
{
    . = 0x40200000;

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
