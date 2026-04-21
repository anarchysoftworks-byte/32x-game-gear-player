!-----------------------------------------------------------------------
! SEGA 32X Cartridge Boot - SH2 ROM header and init/exception code
! Based on Chilly Willy's d32xr crt0.s, adapted for Game Gear 32X
!
! This file provides:
!   - 68000 exception vector table (0x000)
!   - Genesis/MegaDrive ROM header (0x100)
!   - 68000 exception jump table for MARS mode (0x200)
!   - Mars extended header (0x3C0)
!   - Standard 32X startup code (0x3F0)
!   - Embedded 68K program code (incbin at 0x800)
!   - SH-2 Master/Slave vector base tables
!   - SH-2 boot + IRQ handler code
!
! Must be FIRST in object list!
!-----------------------------------------------------------------------

        .text

!-----------------------------------------------------------------------
! 68000 exception vector table at 0x000
!
! When the console is first turned on, it is in MegaDrive mode.
! All vectors point to the 32X startup code at 0x3F0.
! After the adapter is enabled, the MARS boot ROM overlays this
! table and routes exceptions via the jump table at 0x200.
!-----------------------------------------------------------------------

        .long   0x01000000,0x000003F0,0x000003F0,0x000003F0,0x000003F0,0x000003F0,0x000003F0,0x000003F0
        .long   0x000003F0,0x000003F0,0x000003F0,0x000003F0,0x000003F0,0x000003F0,0x000003F0,0x000003F0
        .long   0x000003F0,0x000003F0,0x000003F0,0x000003F0,0x000003F0,0x000003F0,0x000003F0,0x000003F0
        .long   0x000003F0,0x000003F0,0x000003F0,0x000003F0,0x000003F0,0x000003F0,0x000003F0,0x000003F0
        .long   0x000003F0,0x000003F0,0x000003F0,0x000003F0,0x000003F0,0x000003F0,0x000003F0,0x000003F0
        .long   0x000003F0,0x000003F0,0x000003F0,0x000003F0,0x000003F0,0x000003F0,0x000003F0,0x000003F0
        .long   0x000003F0,0x000003F0,0x000003F0,0x000003F0,0x000003F0,0x000003F0,0x000003F0,0x000003F0
        .long   0x000003F0,0x000003F0,0x000003F0,0x000003F0,0x000003F0,0x000003F0,0x000003F0,0x000003F0

!-----------------------------------------------------------------------
! Standard MegaDrive ROM header at 0x100
!-----------------------------------------------------------------------

        .ascii  "SEGA 32X        "                      /* Console name */
        .ascii  "(C) ASW 2026    "                      /* Copyright */
        .ascii  "MASTER SYSTEM 32"                      /* Domestic name */
        .ascii  "X EMULATOR V1.0 "
        .ascii  "                "
        .ascii  "MASTER SYSTEM 32"                      /* Overseas name */
        .ascii  "X EMULATOR V1.0 "
        .ascii  "                "
        .ascii  "GM MS32XEMU-01"                        /* Serial number */
        .word   0x0000                                  /* Checksum (filled by romheaderfix) */
        .ascii  "J               "                      /* I/O support (J = 3-button joypad) */
        .long   0x00000000,0x003FFFFF                   /* ROM start, end (4MB) */
        .long   0x00FF0000,0x00FFFFFF                   /* RAM start, end */

        /* No SRAM for now */
        .ascii  "            "

        .ascii  "    "
        .ascii  "                "
        .ascii  "                "
        .ascii  "                "
        .ascii  "F               "                      /* enable any hardware configuration */

!-----------------------------------------------------------------------
! Mars 68000 exception jump table at 0x200
!
! After 32X activation, the MARS boot ROM overlays the original
! 68000 vector table and uses this jump table to route exceptions.
! Entries use absolute long jumps into the embedded 68K code at 0x880800+.
!-----------------------------------------------------------------------

        .macro  jump address
        .word   0x4EF9,\address>>16,\address&0xFFFF
        .endm

        .macro  call address
        .word   0x4EB9,\address>>16,\address&0xFFFF
        .endm

        jump    0x880800    /* reset = hot start (68K main code entry) */
        call    0x880840    /* EX_BusError */
        call    0x880840    /* EX_AddrError */
        call    0x880840    /* EX_IllInstr */
        call    0x880840    /* EX_DivByZero */
        call    0x880840    /* EX_CHK */
        call    0x880840    /* EX_TrapV */
        call    0x880840    /* EX_Priviledge */
        call    0x880840    /* EX_Trace */
        call    0x880840    /* EX_LineA */
        call    0x880840    /* EX_LineF */
        .space  72          /* reserved */
        call    0x880840    /* EX_Spurious */
        call    0x880840    /* EX_Level1 */
        jump    0x880900    /* EX_Level2 EXT */
        call    0x880840    /* EX_Level3 */
        jump    0x880880    /* EX_Level4 HBlank */
        call    0x880840    /* EX_Level5 */
        jump    0x8808C0    /* EX_Level6 VBlank */
        call    0x880840    /* EX_Level7 */
        call    0x880840    /* EX_Trap0 */
        call    0x880840    /* EX_Trap1 */
        call    0x880840    /* EX_Trap2 */
        call    0x880840    /* EX_Trap3 */
        call    0x880840    /* EX_Trap4 */
        call    0x880840    /* EX_Trap5 */
        call    0x880840    /* EX_Trap6 */
        call    0x880840    /* EX_Trap7 */
        call    0x880840    /* EX_Trap8 */
        call    0x880840    /* EX_Trap9 */
        call    0x880840    /* EX_TrapA */
        call    0x880840    /* EX_TrapB */
        call    0x880840    /* EX_TrapC */
        call    0x880840    /* EX_TrapD */
        call    0x880840    /* EX_TrapE */
        call    0x880840    /* EX_TrapF */
        .space  166         /* reserved */

