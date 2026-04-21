OUTPUT_ARCH(sh)
EXTERN (_start)
ENTRY (_start)
__DYNAMIC  =  0;

/*
 * Cartridge 32X Memory Map
 * ========================
 *
 * SH-2 sees cartridge ROM at 0x02000000 (via 32X adapter bus mapping).
 * The .text and .rodata sections live in ROM and execute in-place.
 * The .data section's LOAD address is in ROM (appended after .text)
 * but its virtual address is in SDRAM — crt0 copies it at startup.
 * The .bss section is zero-filled by crt0.
 *
 * +--------------------+ <- 0x02000000  (ROM, read-only)
 * | .text              |   Code + read-only data
 * |                    |   SH-2 executes directly from ROM
 * |         __text_end |
 * +--------------------+
 * | .data (LMA)        |   Initial values, copied to SDRAM by crt0
 * +--------------------+
 *
 * +--------------------+ <- 0x06000000  (SDRAM, read-write)
 * | .data (VMA)        |   Initialized data (copied from ROM)
 * |         __data_end |
 * +--------------------+
 * | .bss               |   Zeroed by crt0
 * |        __bss_start |
 * |         __bss_end  |
 * +--------------------+
 * .                    .
 * .  Heap / Level data .
 * .                    .
 * +--------------------+ <- 0x0603D000
 * | SH-2 Shared RAM    |   ~9 KB - master/slave shared data
 * +--------------------+ <- 0x0603F400
 * | Master SH-2 Stack  |   Grows down from 0x0603F400
 * +--------------------+
 * | Slave SH-2 Stack   |   3 KB (grows down from 0x06040000)
 * +--------------------+ <- 0x06040000
 */

MEMORY
{
    rom (rx) : ORIGIN = 0x02000000, LENGTH = 0x00400000
    ram (wx) : ORIGIN = 0x06000000, LENGTH = 0x0003D100
}

/*
 * Stack allocation:
 *   Master SH-2: grows down from 0x0603F400
 *   Slave SH-2:  grows down from 0x06040000 (3 KB above master)
 *
 * These values MUST match crt0.s!
 */
PROVIDE (__stack = 0x0603F400);

SECTIONS
{
  .text 0x02000000 :
  AT ( 0x00000000 )
  {
    __text_start = .;
    *(.text)
    *(.text.*)
    *(.gnu.linkonce.t.*)

    . = ALIGN(16);
    __INIT_SECTION__ = .;
    KEEP (*(.init))
    SHORT (0x000B)  /* rts */
    SHORT (0x0009)  /* nop */
    . = ALIGN(16);
    __FINI_SECTION__ = .;
    KEEP (*(.fini))
    SHORT (0x000B)  /* rts */
    SHORT (0x0009)  /* nop */

    *(.eh_frame_hdr)
    KEEP (*(.eh_frame))
    *(.gcc_except_table)
    *(.gcc_except_table.*)
    KEEP (*(.jcr))

    . = ALIGN(16);
     __CTOR_LIST__ = .;
    ___CTOR_LIST__ = .;
    LONG((__CTOR_END__ - __CTOR_LIST__) / 4 - 2)
    KEEP (*(SORT(.ctors.*)))
    KEEP (*(.ctors))
    LONG(0)
    __CTOR_END__ = .;

    . = ALIGN(16);
    __DTOR_LIST__ = .;
    ___DTOR_LIST__ = .;
    LONG((__DTOR_END__ - __DTOR_LIST__) / 4 - 2)
    KEEP (*(SORT(.dtors.*)))
    KEEP (*(.dtors))
     LONG(0)
    __DTOR_END__ = .;

    *(.rdata)
    *(.rodata)
    *(.rodata.*)
    *(.gnu.linkonce.r.*)
    . = ALIGN(16);
    __text_end = .;
  } > rom
  __text_size = __text_end - __text_start;

  .data 0x06000000 :
  AT ( LOADADDR (.text) + SIZEOF (.text) )
  {
    __data_start = .;
    *(.data)
    *(.data.*)
    *(.gnu.linkonce.d.*)
    CONSTRUCTORS

    *(.lit8)
    *(.lit4)
    *(.sdata)

    /* I-cache coloring: the hot wall loop is 4K-aligned so its
     * per-column callees (placed right after) occupy separate
     * cache lines.  Eliminates ~4000 I-cache misses/frame. */
    . = ALIGN(4096);
    *(.sdata.hot_loop)
    *(.sdata.hot_helpers)

    /* I-cache coloring: plane hot path gets its own 4K-aligned region
     * so it doesn't conflict with the wall loop/helpers above.  The
     * plane span drawer (R_MapPlaneSpanJQ) and its callers execute
     * hundreds of times per frame in multi-floor scenes. */
    . = ALIGN(4096);
    *(.sdata.hot_planes)

    /* Wall texture pass: R_DrawTexturedWallsPassJQ + callees
     * (R_ComputeWallColumnLightAndTexcol, R_DrawUpperLowerColumns,
     * R_DegenerateFills).  Runs AFTER prep phase and interleaves
     * with hot_helpers (column drawers).  Placed after hot_planes
     * with no alignment gap — both wall_tex and planes execute in
     * different phases so cache aliasing is acceptable. */
    *(.sdata.hot_wall_tex)

    *(.sdata.*)
    *(.gnu.linkonce.s.*)

    /* ============================================================
     * Z80 CPU core: hot/cold split for I-cache optimization.
     *
     * SH-2 cache: 4 KB unified, 4-way set-associative, 64 sets × 16 B.
     * Cache index = address bits [9:4].
     *
     * Strategy: place the Z80 fetch loop, dispatch table, and top ~30
     * opcode handlers in a contiguous block (subsection 0) that fits
     * within ~4 KB.  Hot data tables (PZSTable, IncFlags, DecFlags)
     * go in .hot_z80_data, padded to reduce cache conflicts.
     * All remaining Z80 data goes in .cold_z80_data.
     *
     * GAS .subsection ensures hot code (subsection 0) is placed before
     * cold code (subsection 1) within the single .z80_code section.
     * 4K-align so cache set mapping is predictable.
     * ============================================================ */

    . = ALIGN(4096);
    __z80_hot_start = .;
    KEEP(*(.z80_code))
    __z80_code_end = .;

    /* Hot Z80 data tables — PZSTable, IncFlags, DecFlags, RegOffsets */
    . = ALIGN(16);
    KEEP(*(.hot_z80_data))
    __z80_hot_end = .;

    /* Cold Z80 data — timing tables (Cycles, ZSTable) */
    . = ALIGN(16);
    KEEP(*(.cold_z80_data))

    /* Legacy catch-all for any remaining sdram_code/data */
    KEEP(*(.sdram_code))
    KEEP(*(.sdram_data))

    . = ALIGN(16);
    __data_end = .;
  } > ram
  __data_size = __data_end - __data_start;

  .bss :
  {
    __bss_start = .;
    *(.bss)
    *(.bss.*)
    *(.gnu.linkonce.b.*)
    *(.sbss)
    *(.sbss.*)
    *(.gnu.linkonce.sb.*)
    *(.scommon)
    *(COMMON)
    . = ALIGN(16);
    end = .;
    _end = end;
    __end = _end;
    __bss_end = .;
  } > ram
  __bss_size = __bss_end - __bss_start;

}
