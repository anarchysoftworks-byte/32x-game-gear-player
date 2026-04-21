/*
 * gg_mem.c — GG memory subsystem for 32X
 *
 * Manages the 64 KB Z80 address space via an 8-page table (8 KB each).
 * ROM pages point into SDRAM shadow buffers for faster SH-2 access
 * (cart ROM at 0x02xxxxxx goes through the slower adapter bus).
 * RAM pages point into SDRAM arrays.
 *
 * Ported from MEKA mappers.cpp (Mem_Pages[], Map_8k_ROM, etc.)
 */

#include "gg_emu.h"
#include "gg_vdp.h"
#include "32x.h"

/* Memory access strategy for Z80 address space.
 *
 * CRITICAL PERFORMANCE FIX: Mem_Pages uses CACHED SDRAM (0x06xxxxxx).
 *
 * The old design used uncached aliases (0x26xxxxxx) to "avoid polluting
 * the 4 KB unified I+D cache with ROM/RAM data."  This was catastrophic:
 * every Z80 opcode fetch hit raw SDRAM (~8-12 cycles per byte with bus
 * contention from the slave renderer), totaling ~160K+ wasted cycles
 * per frame — enough to blow the entire 383K cycle budget.
 *
 * With cached access, sequential Z80 fetches benefit from 16-byte
 * cache line fills (~1 cycle per byte amortized).  The Z80 hot code
 * path touches ~1-2 KB of ROM per frame, and the interpreter is ~3 KB;
 * both fit in the 4-way set-associative 4 KB cache with room to spare.
 *
 * SH-2 write-through cache ensures coherency: cached RAM writes
 * propagate to SDRAM immediately, so the slave (which purges its
 * cache at frame start) always sees current data. */
#define MEM_CACHED(p)   ((uint8_t *)(p))

/* Keep uncached alias available for explicit use (e.g., shared memory) */
#define MEM_UNCACHED(p) ((uint8_t *)((uint32_t)(p) | 0x20000000))

/* Bare-metal: no libc, inline memset */
static void mem_clear(void *dst, int val, unsigned int n)
{
    uint8_t *d = (uint8_t *)dst;
    while (n--) *d++ = (uint8_t)val;
}

/* ------------------------------------------------------------------ */
/* Fast longword copy (src and dst must be 4-byte aligned)             */
/* ------------------------------------------------------------------ */

static void mem_copy_fast(void *dst, const void *src, unsigned int n)
{
    uint32_t *d = (uint32_t *)dst;
    const uint32_t *s = (const uint32_t *)src;
    unsigned int words = n >> 2;
    while (words--) *d++ = *s++;
}

/* ------------------------------------------------------------------ */
/* Memory arrays — placed in SDRAM via default .bss                    */
/* ------------------------------------------------------------------ */

uint8_t  gg_ram[GG_RAM_SIZE];         /* 8 KB Z80 work RAM */
uint8_t  gg_vram[GG_VRAM_SIZE];       /* 16 KB video RAM */
uint8_t  gg_cram[GG_CRAM_SIZE];       /* 32 bytes color RAM */
uint8_t  gg_sram[GG_SRAM_SIZE];       /* 32 KB battery-backed SRAM */
uint16_t gg_palette_32x[32];           /* precomputed 15-bit palette */

/* ROM shadow buffers in SDRAM — three 16 KB slots for the three
   bankable ROM windows (slots 0, 1, 2).  ROM data is copied here
   on bank switch and Mem_Pages[] points into these instead of
   cart ROM space.  This eliminates adapter bus wait states. */
static uint8_t rom_shadow[3][0x4000] __attribute__((aligned(16)));

/* Track which 16K ROM page is currently shadowed in each slot,
   so we skip re-copying if the bank hasn't changed. */
static int rom_shadow_page[3] = { -1, -1, -1 };

/* Page table: 8 pointers, each covering 8 KB */
uint8_t *Mem_Pages[GG_PAGE_COUNT];

/* Global emulator state */
z80_t     z80;
gg_t     gg;
tgg_t    tgg;
machine_t g_machine;

/* Internal: base pointer for the embedded ROM in cart space */
static const uint8_t *rom_base_ptr;
static uint32_t       rom_total_size;

/* ------------------------------------------------------------------ */
/* Page mapping helpers                                                */
/*                                                                     */
/* ROM pages are shadowed into SDRAM for faster access.  The shadow    */
/* copy is skipped if the same ROM page is already loaded.             */
/* ------------------------------------------------------------------ */

void gg_map_8k_rom(int page, int rom_page)
{
    rom_page &= tgg.Pages_Mask_8k;
    /* 8K ROM mapping: point into the appropriate shadow slot.
       The slot is determined by which pair of pages (0-1, 2-3, 4-5). */
    int slot = page >> 1;   /* 0, 1, or 2 */
    int half = page & 1;    /* 0 = first 8K, 1 = second 8K */

    /* Determine if we need to copy this 8K chunk.
       Since 8K mappings are less common, always copy. */
    const uint8_t *src = rom_base_ptr + (rom_page * GG_PAGE_SIZE);
    uint8_t *dst = rom_shadow[slot] + (half * GG_PAGE_SIZE);
    mem_copy_fast(dst, src, GG_PAGE_SIZE);
    Mem_Pages[page] = MEM_CACHED(dst);

    /* Invalidate the slot's cached 16K page since we did a partial update */
    rom_shadow_page[slot] = -1;
}