!-----------------------------------------------------------------------
! Standard Mars Header at 0x3C0
!
! The MARS boot ROM reads this header to configure the SH-2 CPUs.
! It contains the ROM→SDRAM copy descriptor and SH-2 entry points.
!-----------------------------------------------------------------------

        .ascii  "32X GG PLAYER   "      /* Module name */
        .long   0x00000000              /* Version */
        .long   __text_end-0x02000000   /* Source offset in ROM (.data load address) */
        .long   0x00000000              /* Destination in SDRAM (0x06000000 + 0 = base) */
        .long   __data_size             /* Size of .data to copy */
        .long   master_start            /* Master SH2 entry point */
        .long   slave_start             /* Slave SH2 entry point */
        .long   master_vbr              /* Master SH2 VBR */
        .long   slave_vbr               /* Slave SH2 VBR */

!-----------------------------------------------------------------------
! Standard 32X startup code for MD side at 0x3F0
!
! This is the canonical Chilly Willy 32X bootstrap. It runs on the
! 68000 in MegaDrive mode before the MARS adapter is activated.
! It initializes the 32X hardware, copies SH-2 data from ROM to
! SDRAM, clears framebuffers and CRAM, verifies SH-2 startup,
! and then jumps to the embedded 68K code.
!-----------------------------------------------------------------------

        .word   0x287C,0xFFFF,0xFFC0,0x23FC,0x0000,0x0000,0x00A1,0x5128
        .word   0x46FC,0x2700,0x4BF9,0x00A1,0x0000,0x7001,0x0CAD,0x4D41
        .word   0x5253,0x30EC,0x6600,0x03E6,0x082D,0x0007,0x5101,0x67F8
        .word   0x4AAD,0x0008,0x6710,0x4A6D,0x000C,0x670A,0x082D,0x0000
        .word   0x5101,0x6600,0x03B8,0x102D,0x0001,0x0200,0x000F,0x6706
        .word   0x2B78,0x055A,0x4000,0x7200,0x2C41,0x4E66,0x41F9,0x0000
        .word   0x04D4,0x6100,0x0152,0x6100,0x0176,0x47F9,0x0000,0x04E8
        .word   0x43F9,0x00A0,0x0000,0x45F9,0x00C0,0x0011,0x3E3C,0x0100
        .word   0x7000,0x3B47,0x1100,0x3B47,0x1200,0x012D,0x1100,0x66FA
        .word   0x7425,0x12DB,0x51CA,0xFFFC,0x3B40,0x1200,0x3B40,0x1100
        .word   0x3B47,0x1200,0x149B,0x149B,0x149B,0x149B,0x41F9,0x0000
        .word   0x04C0,0x43F9,0x00FF,0x0000,0x22D8,0x22D8,0x22D8,0x22D8
        .word   0x22D8,0x22D8,0x22D8,0x22D8,0x41F9,0x00FF,0x0000,0x4ED0
        .word   0x1B7C,0x0001,0x5101,0x41F9,0x0000,0x06BC,0xD1FC,0x0088
        .word   0x0000,0x4ED0,0x0404,0x303C,0x076C,0x0000,0x0000,0xFF00
        .word   0x8137,0x0002,0x0100,0x0000,0xAF01,0xD91F,0x1127,0x0021
        .word   0x2600,0xF977,0xEDB0,0xDDE1,0xFDE1,0xED47,0xED4F,0xD1E1
        .word   0xF108,0xD9C1,0xD1E1,0xF1F9,0xF3ED,0x5636,0xE9E9,0x9FBF
        .word   0xDFFF,0x4D41,0x5253,0x2049,0x6E69,0x7469,0x616C,0x2026
        .word   0x2053,0x6563,0x7572,0x6974,0x7920,0x5072,0x6F67,0x7261
        .word   0x6D20,0x2020,0x2020,0x2020,0x2020,0x2043,0x6172,0x7472
        .word   0x6964,0x6765,0x2056,0x6572,0x7369,0x6F6E,0x2020,0x2020
        .word   0x436F,0x7079,0x7269,0x6768,0x7420,0x5345,0x4741,0x2045
        .word   0x4E54,0x4552,0x5052,0x4953,0x4553,0x2C4C,0x5444,0x2E20
        .word   0x3139,0x3934,0x2020,0x2020,0x2020,0x2020,0x2020,0x2020
        .word   0x2020,0x2020,0x2020,0x2020,0x2020,0x2020,0x2020,0x2020
        .word   0x2020,0x2020,0x2020,0x524F,0x4D20,0x5665,0x7273,0x696F
        .word   0x6E20,0x312E,0x3000,0x48E7,0xC040,0x43F9,0x00C0,0x0004
        .word   0x3011,0x303C,0x8000,0x323C,0x0100,0x3E3C,0x0012,0x1018
        .word   0x3280,0xD041,0x51CF,0xFFF8,0x4CDF,0x0203,0x4E75,0x48E7
        .word   0x81C0,0x41F9,0x0000,0x063E,0x43F9,0x00C0,0x0004,0x3298
        .word   0x3298,0x3298,0x3298,0x3298,0x3298,0x3298,0x2298,0x3341
        .word   0xFFFC,0x3011,0x0800,0x0001,0x66F8,0x3298,0x3298,0x7000
        .word   0x22BC,0xC000,0x0000,0x7E0F,0x3340,0xFFFC,0x3340,0xFFFC
        .word   0x3340,0xFFFC,0x3340,0xFFFC,0x51CF,0xFFEE,0x22BC,0x4000
        .word   0x0010,0x7E09,0x3340,0xFFFC,0x3340,0xFFFC,0x3340,0xFFFC
        .word   0x3340,0xFFFC,0x51CF,0xFFEE,0x4CDF,0x0381,0x4E75,0x8114
        .word   0x8F01,0x93FF,0x94FF,0x9500,0x9600,0x9780,0x4000,0x0080
        .word   0x8104,0x8F02,0x48E7,0xC140,0x43F9,0x00A1,0x5180,0x08A9
        .word   0x0007,0xFF80,0x66F8,0x3E3C,0x00FF,0x7000,0x7200,0x337C
        .word   0x00FF,0x0004,0x3341,0x0006,0x3340,0x0008,0x4E71,0x0829
        .word   0x0001,0x000B,0x66F8,0x0641,0x0100,0x51CF,0xFFE8,0x4CDF
        .word   0x0283,0x4E75,0x48E7,0x8180,0x41F9,0x00A1,0x5200,0x08A8
        .word   0x0007,0xFF00,0x66F8,0x3E3C,0x001F,0x20C0,0x20C0,0x20C0
        .word   0x20C0,0x51CF,0xFFF6,0x4CDF,0x0181,0x4E75,0x41F9,0x00FF
        .word   0x0000,0x3E3C,0x07FF,0x7000,0x20C0,0x20C0,0x20C0,0x20C0
        .word   0x20C0,0x20C0,0x20C0,0x20C0,0x51CF,0xFFEE,0x3B7C,0x0000
        .word   0x1200,0x7E0A,0x51CF,0xFFFE,0x43F9,0x00A1,0x5100,0x7000
        .word   0x2340,0x0020,0x2340,0x0024,0x1B7C,0x0003,0x5101,0x2E79
        .word   0x0088,0x0000,0x0891,0x0007,0x66FA,0x7000,0x3340,0x0002
        .word   0x3340,0x0004,0x3340,0x0006,0x2340,0x0008,0x2340,0x000C
        .word   0x3340,0x0010,0x3340,0x0030,0x3340,0x0032,0x3340,0x0038
        .word   0x3340,0x0080,0x3340,0x0082,0x08A9,0x0000,0x008B,0x66F8
        .word   0x6100,0xFF12,0x08E9,0x0000,0x008B,0x67F8,0x6100,0xFF06
        .word   0x08A9,0x0000,0x008B,0x6100,0xFF3C,0x303C,0x0040,0x2229
        .word   0x0020,0x0C81,0x5351,0x4552,0x6700,0x0092,0x303C,0x0080
        .word   0x2229,0x0020,0x0C81,0x5344,0x4552,0x6700,0x0080,0x21FC
        .word   0x0088,0x02A2,0x0070,0x303C,0x0002,0x7200,0x122D,0x0001
        .word   0x1429,0x0080,0xE14A,0x8242,0x0801,0x000F,0x660A,0x0801
        .word   0x0006,0x6700,0x0058,0x6008,0x0801,0x0006,0x6600,0x004E
        .word   0x7020,0x41F9,0x0088,0x0000,0x3C28,0x018E,0x4A46,0x6700
        .word   0x0010,0x3429,0x0028,0x0C42,0x0000,0x67F6,0xB446,0x662C
        .word   0x7000,0x2340,0x0028,0x2340,0x002C,0x3E14,0x2C7C,0xFFFF
        .word   0xFFC0,0x4CD6,0x7FF9,0x44FC,0x0000,0x6014,0x43F9,0x00A1
        .word   0x5100,0x3340,0x0006,0x303C,0x8000,0x6004,0x44FC,0x0001

