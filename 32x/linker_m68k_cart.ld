/*
 * Linker script for Genesis 68K code in cartridge-boot mode.
 *
 * The 68K binary is embedded in the SH-2 ROM via .incbin at ROM offset 0x800.
 * After 32X activation, the 68K sees the ROM at 0x880000, so code at ROM
 * offset 0x800 is at 68K address 0x880800.
 *
 * The exception jump table at 0x200 in crt0_cart.s uses absolute addresses
 * like 0x880800, so this linker script must use ORIGIN = 0x880800 to ensure
 * labels resolve to the correct absolute 68K addresses.
 *
 * objcopy -O binary will strip the load address and output just the code,
 * starting at file byte 0 = 0x880800.
 *
 * Variables go in 68K work RAM at 0xFF0000-0xFFFFFF.
 */

MEMORY
{
    rom (rx)  : ORIGIN = 0x880800, LENGTH = 0x180000  /* ROM code space (up to ~1.5MB) */
    ram (rwx) : ORIGIN = 0xFF0000, LENGTH = 0x010000  /* 68K work RAM (64KB) */
}

SECTIONS
{
    .text : {
        *(.text*)
        *(.rodata*)
        . = ALIGN(4);
    } > rom

    .data : {
        *(.data*)
        . = ALIGN(4);
    } > rom  /* Data constants in ROM (read-only) */

    .bss (NOLOAD) : {
        __bss_start_m68k = .;
        *(.bss*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end_m68k = .;
    } > ram
}
