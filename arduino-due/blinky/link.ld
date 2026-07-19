/*
 * Linker script for the Atmel SAM3X8E (Arduino Due).
 *
 * The memory regions below are narrower than the ones Arduino's own flash.ld
 * declares, and deliberately so. Both were checked against probe-rs's target
 * registry (`dagger -m .../flash call chip-info --chip ATSAM3X8E`), which
 * reports:
 *
 *     NVM:     0x00080000..0x000c0000 (256K)   <- flash bank 0, programmable
 *     Generic: 0x000c0000..0x00100000 (256K)   <- flash bank 1, NOT programmable
 *     RAM:     0x20000000..0x20010000 (64K)    <- SRAM0
 *     Generic: 0x20080000..0x20088000 (32K)    <- SRAM1
 *
 * So:
 *   - rom is 256K, not the 512K Arduino declares. Only bank 0 is exposed as
 *     programmable NVM, and a blinky has no use for the second bank anyway.
 *   - ram is SRAM0 at 0x20000000. Arduino's script uses 0x20070000, a hardware
 *     alias that presents SRAM0+SRAM1 as one contiguous 96K block. That alias
 *     does not appear in probe-rs's map at all, and we need a few hundred bytes,
 *     so the plainly-addressed 64K bank is the lower-risk choice.
 *
 * On reset the Cortex-M3 fetches the initial stack pointer and reset vector
 * from address 0. With GPNVM1 set (boot from flash) that address is mirrored
 * onto flash bank 0, which is why .isr_vector must be first in rom.
 */

ENTRY(resetHandler)

MEMORY
{
    rom (rx)  : ORIGIN = 0x00080000, LENGTH = 0x00040000  /* 256K, flash bank 0 */
    ram (rwx) : ORIGIN = 0x20000000, LENGTH = 0x00010000  /*  64K, SRAM0        */
}

/* Full descending stack: the CPU pre-decrements, so this points one past the end. */
_estack = ORIGIN(ram) + LENGTH(ram);

SECTIONS
{
    .text :
    {
        . = ALIGN(4);
        /* KEEP, or --gc-sections discards the table: nothing references it. */
        KEEP(*(.isr_vector))
        *(.text*)
        *(.rodata*)
        . = ALIGN(4);
    } > rom

    /* Load address of .data in flash, so the reset handler knows where to copy from. */
    _sidata = LOADADDR(.data);

    .data :
    {
        . = ALIGN(4);
        _sdata = .;
        *(.data*)
        . = ALIGN(4);
        _edata = .;
    } > ram AT > rom

    .bss (NOLOAD) :
    {
        . = ALIGN(4);
        _sbss = .;
        *(.bss*)
        *(COMMON)
        . = ALIGN(4);
        _ebss = .;
    } > ram

    /* No unwinder in a freestanding image; drop the tables rather than carry them. */
    /DISCARD/ :
    {
        *(.ARM.exidx*)
        *(.ARM.extab*)
    }
}