!-----------------------------------------------------------------------
! At this point (0x800), the Work RAM is clear, the VDP initialized,
! the VRAM/VSRAM/CRAM cleared, the Z80 initialized, the 32X initialized,
! both 32X framebuffers cleared, the 32X palette cleared, the SH2s
! checked for a startup error, the adapter TV mode matches the MD TV
! mode, and the ROM checksum checked. If any error is detected, the
! carry is set, otherwise it is cleared. The 68000 main code starts.
!-----------------------------------------------------------------------

        .incbin "build/m68k.bin"        /* 68000 code, compiled to run at 0x880800/0xFF0000 */

!-----------------------------------------------------------------------
! Embedded ROM images
!
! Both .gg and .gg files are included here at 16-byte-aligned
! boundaries in the cartridge ROM.  The SH-2 accesses them in place
! via the ROM bus at 0x02000000 + offset.
! Symbols are exported for C code; runtime detection selects which
! ROM to use (see main.c).
! Public source release note: no commercial ROM is bundled here.
! Point this .incbin at your own Game Gear ROM before building.
!-----------------------------------------------------------------------

        .align  4
        .global _rom_data
_rom_data:
        .incbin "../YOUR_ROM_HERE.gg"
_rom_end:

        .align  4
        .global _rom_size
_rom_size:
        .long   _rom_end - _rom_data

!-----------------------------------------------------------------------
! SH-2 Data Section
! Vector tables and boot code go here — loaded into SDRAM by Mars boot ROM
!-----------------------------------------------------------------------

        .section .sdata

!-----------------------------------------------------------------------
! Master Vector Base Table
!-----------------------------------------------------------------------

        .equ    master_stack, 0x0603F400
        .equ    slave_stack,  0x06040000

        .align  4
