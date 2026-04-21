/*
 * gg_emu.h — Game Gear emulator core data structures
 *
 * Ported from MEKA (GG_TYPE, TGG_TYPE, t_machine, etc.) for
 * bare-metal SH-2 execution on the Sega 32X.
 *
 * SH-2 is big-endian.  The Z80 register pair union is ordered {h, l}
 * so that the .W member stores the 16-bit value in native byte order.
 */

#ifndef GG_EMU_H
#define GG_EMU_H

#include <stdint.h>

/* ------------------------------------------------------------------ */
/* Emulator mode                                                        */
/* ------------------------------------------------------------------ */

#define EMU_MODE_GG     1

/* ------------------------------------------------------------------ */
/* Mode-dependent display configuration                                */
/* ------------------------------------------------------------------ */

typedef struct {
    int32_t  mode;
    int32_t  x_res;             /* active display width (GG=160) */
    int32_t  y_res;             /* active display height (GG=144) */
    int32_t  x_start;           /* VDP tile X start for viewport (GG=48) */
    int32_t  y_start;           /* VDP scanline Y start (GG=24) */
    int32_t  fb_x_offset;       /* framebuffer pixel X offset (GG=80) */
    int32_t  fb_y_offset;       /* framebuffer line Y offset (GG=40) */
    int32_t  tile_start;        /* first tile column to render (GG=6) */
    int32_t  tile_end;          /* last+1 tile column to render (GG=26) */
    int32_t  cram_bytes;        /* CRAM size in bytes (GG=64) */
    int32_t  palette_12bit;     /* GG uses 12-bit palette */
    int32_t  sprite_clip_x_min; /* sprite X clip left (GG=48) */
    int32_t  sprite_clip_x_max; /* sprite X clip right (GG=208) */
} emu_config_t;

extern emu_config_t emu_config;

/* ------------------------------------------------------------------ */
/* Z80 register pair — big-endian layout for SH-2                     */
/* ------------------------------------------------------------------ */

typedef union {
    struct { uint8_t h, l; } B;   /* individual bytes (big-endian) */
    uint16_t W;                   /* full 16-bit value             */
} z80_pair_t;

/* ------------------------------------------------------------------ */
/* Z80 CPU state                                                      */
/* Ported from Marat Fayzullin's Z80 core (meka/srcs/z80marat/Z80.h)  */
/* ------------------------------------------------------------------ */

typedef struct {
    /* --- Cache line 1 (offset 0-15): hottest fields --- */
    /* PC + ICount are touched every z80_fetch iteration;
       AF, HL, BC, DE are used by most opcode implementations. */
    z80_pair_t PC;          /*  0: program counter */
    z80_pair_t AF;          /*  2: accumulator + flags */
    int32_t    ICount;      /*  4: cycles remaining (4-byte aligned) */
    z80_pair_t HL;          /*  8: HL pair (memory addressing) */
    z80_pair_t BC;          /* 10: BC pair */
    z80_pair_t DE;          /* 12: DE pair */
    uint8_t    IFF;         /* 14: interrupt flip-flops (see IFF_*) */
    uint8_t    R;           /* 15: refresh counter (low 7 bits) */

    /* --- Cache line 2 (offset 16-31): warm fields --- */
    z80_pair_t SP;          /* 16: stack pointer */
    z80_pair_t IX;          /* 18: index register X */
    z80_pair_t IY;          /* 20: index register Y */
    uint8_t    I;           /* 22: interrupt vector base */
    uint8_t    R7;          /* 23: bit 7 of R (preserved separately) */
    int32_t    IBackup;     /* 24: saved ICount (EI/DI) */
    int32_t    IPeriod;     /* 28: cycles per time-slice */

    /* --- Cache line 3 (offset 32-43): cold fields --- */
    z80_pair_t AF1, BC1, DE1, HL1;  /* 32: shadow register set */
    uint16_t   IRequest;    /* 40: pending IRQ vector (0xFFFF = none) */
    uint8_t    IAutoReset;  /* 42: auto-clear IRequest after delivery */
    uint8_t    TrapBadOps;  /* 43: warn on illegal opcodes */
    int32_t    page_start;  /* 44: pc_page_start for asm fetch loop */
} z80_t;

/* Bits in IFF field */
#define IFF_1       0x01    /* IFF1 flip-flop */
#define IFF_IM1     0x02    /* 1: IM1 mode */
#define IFF_IM2     0x04    /* 1: IM2 mode */
#define IFF_2       0x08    /* IFF2 flip-flop */
#define IFF_EI      0x20    /* 1: EI pending */
#define IFF_HALT    0x80    /* 1: CPU HALTed */

/* Interrupt vector constants */
#define Z80_INT_NONE    0xFFFF
#define Z80_INT_IRQ     0x0038
#define Z80_INT_NMI     0xFFFD

/* ------------------------------------------------------------------ */
/* GG hardware state                                                  */
/* Ported from MEKA GG_TYPE (meka/srcs/meka.h)                       */
/* ------------------------------------------------------------------ */