void gg_map_16k_rom(int page, int rom_page)
{
    rom_page &= tgg.Pages_Mask_16k;
    int slot = page >> 1;   /* 0, 1, or 2 */

    /* Skip copy if this exact 16K ROM page is already shadowed */
    if (rom_shadow_page[slot] != rom_page)
    {
        const uint8_t *src = rom_base_ptr + (rom_page * GG_PAGE_SIZE * 2);
        mem_copy_fast(rom_shadow[slot], src, GG_PAGE_SIZE * 2);
        rom_shadow_page[slot] = rom_page;
    }

    Mem_Pages[page]     = MEM_CACHED(rom_shadow[slot]);
    Mem_Pages[page + 1] = MEM_CACHED(rom_shadow[slot] + GG_PAGE_SIZE);
}

void gg_map_8k_ram(int page)
{
    Mem_Pages[page] = MEM_CACHED(gg_ram);
}

void gg_map_8k_sram(int page, int sram_page)
{
    Mem_Pages[page] = MEM_CACHED(gg_sram + (sram_page * GG_PAGE_SIZE));
}

/* ------------------------------------------------------------------ */
/* Initialization                                                      */
/* ------------------------------------------------------------------ */

void gg_mem_init(const uint8_t *rom_base, uint32_t rom_size)
{
    rom_base_ptr  = rom_base;
    rom_total_size = rom_size;

    /* Compute page counts and masks */
    tgg.Size_ROM       = rom_size;
    tgg.Pages_Count_8k  = rom_size / GG_PAGE_SIZE;
    tgg.Pages_Count_16k = rom_size / (GG_PAGE_SIZE * 2);
    if (tgg.Pages_Count_8k  < 1) tgg.Pages_Count_8k  = 1;
    if (tgg.Pages_Count_16k < 1) tgg.Pages_Count_16k = 1;
    tgg.Pages_Mask_8k   = tgg.Pages_Count_8k  - 1;
    tgg.Pages_Mask_16k  = tgg.Pages_Count_16k - 1;

    /* Clear RAM */
    mem_clear(gg_ram,  0, GG_RAM_SIZE);
    mem_clear(gg_vram, 0, GG_VRAM_SIZE);
    mem_clear(gg_cram, 0, GG_CRAM_SIZE);
    mem_clear(gg_sram, 0, GG_SRAM_SIZE);
    mem_clear(gg_palette_32x, 0, sizeof(gg_palette_32x));

    /* Default page mapping:
     * Pages 0-5: first 48 KB of ROM (3 × 16 KB banks)
     * Pages 6-7: RAM (mirrored) */
    gg_map_16k_rom(0, 0);   /* 0x0000-0x3FFF */
    gg_map_16k_rom(2, 1);   /* 0x4000-0x7FFF */
    gg_map_16k_rom(4, 2);   /* 0x8000-0xBFFF */
    Mem_Pages[6] = MEM_CACHED(gg_ram);  /* 0xC000-0xDFFF */
    Mem_Pages[7] = MEM_CACHED(gg_ram);  /* 0xE000-0xFFFF (mirror) */

    /* Init mapper state */
    g_machine.mapper = MAPPER_Standard;
    mem_clear(g_machine.mapper_regs, 0, sizeof(g_machine.mapper_regs));
    g_machine.mapper_regs_count = 4;
    /* Default mapper register values (post-BIOS) */
    g_machine.mapper_regs[0] = 0x00;   /* 0xFFFC: SRAM control */
    g_machine.mapper_regs[1] = 0x00;   /* 0xFFFD: bank 0 */
    g_machine.mapper_regs[2] = 0x01;   /* 0xFFFE: bank 1 */
    g_machine.mapper_regs[3] = 0x02;   /* 0xFFFF: bank 2 */

    /* Init TV timing */
    g_machine.TV_lines = GG_LINES_NTSC;
}

/* ------------------------------------------------------------------ */
/* Z80 memory read                                                     */
/* ------------------------------------------------------------------ */

uint8_t gg_read(uint16_t addr)
{
    int page = addr >> 13;              /* 0-7 */
    int offset = addr & 0x1FFF;         /* 0x0000 - 0x1FFF */
    return Mem_Pages[page][offset];
}

/* ------------------------------------------------------------------ */
/* Z80 memory write                                                    */
/*                                                                     */
/* RAM is at pages 6-7 (0xC000-0xFFFF).  Writes to ROM pages are       */
/* silently discarded EXCEPT for mapper register writes at             */
/* 0xFFFC-0xFFFF which are intercepted.                                */
/* ------------------------------------------------------------------ */

/* Moved to ROM (.text) — SDRAM cache conflict with Z80 interpreter */
void gg_write(uint16_t addr, uint8_t val)
{
    /* Write through CACHED alias.  SH-2 write-through cache updates
     * both the cache line and SDRAM atomically, so subsequent cached
     * reads (through Mem_Pages) see the new value immediately.
     * The slave SH-2 does sh2_cache_purge() at frame start to see
     * master writes to shared data (VRAM/CRAM). */

    /* Mapper register intercept (standard GG mapper) */
    if (addr >= 0xFFFC) {
        /* Store value in RAM first (games can read these back) */
        gg_ram[addr & 0x1FFF] = val;
        gg_mapper_write(addr, val);
        return;
    }

    /* Only allow writes to RAM range (0xC000-0xFFFF) */
    if (addr >= 0xC000) {
        gg_ram[addr & 0x1FFF] = val;
        return;
    }

    /* Writes to ROM space are ignored in GG-only mode. */
}