master_vbr:
        .long   master_start    /* Cold Start PC */
        .long   master_stack    /* Cold Start SP */
        .long   master_start    /* Manual Reset PC */
        .long   master_stack    /* Manual Reset SP */
        .long   master_err      /* Illegal instruction */
        .long   0x00000000      /* reserved */
        .long   master_err      /* Invalid slot instruction */
        .long   0x00000000      /* reserved */
        .long   0x00000000      /* reserved */
        .long   master_err      /* CPU address error */
        .long   master_err      /* DMA address error */
        .long   master_err      /* NMI vector */
        .long   master_err      /* User break vector */
        .space  76              /* reserved */
        .long   master_err      /* TRAPA #32 */
        .long   master_err      /* TRAPA #33 */
        .long   master_err      /* TRAPA #34 */
        .long   master_err      /* TRAPA #35 */
        .long   master_err      /* TRAPA #36 */
        .long   master_err      /* TRAPA #37 */
        .long   master_err      /* TRAPA #38 */
        .long   master_err      /* TRAPA #39 */
        .long   master_err      /* TRAPA #40 */
        .long   master_err      /* TRAPA #41 */
        .long   master_err      /* TRAPA #42 */
        .long   master_err      /* TRAPA #43 */
        .long   master_err      /* TRAPA #44 */
        .long   master_err      /* TRAPA #45 */
        .long   master_err      /* TRAPA #46 */
        .long   master_err      /* TRAPA #47 */
        .long   master_err      /* TRAPA #48 */
        .long   master_err      /* TRAPA #49 */
        .long   master_err      /* TRAPA #50 */
        .long   master_err      /* TRAPA #51 */
        .long   master_err      /* TRAPA #52 */
        .long   master_err      /* TRAPA #53 */
        .long   master_err      /* TRAPA #54 */
        .long   master_err      /* TRAPA #55 */
        .long   master_err      /* TRAPA #56 */
        .long   master_err      /* TRAPA #57 */
        .long   master_err      /* TRAPA #58 */
        .long   master_err      /* TRAPA #59 */
        .long   master_err      /* TRAPA #60 */
        .long   master_err      /* TRAPA #61 */
        .long   master_err      /* TRAPA #62 */
        .long   master_err      /* TRAPA #63 */
        .long   master_lvl1     /* Level 1 IRQ (FRT) */
        .long   master_lvl2_3   /* Level 2 & 3 IRQ (WDT) */
        .long   master_lvl4_5   /* Level 4 & 5 IRQ (DMA) */
        .long   master_pwm      /* PWM interrupt (Level 6 & 7) */
        .long   master_cmd      /* Command interrupt (Level 8 & 9) */
        .long   master_hbi      /* H Blank interrupt (Level 10 & 11) */
        .long   master_vbi      /* V Blank interrupt (Level 12 & 13) */
        .long   master_rst      /* Reset Button (Level 14 & 15) */

!-----------------------------------------------------------------------
! Slave Vector Base Table
!-----------------------------------------------------------------------

slave_vbr:
        .long   slave_start     /* Cold Start PC */
        .long   slave_stack     /* Cold Start SP */
        .long   slave_start     /* Manual Reset PC */
        .long   slave_stack     /* Manual Reset SP */
        .long   slave_err       /* Illegal instruction */
        .long   0x00000000      /* reserved */
        .long   slave_err       /* Invalid slot instruction */
        .long   0x00000000      /* reserved */
        .long   0x00000000      /* reserved */
        .long   slave_err       /* CPU address error */
        .long   slave_err       /* DMA address error */
        .long   slave_err       /* NMI vector */
        .long   slave_err       /* User break vector */
        .space  76              /* reserved */
        .long   slave_err       /* TRAPA #32 */
        .long   slave_err       /* TRAPA #33 */
        .long   slave_err       /* TRAPA #34 */
        .long   slave_err       /* TRAPA #35 */
        .long   slave_err       /* TRAPA #36 */
        .long   slave_err       /* TRAPA #37 */
        .long   slave_err       /* TRAPA #38 */
        .long   slave_err       /* TRAPA #39 */
        .long   slave_err       /* TRAPA #40 */
        .long   slave_err       /* TRAPA #41 */
        .long   slave_err       /* TRAPA #42 */
        .long   slave_err       /* TRAPA #43 */
        .long   slave_err       /* TRAPA #44 */
        .long   slave_err       /* TRAPA #45 */
        .long   slave_err       /* TRAPA #46 */
        .long   slave_err       /* TRAPA #47 */
        .long   slave_err       /* TRAPA #48 */
        .long   slave_err       /* TRAPA #49 */
        .long   slave_err       /* TRAPA #50 */
        .long   slave_err       /* TRAPA #51 */
        .long   slave_err       /* TRAPA #52 */
        .long   slave_err       /* TRAPA #53 */
        .long   slave_err       /* TRAPA #54 */
        .long   slave_err       /* TRAPA #55 */
        .long   slave_err       /* TRAPA #56 */
        .long   slave_err       /* TRAPA #57 */
        .long   slave_err       /* TRAPA #58 */
        .long   slave_err       /* TRAPA #59 */
        .long   slave_err       /* TRAPA #60 */
        .long   slave_err       /* TRAPA #61 */
        .long   slave_err       /* TRAPA #62 */
        .long   slave_err       /* TRAPA #63 */
        .long   slave_lvl1      /* Level 1 IRQ (FRT) */
        .long   slave_lvl2_3    /* Level 2 & 3 IRQ (WDT) */
        .long   slave_lvl4_5    /* Level 4 & 5 IRQ (DMA) */
        .long   slave_pwm       /* PWM interrupt (Level 6 & 7) */
        .long   slave_cmd       /* Command interrupt (Level 8 & 9) */
        .long   slave_hbi       /* H Blank interrupt (Level 10 & 11) */
        .long   slave_vbi       /* V Blank interrupt (Level 12 & 13) */
        .long   slave_rst       /* Reset Button (Level 14 & 15) */

!-----------------------------------------------------------------------
! The Master SH2 starts here
!-----------------------------------------------------------------------