typedef struct {
    /* VDP registers and state */
    uint8_t  VDP[16];             /* VDP register file */
    uint8_t  VDP_Status;          /* VDP status byte */
    uint16_t VDP_Address;         /* current VRAM address */
    uint8_t  VDP_Access_Mode;     /* 0 = first byte, 1 = second byte */
    uint8_t  VDP_Access_First;    /* latched first byte of address write */
    uint8_t  VDP_ReadLatch;       /* read-ahead buffer */
    uint8_t  VDP_Pal;             /* non-zero when writing CRAM */

    /* Interrupt latches */
    int16_t  Lines_Left;          /* H-blank line counter */
    uint8_t  Pending_HBlank;      /* H-blank interrupt pending */
    uint8_t  Pending_NMI;         /* NMI pending (pause button) */

    /* Hardware */
    uint8_t  Country;             /* 0 = export, 1 = Japan */
    uint8_t  SRAM_Mapping_Register;

    /* Game Gear specific */
    uint8_t  GG_Control;          /* port 0x00: bit7=Start, bit6=region */
    uint8_t  GG_Stereo;           /* port 0x06: stereo panning register */

    /* Input */
    uint8_t  FM_Magic;            /* FM detection latch */
    uint8_t  FM_Register;         /* FM register select */
    uint8_t  Input_Mode;          /* keyboard/joypad select */
    uint8_t  Port3F;              /* nationalization port shadow */
} gg_t;

/* ------------------------------------------------------------------ */
/* Runtime / transient state                                           */
/* Ported from MEKA TGG_TYPE                                         */
/* ------------------------------------------------------------------ */

typedef struct {
    int32_t  VDP_Line;            /* current scanline (0 – TV_lines-1) */
    int32_t  VDP_VideoMode;       /* active video mode */
    int32_t  VDP_New_VideoMode;   /* pending mode after register change */
    int32_t  VDP_Video_Change;    /* flag: mode changed this frame */

    /* ROM geometry (computed at init) */
    int32_t  Pages_Mask_8k;       /* (rom_size / 8192) - 1 */
    int32_t  Pages_Mask_16k;      /* (rom_size / 16384) - 1 */
    int32_t  Pages_Count_8k;      /* rom_size / 8192 */
    int32_t  Pages_Count_16k;     /* rom_size / 16384 */
    uint32_t Size_ROM;            /* total ROM size in bytes */

    /* Controller state (directly from COMM8) */
    uint16_t Pad;                 /* 32X pad word (active-high) */
    uint8_t  Pause_Pressed;       /* Start->NMI latch */
    uint8_t  _pad;
} tgg_t;

/* ------------------------------------------------------------------ */
/* VDP derived pointers (recomputed on VDP register writes)            */
/* Ported from MEKA t_machine_vdp_smsgg                               */
/* ------------------------------------------------------------------ */

typedef struct {
    uint8_t *name_table_address;        /* pointer into gg_vram[] */
    uint8_t *sprite_attribute_table;    /* pointer into gg_vram[] */
    uint8_t *sprite_pattern_gen_address;
    int32_t  sprite_pattern_gen_index;  /* 0 or 256 */
    int32_t  sprite_shift_x;            /* 0 or 8 */
    uint8_t  scroll_x_latched;
    uint8_t  scroll_y_latched;
    uint8_t  _pad[2];
} machine_vdp_t;

/* ------------------------------------------------------------------ */
/* Machine configuration                                              */
/* ------------------------------------------------------------------ */

#define MAPPER_REGS_MAX     6

/* Mapper types for Game Gear ROM banking */
#define MAPPER_Standard     0   /* Sega standard (0xFFFC-0xFFFF) */
#define MAPPER_NoMapper     1   /* ROM ≤ 48 KB, no banking */

typedef struct {
    int32_t  mapper;
    uint8_t  mapper_regs[MAPPER_REGS_MAX];
    int32_t  mapper_regs_count;
    int32_t  TV_lines;            /* 262 (NTSC) or 313 (PAL) */

    machine_vdp_t VDP;
} machine_t;

/* ------------------------------------------------------------------ */
/* Memory page table                                                   */
/*                                                                     */
/* 64 KB Z80 address space split into 8 × 8 KB pages.                 */
/* Each pointer targets either ROM (in cart space) or RAM (in SDRAM).  */
/* ------------------------------------------------------------------ */

#define GG_PAGE_COUNT      8
#define GG_PAGE_SIZE       0x2000   /* 8 KB */

extern uint8_t *Mem_Pages[GG_PAGE_COUNT];

/* ------------------------------------------------------------------ */
/* GG memory arrays (allocated in SDRAM)                              */
/* ------------------------------------------------------------------ */

#define GG_RAM_SIZE        0x2000   /* 8 KB */
#define GG_VRAM_SIZE       0x4000   /* 16 KB */
#define GG_CRAM_SIZE       64       /* 64 bytes (GG needs 2 bytes × 32 colors) */
#define GG_SRAM_SIZE       0x8000   /* 32 KB max SRAM */

extern uint8_t  gg_ram[];
extern uint8_t  gg_vram[];
extern uint8_t  gg_cram[];
extern uint8_t  gg_sram[];