master_start:
        ! EARLY DEBUG: prove SH-2 reached master_start
        mov.l   _master_comm14,r3
        mov     #-1,r0
        mov.w   r0,@r3                  /* COMM14 = 0xFFFF */

        ! clear interrupt flags
        mov.l   _master_int_clr,r1
        mov.w   r0,@-r1                 /* PWM INT clear */
        mov.w   r0,@r1
        mov.w   r0,@-r1                 /* CMD INT clear */
        mov.w   r0,@r1
        mov.w   r0,@-r1                 /* H INT clear */
        mov.w   r0,@r1
        mov.w   r0,@-r1                 /* V INT clear */
        mov.w   r0,@r1
        mov.w   r0,@-r1                 /* VRES INT clear */
        mov.w   r0,@r1

        ! Set Free Run Timer (matches d32xr pri_start)
        mov.l   _master_frtctl,r1
        mov     #0x00,r0
        mov.b   r0,@(0x00,r1)           /* TIER = ints disabled */
        mov     #0xE2,r0
        mov.b   r0,@(0x07,r1)           /* TOCR = select OCRA, output 1 on compare match */
        mov     #0x00,r0
        mov.b   r0,@(0x04,r1)           /* OCR_H */
        mov     #0x01,r0
        mov.b   r0,@(0x05,r1)           /* OCR_L => OCRA = 0x0001 */
        mov     #0,r0
        mov.b   r0,@(0x06,r1)           /* TCR = input captured on falling edge, CKS = Fs/8 */
        mov     #1,r0
        mov.b   r0,@(0x01,r1)           /* TCSR = clear FRC on match OCRA */
        mov     #0x00,r0
        mov.b   r0,@(0x03,r1)           /* FRC_L */
        mov.b   r0,@(0x02,r1)           /* FRC_H => clear FRC */

        mov.l   _master_stk,r15

        ! purge cache and turn it off
        mov.l   _master_cctl,r0
        mov     #0x10,r1                /* CP = cache purge, /CE = disabled */
        mov.b   r1,@r0

        ! DEBUG step 0xBB: about to start BSS clear
        mov     #0xBB,r0
        extu.b  r0,r0
        mov.w   r0,@r3

        ! NOTE: .data copy from ROM to SDRAM is handled by the MARS boot ROM
        ! using the Mars header at 0x3C0.  Do NOT duplicate it here.
        ! All SH-2 code executes directly from ROM (d32xr style).

        ! clear bss
        mov     #0,r0
        mov.l   _bss_dst,r1
        mov.l   _bss_end,r2
2:
        mov.b   r0,@r1
        add     #1,r1
        cmp/eq  r1,r2
        bf      2b

        ! DEBUG step 0xCC: BSS clear done
        mov     #0xCC,r0
        extu.b  r0,r0
        mov.w   r0,@r3

        ! Signal 68K that the Master SH-2 is ready.
        ! Write 'M_' (0x4D5F) to COMM0 (16-bit), then wait for 68K to clear it.
        mov.l   _master_sts,r0
        mov.l   _master_ok,r1
        mov.w   r1,@r0                  /* COMM0 = 0x4D5F ('M_') */

        ! DEBUG step 0xDD: M_OK written, entering poll loop
        mov     #0xDD,r0
        extu.b  r0,r0
        mov.w   r0,@r3

        ! reload r3 for later step tracing (after clobbered above)
        mov.l   _master_comm14,r3

3:
        mov.w   @r0,r2
        nop
        nop
        extu.w  r2,r2                   /* zero-extend for compare */
        cmp/eq  r1,r2
        bt      3b                      /* loop while COMM0 == 'M_' */

        ! DEBUG step 1: M_OK loop exited
        mov     #0x01,r0
        mov.w   r0,@r3

        mov     #0x80,r0
        mov.l   _master_adapter,r1
        mov.b   r0,@r1                  /* set FM = 1 (SH-2 owns framebuffer) */

        ! DEBUG step 2: FM bit set
        mov     #0x02,r0
        mov.w   r0,@r3

        mov     #0x0A,r0                /* VBI and CMD enabled (HBI disabled) */
        mov.b   r0,@(1,r1)             /* set int enables */

        ! DEBUG step 3: int enables set
        mov     #0x03,r0
        mov.w   r0,@r3

        mov     #0x10,r0
        ldc     r0,sr                   /* allow ints (imask=1) */

        ! DEBUG step 4: SR set (ints enabled)
        mov     #0x04,r0
        mov.w   r0,@r3

        ! purge cache, turn it on, and run main()
        mov.l   _master_cctl,r0
        mov     #0x11,r1                /* CP = cache purge, CE = cache enabled */
        mov.b   r1,@r0

        ! DEBUG step 5: cache enabled, jumping to main
        mov     #0x05,r0
        mov.w   r0,@r3

        mov.l   _master_go,r0
        jmp     @r0
        nop

        .align   2

_master_comm14:
        .long   0x2000402E

_master_int_clr:
        .long   0x2000401E              /* one word past last int clr reg */
_master_frtctl:
        .long   0xFFFFFE10
_master_stk:
        .long   master_stack
_master_sts:
        .long   0x20004020              /* COMM0 */
_master_ok:
        .long   0x4D5F                  /* 'M_' token (16-bit) */
_master_adapter:
        .long   0x20004000
_master_cctl:
        .long   0xFFFFFE92
_master_go:
        .long   _main

_bss_dst:
        .long   __bss_start
_bss_end:
        .long   __bss_end

!-----------------------------------------------------------------------
! Master exception handler
! Advances saved PC by 2 to skip past the faulting instruction,
! then returns from exception.
!-----------------------------------------------------------------------

master_err:
        rte
        nop

!-----------------------------------------------------------------------
! Master Level 1 IRQ handler (FRT)
!-----------------------------------------------------------------------

master_lvl1:
        rte
        nop

!-----------------------------------------------------------------------
! Master Level 2/3 IRQ handler (WDT)
!-----------------------------------------------------------------------

master_lvl2_3:
        rte
        nop

!-----------------------------------------------------------------------
! Master Level 4/5 IRQ handler (DMA)
!-----------------------------------------------------------------------

master_lvl4_5:
        rte
        nop

!-----------------------------------------------------------------------
! Master V Blank IRQ handler
!-----------------------------------------------------------------------

master_vbi:
        mov.l   r0,@-r15
        mov.l   r1,@-r15

        mov.l   mvi_mars_adapter,r1
        mov.w   r0,@(0x16,r1)           /* clear V IRQ */
        nop
        nop
        nop
        nop

        ! If overlay HINT is active, reset DISPMODE and clear COMM4 flag
        mov.l   mvi_overlay_flag,r0
        mov.l   @r0,r1
        tst     r1,r1
        bt      .mvi_skip_overlay

        ! Reset DISPMODE to 256-color, 32X priority (FP=0)
        mov.l   mvi_dispmode_addr,r0
        mov     #1,r1                   /* MARS_VDP_MODE_256 */
        mov.w   r1,@r0

        ! Clear COMM4 bit 15 (overlay trigger flag from 68K HBlank)
        mov.l   mvi_comm4_addr,r0
        mov.w   @r0,r1
        extu.w  r1,r1
        mov.l   mvi_comm4_mask,r0
        and     r0,r1
        mov.l   mvi_comm4_addr,r0
        mov.w   r1,@r0

.mvi_skip_overlay:
        mov.l   @r15+,r1
        mov.l   @r15+,r0
        rte
        nop

        .align  2

mvi_mars_adapter:
        .long   0x20004000
mvi_overlay_flag:
        .long   _overlay_hint_active
mvi_dispmode_addr:
        .long   0x20004100
mvi_comm4_addr:
        .long   0x20004024
mvi_comm4_mask:
        .long   0x00007FFF

!-----------------------------------------------------------------------
! Master H Blank IRQ handler
!-----------------------------------------------------------------------

master_hbi:
        mov.l   r0,@-r15
        mov.l   r1,@-r15

        ! Clear H IRQ
        mov.l   mhi_adapter,r1
        mov.w   r0,@(0x18,r1)           /* clear HINT at 0x20004018 */
        nop
        nop
        nop
        nop

        ! Check if overlay HINT is active
        mov.l   mhi_flag_addr,r1
        mov.l   @r1,r0
        tst     r0,r0
        bt      .mhi_done

        ! Check COMM4 bit 15 — set by 68K HBlank at the exact scanline
        ! via hardware-timed Genesis VDP register 10 counter.
        ! mov.w sign-extends: bit 15=1 → r0 is negative → cmp/pz fails.
        mov.l   mhi_comm4_addr,r1
        mov.w   @r1,r0
        cmp/pz  r0                      /* T=1 if bit 15=0 (no trigger) */
        bt      .mhi_done               /* skip if flag not set */

        ! Flag is set — switch DISPMODE to MD priority (FP=1)
        mov.l   mhi_overlay_dispmode,r0 /* 0x0081 = 256-color | FP=1 */
        mov.l   mhi_dispmode_addr,r1
        mov.w   r0,@r1

.mhi_done:
        mov.l   @r15+,r1
        mov.l   @r15+,r0
        rte
        nop

        .align  2

mhi_adapter:
        .long   0x20004000
mhi_flag_addr:
        .long   _overlay_hint_active
mhi_comm4_addr:
        .long   0x20004024
mhi_dispmode_addr:
        .long   0x20004100
mhi_overlay_dispmode:
        .long   0x0081

!-----------------------------------------------------------------------
! Master Command IRQ handler
!-----------------------------------------------------------------------

master_cmd:
        mov.l   r0,@-r15
        mov.l   r1,@-r15

        mov.l   mci_mars_adapter,r1
        mov.w   r0,@(0x1A,r1)           /* clear CMD IRQ */
        nop
        nop
        nop
        nop

        ! handle CMD IRQ

        mov.l   @r15+,r1
        mov.l   @r15+,r0
        rte
        nop

        .align  2

mci_mars_adapter:
        .long   0x20004000

!-----------------------------------------------------------------------
! Master PWM IRQ handler
!-----------------------------------------------------------------------

master_pwm:
        mov.l   r0,@-r15
        mov.l   r1,@-r15

        mov.l   mpi_mars_adapter,r1
        mov.w   r0,@(0x1C,r1)           /* clear PWM IRQ */
        nop
        nop
        nop
        nop

        ! handle PWM IRQ

        mov.l   @r15+,r1
        mov.l   @r15+,r0
        rte
        nop

        .align  2

mpi_mars_adapter:
        .long   0x20004000

!-----------------------------------------------------------------------
! Master RESET IRQ handler
!-----------------------------------------------------------------------

master_rst:
        mov.l   mvri_mars_adapter,r1
        mov.w   r0,@(0x14,r1)           /* clear VRES IRQ */
        nop
        nop
        nop
        nop

        mov     #0x0F,r0
        shll2   r0
        shll2   r0
        ldc     r0,sr                   /* disallow ints */

        mov.l   mvri_master_stk,r15
        mov.l   mvri_master_vres,r0
        jmp     @r0
        nop

        .align  2

mvri_mars_adapter:
        .long   0x20004000
mvri_master_stk:
        .long   master_stack
mvri_master_vres:
        .long   master_reset

!-----------------------------------------------------------------------
! The Slave SH2 starts here
!-----------------------------------------------------------------------