/* Precomputed 15-bit palette for 32X framebuffer (updated on CRAM write) */
extern uint16_t gg_palette_32x[];

/* ------------------------------------------------------------------ */
/* Global emulator state instances                                     */
/* ------------------------------------------------------------------ */

extern z80_t     z80;
extern gg_t     gg;
extern tgg_t    tgg;
extern machine_t g_machine;

/* ------------------------------------------------------------------ */
/* ROM pointers (set by crt0, point into cart ROM space at 0x02xxxxxx) */
/* ------------------------------------------------------------------ */

extern const uint8_t  rom_data[];       /* defined in crt0_cart.s */
extern const uint32_t rom_size;         /* defined in crt0_cart.s */

/* ------------------------------------------------------------------ */
/* GG timing constants                                                */
/* ------------------------------------------------------------------ */

#define GG_CPU_CLOCK       3579545     /* Z80 clock: 3.579545 MHz */
#define GG_LINES_NTSC      262
#define GG_LINES_PAL       313
#define GG_CYCLES_PER_LINE 228         /* ~3579545 / 262 / 59.92 */
#define GG_VISIBLE_LINES   192
#define GG_VBLANK_LINE     192

/* ------------------------------------------------------------------ */
/* Function declarations — implemented across gg_*.c modules          */
/* ------------------------------------------------------------------ */

/* gg_mem.c */
void    gg_mem_init(const uint8_t *rom_base, uint32_t rom_size);
uint8_t gg_read(uint16_t addr);
void    gg_write(uint16_t addr, uint8_t val);
void    gg_map_8k_rom(int page, int rom_page);
void    gg_map_16k_rom(int page, int rom_page);
void    gg_map_8k_ram(int page);
void    gg_map_8k_sram(int page, int sram_page);

/* ------------------------------------------------------------------ */
/* Inline memory access — used by Z80 core and VDP hot paths           */
/* Eliminates function call overhead (~10 SH-2 cycles per call).       */
/* ------------------------------------------------------------------ */

/* Forward declarations needed by inline functions below */
void    gg_mapper_write(uint16_t addr, uint8_t val);

static inline uint8_t gg_read_inline(uint16_t addr)
{
    return Mem_Pages[addr >> 13][addr & 0x1FFF];
}

#define GG_READ(addr) gg_read_inline((uint16_t)(addr))

/* Fast RAM write: only writes to 0xC000-0xFFFF (pages 6-7).
   Mapper register intercepts (0xFFFC-0xFFFF) use the slow path. */
static inline void gg_write_inline(uint16_t addr, uint8_t val)
{
    if (addr >= 0xC000) {
        /* Write through cached alias — SH-2 write-through cache
         * updates both cache line and SDRAM atomically */
        gg_ram[addr & 0x1FFF] = val;
        if (addr >= 0xFFFC)
            gg_mapper_write(addr, val);
        return;
    }
    /* ROM writes: only CodeMasters mapper intercepts */
    gg_write(addr, val);
}

/* gg_io.c */
uint8_t gg_in(uint16_t port);
void    gg_out(uint16_t port, uint8_t val);
void    gg_input_update(void);

/* gg_vdp.c */
void    gg_vdp_init(void);
void    gg_vdp_data_write(uint8_t val);
void    gg_vdp_addr_write(uint8_t val);
uint8_t gg_vdp_data_read(void);
uint8_t gg_vdp_status_read(void);
void    gg_vdp_reg_write(uint8_t reg, uint8_t val);
void    gg_vdp_update_addresses(void);

/* gg_render.c */
void    gg_render_init(void);
void    gg_render_line(int line, uint8_t cmd_flags);
void    gg_tile_dirty(uint16_t vram_addr);

/* gg_mapper.c */
void    gg_mapper_init(const uint8_t *rom_base, uint32_t rom_size);
void    gg_mapper_write(uint16_t addr, uint8_t val);

/* gg_psg.c — PSG dispatcher + slave SH-2 main loop */
void    gg_psg_init(void);
void    gg_psg_write(uint8_t val);

/* gg_psg_relay.c — GG COMM4 hardware relay */
void    gg_psg_relay_write(uint8_t val);

/* z80.h */
void    z80_reset(z80_t *cpu);
void    z80_run(z80_t *cpu, int cycles);
void    z80_run_frame(z80_t *cpu, int cycles_per_line, int (*callback)(z80_t *));
void    z80_set_irq(z80_t *cpu, uint16_t vector);
void    z80_nmi(z80_t *cpu);
void    z80_exec_opcode(z80_t *cpu, uint8_t opcode);

/* z80 tables (defined in z80_dispatch.c, referenced by z80_asm.s) */
extern const uint8_t  Cycles[256];
extern const uint8_t  CyclesCB[256];
extern const uint8_t  CyclesED[256];
extern const uint8_t  CyclesXX[256];
extern const uint8_t  CyclesXXCB[256];
extern const uint8_t  ZSTable[256];
extern const uint8_t  PZSTable[256];

#endif /* GG_EMU_H */