slave_start:
        ! clear interrupt flags
        mov.l   _slave_int_clr,r1
        mov.w   r0,@-r1                 /* PWM INT clear */
        mov.w   r0,@r1
        mov.w   r0,@-r1                 /* CMD INT clear */
        mov.w   r0,@r1
        mov.w   r0,@-r1                 /* H INT clear */
        mov.w   r0,@r1
        mov.w   r0,@-r1                 /* V INT clear */
        mov.w   r0,@r1
        mov.w   r0,@-r1                 /* VRES INT clear */
        mov.w   r0,@r1

        ! Set Free Run Timer (matches d32xr sec_start)
        mov.l   _slave_frtctl,r1
        mov     #0x00,r0
        mov.b   r0,@(0x00,r1)           /* TIER = ints disabled */
        mov     #0xE2,r0
        mov.b   r0,@(0x07,r1)           /* TOCR = select OCRA, output 1 on compare match */
        mov     #0x00,r0
        mov.b   r0,@(0x04,r1)           /* OCR_H */
        mov     #0x01,r0
        mov.b   r0,@(0x05,r1)           /* OCR_L => OCRA = 0x0001 */
        mov     #0,r0
        mov.b   r0,@(0x06,r1)           /* TCR = input captured on falling edge, CKS = Fs/8 */
        mov     #1,r0
        mov.b   r0,@(0x01,r1)           /* TCSR = clear FRC on match OCRA */
        mov     #0x00,r0
        mov.b   r0,@(0x03,r1)           /* FRC_L */
        mov.b   r0,@(0x02,r1)           /* FRC_H => clear FRC */

        mov.l   _slave_stk,r15

        ! Signal 68K that the Slave SH-2 is ready.
        ! Write 'S_' (0x535F) to COMM4 (16-bit), then wait for 68K to clear it.
        mov.l   _slave_sts,r0
        mov.l   _slave_ok,r1
        mov.w   r1,@r0                  /* COMM4 = 0x535F ('S_') */
1:
        mov.w   @r0,r2
        nop
        nop
        extu.w  r2,r2
        cmp/eq  r1,r2
        bt      1b                      /* loop while COMM4 == 'S_' */

        mov.l   _slave_adapter,r1
        mov     #0x0A,r0                /* VBI + CMD enabled */
        mov.b   r0,@(1,r1)             /* set int enables */
        mov     #0x10,r0
        ldc     r0,sr                   /* allow ints (imask=1, matches d32xr) */

! purge cache, turn it on, and run slave()
        mov.l   _slave_cctl,r0
        mov     #0x11,r1
        mov.b   r1,@r0
        mov.l   _slave_go,r0
        jmp     @r0
        nop

        .align   2

_slave_int_clr:
        .long   0x2000401E
_slave_frtctl:
        .long   0xFFFFFE10
_slave_stk:
        .long   slave_stack
_slave_sts:
        .long   0x20004024              /* COMM4 */
_slave_ok:
        .long   0x535F                  /* 'S_' token (16-bit) */
_slave_adapter:
        .long   0x20004000
_slave_cctl:
        .long   0xFFFFFE92
_slave_go:
        .long   _slave

!-----------------------------------------------------------------------
! Slave exception handler
!-----------------------------------------------------------------------

slave_err:
        rte
        nop

!-----------------------------------------------------------------------
! Slave Level 1 IRQ handler (FRT)
!-----------------------------------------------------------------------

slave_lvl1:
        rte
        nop

!-----------------------------------------------------------------------
! Slave Level 2/3 IRQ handler (WDT)
!-----------------------------------------------------------------------

slave_lvl2_3:
        rte
        nop

!-----------------------------------------------------------------------
! Slave Level 4/5 IRQ handler (DMA)
!-----------------------------------------------------------------------

slave_lvl4_5:
        rte
        nop

!-----------------------------------------------------------------------
! Slave V Blank IRQ handler
!-----------------------------------------------------------------------

slave_vbi:
        mov.l   r0,@-r15
        mov.l   r1,@-r15

        mov.l   svi_mars_adapter,r1
        mov.w   r0,@(0x16,r1)           /* clear V IRQ */
        nop
        nop
        nop
        nop

        ! handle V IRQ

        mov.l   @r15+,r1
        mov.l   @r15+,r0
        rte
        nop

        .align  2

svi_mars_adapter:
        .long   0x20004000

!-----------------------------------------------------------------------
! Slave H Blank IRQ handler
!-----------------------------------------------------------------------

slave_hbi:
        mov.l   r0,@-r15
        mov.l   r1,@-r15

        mov.l   shi_mars_adapter,r1
        mov.w   r0,@(0x18,r1)           /* clear H IRQ */
        nop
        nop
        nop
        nop

        ! handle H IRQ

        mov.l   @r15+,r1
        mov.l   @r15+,r0
        rte
        nop

        .align  2

shi_mars_adapter:
        .long   0x20004000

!-----------------------------------------------------------------------
! Slave Command IRQ handler
!-----------------------------------------------------------------------

slave_cmd:
        mov.l   r0,@-r15
        mov.l   r1,@-r15

        mov.l   sci_mars_adapter,r1
        mov.w   r0,@(0x1A,r1)           /* clear CMD IRQ */
        nop
        nop
        nop
        nop

        ! Set slave wakeup flag — checked by slave main loop
        ! this after waking from SLEEP to know CMD fired.
        mov.l   sci_wakeup_flag,r1
        mov     #1,r0
        mov.b   r0,@r1

        mov.l   @r15+,r1
        mov.l   @r15+,r0
        rte
        nop

        .align  2

sci_mars_adapter:
        .long   0x20004000

sci_wakeup_flag:
        .long   _slave_cmd_wakeup + 0x20000000  /* uncached alias */

!-----------------------------------------------------------------------
! Slave PWM IRQ handler
!-----------------------------------------------------------------------

slave_pwm:
        mov.l   r0,@-r15
        mov.l   r1,@-r15

        mov.l   spi_mars_adapter,r1
        mov.w   r0,@(0x1C,r1)           /* clear PWM IRQ */
        nop
        nop
        nop
        nop

        ! handle PWM IRQ

        mov.l   @r15+,r1
        mov.l   @r15+,r0
        rte
        nop

        .align  2

spi_mars_adapter:
        .long   0x20004000

!-----------------------------------------------------------------------
! Slave RESET IRQ handler
!-----------------------------------------------------------------------

slave_rst:
        mov.l   svri_mars_adapter,r1
        mov.w   r0,@(0x14,r1)           /* clear VRES IRQ */
        nop
        nop
        nop
        nop

        mov     #0x0F,r0
        shll2   r0
        shll2   r0
        ldc     r0,sr                   /* disallow ints */

        mov.l   svri_slave_stk,r15
        mov.l   svri_slave_vres,r0
        jmp     @r0
        nop

        .align  2

svri_mars_adapter:
        .long   0x20004000
svri_slave_stk:
        .long   slave_stack
svri_slave_vres:
        .long   slave_reset

!-----------------------------------------------------------------------
! Master/Slave RESET handlers
!-----------------------------------------------------------------------

master_reset:
        ! wait for slave to signal reset
        mov.l   _rst_slave_st,r0
        mov.l   _rst_slave_ok,r1
0:
        mov.w   @r0,r2
        nop
        nop
        extu.w  r2,r2
        cmp/eq  r1,r2
        bf      0b                      /* wait for slave */

        ! recopy ROM .data to SDRAM
        mov.l   _rst_rom_header,r1
        mov.l   @r1,r2                  /* src relative to start of ROM */
        mov.l   @(4,r1),r3              /* dst relative to start of SDRAM */
        mov.l   @(8,r1),r4              /* size (longword aligned) */
        mov.l   _rst_rom_start,r1
        add     r1,r2
        mov.l   _rst_sdram_start,r1
        add     r1,r3
        shlr2   r4                      /* number of longs */
        add     #-1,r4
1:
        mov.l   @r2+,r0
        mov.l   r0,@r3
        add     #4,r3
        dt      r4
        bf      1b

        mov.l   _rst_master_st,r0
        mov.l   _rst_master_ok,r1
        mov.w   r1,@r0                  /* tell everyone reset complete */

        mov.l   _rst_master_go,r0
        jmp     @r0
        nop

slave_reset:
        ! tell master to start reset
        mov.l   _rst_slave_st,r0
        mov.l   _rst_slave_ok,r1
        mov.w   r1,@r0

        ! wait for master
        mov.l   _rst_master_st,r0
        mov.l   _rst_master_ok,r1
0:
        mov.w   @r0,r2
        nop
        nop
        extu.w  r2,r2
        cmp/eq  r1,r2
        bf      0b

        mov.l   _rst_slave_go,r0
        jmp     @r0
        nop

        .align  2

_rst_master_st:
        .long   0x20004020
_rst_master_ok:
        .long   0x4D5F                  /* 'M_' token (16-bit) */
_rst_master_go:
        .long   master_start
_rst_rom_header:
        .long   0x220003D4              /* Mars header in ROM (SH-2 address) */
_rst_rom_start:
        .long   0x22000000
_rst_sdram_start:
        .long   0x26000000

_rst_slave_st:
        .long   0x20004024
_rst_slave_ok:
        .long   0x535F                  /* 'S_' token (16-bit) */
_rst_slave_go:
        .long   slave_start

!-----------------------------------------------------------------------
! Support Functions
!-----------------------------------------------------------------------

! void fast_memcpy(int *dst, int *src, int len);
! Fast memcpy function - copies longs, runs from SDRAM for speed
! On entry: r4 = dst, r5 = src, r6 = len (in longs)

        .align  4

        .global _fast_memcpy
_fast_memcpy:
        mov.l   @r5+,r3
        mov.l   r3,@r4
        dt      r6
        bf/s    _fast_memcpy
        add     #4,r4
        rts
        nop

! void CacheClearLine(void *ptr);
! Cache clear line function
! On entry: r4 = ptr - should be 16 byte aligned

        .align  4

        .global _CacheClearLine
_CacheClearLine:
        mov.l   _cache_flush,r0
        or      r0,r4
        mov     #0,r0
        mov.l   r0,@r4
        rts
        nop

        .align  2

_cache_flush:
        .long   0x40000000

! void CacheControl(int mode);
! Cache control function
! On entry: r4 = cache mode => 0x10 = CP, 0x08 = TW, 0x01 = CE

        .align  4

        .global _CacheControl
_CacheControl:
        mov.l   _sh2_cctl,r0
        mov.b   r4,@r0
        rts
        nop

        .align  2

_sh2_cctl:
        .long   0xFFFFFE92

! int SetSH2SR(int level);
! On entry: r4 = new irq level
! On exit:  r0 = old irq level
        .align  4

        .global _SetSH2SR
_SetSH2SR:
        stc     sr,r1
        mov     #0x0F,r0
        shll2   r0
        shll2   r0
        and     r0,r1                   /* just the irq mask */
        shlr2   r1
        shlr2   r1
        not     r0,r0
        stc     sr,r2
        and     r0,r2
        shll2   r4
        shll2   r4
        or      r4,r2
        ldc     r2,sr
        rts
        mov     r1,r0

!-----------------------------------------------------------------------
! Suppress linker warning about missing _start
!-----------------------------------------------------------------------

        .global _start
_start:
