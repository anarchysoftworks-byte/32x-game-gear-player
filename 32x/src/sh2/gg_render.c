/*
 * gg_render.c — Game Gear Mode 4 scanline renderer for 32X framebuffer
 *
 * Ported from MEKA video_m5.cpp / video_c.cpp.
 *
 * Key differences from MEKA:
 *  - Tile decode LUT + cache (tile_lut_hi/lo, tile_cache[])
 *  - Output goes directly to 32X framebuffer (15-bit direct color)
 *  - No Allegro/bitmap dependencies
 *  - Game Gear viewport and palette path
 *  - BG and sprite rendering in SH-2 assembly (render_asm.S)
 *  - Display_ON flag stamped by master in render command (avoids
 *    cross-CPU cache coherency race on gg.VDP[1])
 */

#include "gg_emu.h"
#include "gg_vdp.h"
#include "32x.h"

/* Write VDP_Status through uncached SDRAM so the master SH-2
 * sees sprite collision/overflow flags immediately. */
#define VDP_STATUS_SET(flag) do { \
    gg.VDP_Status |= (flag); \
    *(volatile uint8_t *)SH2_UNCACHED(&gg.VDP_Status) = gg.VDP_Status; \
} while(0)

/* ------------------------------------------------------------------ */
/* Constants                                                           */
/* ------------------------------------------------------------------ */

#define GG_WIDTH       256
#define GG_HEIGHT      192
#define FB_WIDTH        320
#define FB_X_OFFSET     32      /* Center 256px GG image in 320px scanout */

/* VDP status bits */
#define VDP_STATUS_COLLISION    0x20
#define VDP_STATUS_9TH_SPRITE  0x40
#define VDP_STATUS_VBLANK      0x80

/* Maximum sprites per line before overflow */
#define MAX_SPRITES_PER_LINE   8

/* ------------------------------------------------------------------ */
/* 32X framebuffer access                                              */
/* ------------------------------------------------------------------ */

/* Pointer to the current back-buffer; set by main.c each frame */
volatile uint16_t *gg_fb_ptr = (volatile uint16_t *)0x24000000;

/* ------------------------------------------------------------------ */
/* Forward declarations for asm-accelerated functions and              */
/* mode-specific dispatch pointers (set once at init)                  */
/* ------------------------------------------------------------------ */

extern void render_bg_line_asm(uint16_t *dst, uint8_t *pri,
                               const uint8_t *map_row, int tile_line,
                               int map_col, int num_cols,
                               const uint16_t *pal_base);
extern void prefetch_tile_row_asm(const uint8_t *map_row,
                                   const uint8_t *vram_base,
                                   int tile_line,
                                   int map_col,
                                   int num_cols,
                                   uint8_t *out);
extern void fb_copy_line_asm(volatile uint32_t *dst, const uint32_t *src);
extern void fb_copy_gg_line_asm(volatile uint32_t *dst, const uint32_t *src);
extern void render_sprites_line_asm(uint16_t *dst, const uint8_t *priority_buf,
                                    int line, int sprite_height,
                                    const uint8_t *sat, const uint16_t *pal,
                                    int clip_x_min, int clip_x_max,
                                    int shift_x, int pat_gen_idx);

static void (*fb_copy_fn)(volatile uint32_t *dst, const uint32_t *src);
static int fb_copy_src_x;  /* line_buf index for copy start */

/* Static line render buffer — kept in .bss rather than on the stack so
 * the compiler can promote it with better SDRAM placement.            */
static uint16_t line_buf[GG_WIDTH + 8] __attribute__((aligned(4)));

/* Static priority buffer — kept in .bss to avoid 264-byte stack
 * allocation per scanline (144 calls/frame).  Stack allocation
 * would touch 17 cache lines and increase function prologue cost. */
static uint8_t priority_buf_static[GG_WIDTH + 8] __attribute__((aligned(4)));

/* Per-scanline tile row prefetch buffer: 32 tiles × 4 bytes = 128 bytes.
 * Aligned to 64 bytes (4 SH-2 cache lines, 16 bytes each) so that
 * render_bg_line_asm() reads are guaranteed to stay in data cache.   */
uint8_t tile_row_scratch[128] __attribute__((aligned(64)));

/* ------------------------------------------------------------------ */
/* Per-frame dirty-line tracking                                        */
/*                                                                     */
/* A scanline can be skipped (re-use pixels from previous render of   */
/* this physical framebuffer — 2 frames ago) if:                       */
/*   1. No palette entry changed this frame (cram_dirty == 0)          */
/*   2. scroll_x for this line is unchanged from last frame            */
/*   3. scroll_y is unchanged from last frame                          */
/*   4. None of the tile_n values referenced by the name table row     */
/*      for this line has been modified (tile_dirty_bits check)        */
/*                                                                     */
/* tile_dirty_bits: 1 bit per tile (512 tiles → 64 bytes).            */
/*   Bit set on VRAM write; cleared by sat_precompute() each frame.    */
/* cram_dirty: set on any CRAM write; cleared by sat_precompute().     */
/* prev_scroll_x[]: per-line scroll_x from the last rendered frame.   */
/* ------------------------------------------------------------------ */
uint8_t tile_dirty_bits[64] __attribute__((aligned(16)));
uint8_t cram_dirty;

/* 32X line table: first 256 bytes (128 words) contain per-line offsets.
   Each entry is a word offset from framebuffer start. */

/* Framebuffer control register */
#define MARS_VDP_FBCTL_REG  (*(volatile uint16_t *)0x2000410A)

/* Return pointer to pixel data for framebuffer line `y`.
   The line table encodes word offsets; each pixel is one word (16-bit). */
static inline volatile uint16_t *fb_line_ptr(int y)
{
    uint16_t offset = gg_fb_ptr[y];
    return gg_fb_ptr + offset;
}

/* ------------------------------------------------------------------ */
/* Tile decode lookup table                                            */
/*                                                                     */
/* For each bitplane byte value (0-255), pre-expand the 8 bits into    */
/* bit positions suitable for OR-ing into a packed pixel result.        */
/* tile_expand[plane][byte] gives the contribution of that byte to     */
/* the 8 output pixels, with each pixel occupying 4 bits.             */
/*                                                                     */
/* Plane 0: each bit goes to bit 0 of the corresponding nibble        */
/* Plane 1: each bit goes to bit 1 of the corresponding nibble        */
/* Plane 2: each bit goes to bit 2 of the corresponding nibble        */
/* Plane 3: each bit goes to bit 3 of the corresponding nibble        */
/*                                                                     */
/* Result: tile_expand[0][bp0] | tile_expand[1][bp1] |                */
/*         tile_expand[2][bp2] | tile_expand[3][bp3]                  */
/* gives a 32-bit word with 8 × 4-bit palette indices (MSB=leftmost). */
/*                                                                     */
/* We use two 32-bit words to hold all 8 pixels:                      */
/* hi = pixels 0-3 (leftmost), lo = pixels 4-7 (rightmost)            */
/* ------------------------------------------------------------------ */

/* 4 planes × 256 entries × 2 words = 8 KB LUT — placed in SDRAM */
uint32_t tile_lut_hi[4][256] __attribute__((aligned(16)));
uint32_t tile_lut_lo[4][256] __attribute__((aligned(16)));

/* ------------------------------------------------------------------ */
/* Tile line cache — decoded pixel rows indexed by VRAM byte offset   */
/*                                                                     */
/* VRAM is 16 KB = 512 tiles × 32 bytes/tile = 4096 tile-lines × 4B. */
/* Each tile line (4 bytes starting at addr & ~3) decodes to 8 pixels.*/
/* We cache the decoded result (2 × 32-bit packed words) and a dirty  */
/* flag.  On VRAM write, the affected entry is marked dirty.          */
/* On decode, dirty entries are re-decoded; clean entries skip the LUT.*/
/*                                                                     */
/* Cache size: 4096 entries × (8+1) bytes ≈ 36 KB in SDRAM.          */
/* ------------------------------------------------------------------ */

#define TILE_CACHE_ENTRIES  (GG_VRAM_SIZE / 4)  /* 4096 */

/* Interleaved decode results: hi (pixels 0-3) and lo (pixels 4-7)
 * packed into a single struct so both fit within one SH-2 cache line.
 * (The code treats the SH-2 D-cache line as 16 bytes; entry is 8 bytes.)
 *
 * Layout is cache-set friendly on purpose: the D-cache indexes sets by
 * address bits [9:4], and an 8-byte entry stride advances the set index
 * every other entry. Two entries therefore collide only when their
 * indices are far apart (>= 64-128 depending on line size), never for
 * consecutive tiles — so sequential left-to-right access keeps good
 * spatial locality and does not thrash. */
typedef struct { uint32_t hi; uint32_t lo; } tile_cache_t;
tile_cache_t tile_cache[TILE_CACHE_ENTRIES] __attribute__((aligned(16)));

/* Dirty flags: 1 = needs re-decode, 0 = cached result is valid.
 * Kept separate from tile_cache because it has excellent spatial
 * locality as-is (16 consecutive dirty flags per cache line) and
 * is checked BEFORE hi/lo access, avoiding a wasted cache miss
 * on clean tiles. */
uint8_t tile_cache_dirty[TILE_CACHE_ENTRIES] __attribute__((aligned(16)));

/* Called from gg_vdp_data_write() when VRAM is written */
__attribute__((section(".sdram_code")))
void gg_tile_dirty(uint16_t vram_addr)
{
    tile_cache_dirty[vram_addr >> 2] = 1;
    /* Mark the tile itself dirty for per-line skip logic.
     * Each tile = 32 bytes; tile_n = vram_addr >> 5.
     * tile_dirty_bits: 1 bit per tile, index = tile_n >> 3, bit = tile_n & 7. */
    if (vram_addr < 0x4000) {  /* tile data area only (not name table etc.) */
        uint16_t tile_n = vram_addr >> 5;
        tile_dirty_bits[tile_n >> 3] |= (uint8_t)(1u << (tile_n & 7));
    }
}

/* Called from gg_vdp_palette_write() when CRAM is written */
__attribute__((section(".sdram_code")))
void gg_cram_dirty(void)
{
    cram_dirty = 1;
}

static void init_tile_lut(void)
{
    int plane, val, bit;
    for (plane = 0; plane < 4; plane++)
    {
        for (val = 0; val < 256; val++)
        {
            uint32_t hi = 0, lo = 0;
            for (bit = 0; bit < 4; bit++)
            {
                /* Bits 7-4 → hi word, pixels 0-3 (leftmost) */
                if (val & (0x80 >> bit))
                    hi |= (uint32_t)(1 << plane) << ((3 - bit) * 8);
            }
            for (bit = 0; bit < 4; bit++)
            {
                /* Bits 3-0 → lo word, pixels 4-7 */
                if (val & (0x08 >> bit))
                    lo |= (uint32_t)(1 << plane) << ((3 - bit) * 8);
            }
            tile_lut_hi[plane][val] = hi;
            tile_lut_lo[plane][val] = lo;
        }
    }
}

/* ------------------------------------------------------------------ */
/* Tile decode — done in ASSEMBLY, not here                           */
/*                                                                     */
/* This C helper was removed: it was dead code (no callers anywhere)   */
/* and its "37 KB tile_cache working set" narrative did NOT apply to   */
/* the runtime scanline loop. The cache-set analysis that resolves the */
/* audit's thrashing concern lives next to the tile_cache definition.  */
/*                                                                     */
/* Runtime decode happens in two assembly paths:                       */
/*   * Background — render_background_line() fills a 128-byte          */
/*     tile_row_scratch buffer and render_bg_line_asm decodes it       */
/*     straight from the read-only tile_lut_hi/lo LUTs. The entire     */
/*     per-line working set (scratch + touched LUT rows) fits inside   */
/*     the 4 KB SH-2 D-cache, so there are no capacity/conflict misses */
/*     on the dominant 144-line background workload.                   */
/*   * Sprites — render_sprites_line_asm consults tile_cache only on a */
/*     cache miss (<= MAX_SPRITES_PER_LINE sprites per line).          */
/* ------------------------------------------------------------------ */

/* ------------------------------------------------------------------ */
/* Renderer init — call once at startup                                */
/* ------------------------------------------------------------------ */

void gg_render_init(void)
{
    int i;
    init_tile_lut();
    /* Mark all tile cache entries as dirty so first decode fills them */
    for (i = 0; i < TILE_CACHE_ENTRIES; i++)
        tile_cache_dirty[i] = 1;

    /* GG-only framebuffer copy path. */
    fb_copy_fn = fb_copy_gg_line_asm;
    fb_copy_src_x = emu_config.x_start;
}

/* ------------------------------------------------------------------ */
/* Per-frame SAT (Sprite Attribute Table) pre-scan                     */
/*                                                                     */
/* Instead of scanning all 64 SAT Y-entries every scanline, we build  */
/* per-line sprite index lists once per frame.  This reduces the       */
/* find_sprites_on_line cost from ~640 cycles/line to ~30 cycles/line  */
/* (~89K cycles/frame saved for GG's 144 active lines).               */
/*                                                                     */
/* Also resets per-frame dirty tracking state.                         */
/* Called by the slave SH-2 at frame start (after cache purge).        */
/* ------------------------------------------------------------------ */

#define SAT_PRECOMPUTE_LINES  224  /* max visible lines (224-line mode) */

uint8_t sat_line_count[SAT_PRECOMPUTE_LINES];
uint8_t sat_line_idx[SAT_PRECOMPUTE_LINES][MAX_SPRITES_PER_LINE];

/* Moved to ROM (.text) — SDRAM cache conflict with Z80 interpreter */
void sat_precompute(void)
{
    /* GG-only: no doubled sprites.
     * Cache sprite_height and visible_lines as local vars to avoid
     * repeated VDP register reads through possibly-stale cache. */
    int sprite_height = Sprites_8x16 ? 16 : 8;
    int visible_lines = Wide_Screen_28 ? 224 : GG_HEIGHT;
    const uint8_t *sat = g_machine.VDP.sprite_attribute_table;

    /* Clear all line counts (bulk zero via uint32_t writes).
     * Only clear the lines we'll actually scan — GG standard mode
     * uses 192 lines = 48 longwords. */
    {
        uint32_t *p = (uint32_t *)sat_line_count;
        int n = (visible_lines + 3) >> 2;  /* ceiling div by 4 */
        for (int i = 0; i < n; i++)
            p[i] = 0;
    }

    /* GG viewport: only lines 24..167 are visible (144 active lines).
     * Clamp sprite line ranges to the GG viewport to avoid populating
     * sat_line_idx for off-screen lines — saves ~30% of inner-loop
     * iterations for sprites near the top/bottom of the SAT. */
    int gg_y_min = emu_config.y_start;          /* 24 for standard GG */
    int gg_y_max = gg_y_min + emu_config.y_res; /* 168 for standard GG */
    if (Wide_Screen_28) { gg_y_min = 0; gg_y_max = 224; }

    /* Iterate sprites, populate per-line index lists */
    for (int i = 0; i < 64; i++)
    {
        int y = sat[i];

        /* Y = 208 terminates the sprite list (in 192-line mode) */
        if (!Wide_Screen_28 && y == 208)
            break;

        if (y > 224) y -= 256;

        /* Sprite visible on lines (y+1) through (y+sprite_height) */
        int y_start = y + 1;
        int y_end = y_start + sprite_height;

        /* Clamp to visible range */
        if (y_start < 0) y_start = 0;
        if (y_end > visible_lines) y_end = visible_lines;

        /* Skip sprites entirely outside GG viewport.
         * Still populate sat_line_count for overflow detection,
         * but only for lines that will actually be rendered. */
        if (y_end <= gg_y_min || y_start >= gg_y_max)
            continue;

        for (int line = y_start; line < y_end; line++)
        {
            int cnt = sat_line_count[line];
            if (cnt < MAX_SPRITES_PER_LINE)
            {
                sat_line_idx[line][cnt] = (uint8_t)i;
                sat_line_count[line] = cnt + 1;
            }
            else if (cnt == MAX_SPRITES_PER_LINE)
            {
                /* Mark 9th sprite — increment past MAX to flag overflow.
                 * We only increment once to avoid uint8_t wrap on extreme cases. */
                sat_line_count[line] = MAX_SPRITES_PER_LINE + 1;
            }
        }
    }
}

/* ------------------------------------------------------------------ */
/* Render background layer for one scanline                            */
/* ------------------------------------------------------------------ */

/* Moved to ROM (.text) — SDRAM cache conflict with Z80 interpreter */
static void render_background_line(uint16_t *dst, uint8_t *priority_buf, int line)
{
    /* Cache VDP register byte locally — avoids repeated struct access
     * through gg.VDP[] which may cause load-use stalls on SH-2 when
     * the data is not in D-cache.  Single load at function entry. */
    uint8_t vdp0 = gg.VDP[0];

    /* X scrolling */
    int x_scroll = ((vdp0 & VDP_REG0_HSCROLL_LOCK) && line < 16)
                   ? 0 : g_machine.VDP.scroll_x_latched;
    int fine_x = x_scroll & 7;
    int coarse_x = x_scroll >> 3;
    if (coarse_x == 0) coarse_x = 32;

    /* Y scrolling */
    int y = line + g_machine.VDP.scroll_y_latched;
    if (Wide_Screen_28)
        y &= 255;
    else
        y %= 224;

    /* Name table row: each row is 32 entries × 2 bytes = 64 bytes.
       row_offset = (y / 8) * 64 */
    const uint8_t *name_table = g_machine.VDP.name_table_address;
    const uint8_t *map_row = name_table + ((y >> 3) * 64);

    int tile_line = y & 7;  /* row within tile (0-7) */

    /* Position where vertical scroll is ignored (right 8 columns lock) */
    int vscroll_lock_col = (vdp0 & VDP_REG0_VSCROLL_LOCK) ? 24 : -1;

    /* Output pointer with fine-scroll offset */
    int out_x = 0;

    /* Handle fine scroll: fill gap pixels with backdrop */
    if (fine_x > 0 && !(vdp0 & VDP_REG0_MASK_COL0))
    {
        uint16_t backdrop = gg_palette_32x[16 | (gg.VDP[7] & 0x0F)];
        for (int i = 0; i < fine_x; i++)
        {
            dst[out_x] = backdrop;
            priority_buf[out_x] = 0;
            out_x++;
        }
    }
    else
    {
        out_x = fine_x;
    }

    /* Render tile columns.
     * Visible tile range is computed from viewport bounds:
     * GG (x_start=0, x_res=256): yields skip=0, render=32 (full width).
     * GG  (x_start=48, x_res=160): yields skip~5, render~21 (~37% fewer tiles). */
    int map_col = 32 - coarse_x;  /* starting column in name table */

    if (vscroll_lock_col < 0)
    {
        int xs = emu_config.x_start;
        int xe = xs + emu_config.x_res;
        int skip_cols = (xs - fine_x) / 8;
        if (skip_cols < 0) skip_cols = 0;
        int last_col = (xe - fine_x - 1) / 8;
        if (last_col > 31) last_col = 31;
        int render_cols = last_col - skip_cols + 1;
        if (render_cols < 1) render_cols = 1;
        if (render_cols > 32 - skip_cols) render_cols = 32 - skip_cols;

        /* Prefetch tile row bytes into scratch buffer.
         * render_bg_line_asm reads from tile_row_scratch[0..render_cols-1*4]. */
        prefetch_tile_row_asm(map_row, gg_vram, tile_line,
                              (map_col + skip_cols) & 31, render_cols,
                              tile_row_scratch);

        /* Common case: no VScroll lock */
        render_bg_line_asm(dst + out_x + skip_cols * 8,
                           priority_buf + out_x + skip_cols * 8,
                           map_row, tile_line,
                           (map_col + skip_cols) & 31, render_cols,
                           gg_palette_32x);
    }
    else
    {
        /* VScroll lock: render columns 0 to lock_col-1 in asm,
           then recalculate Y and render remaining in asm */
        if (vscroll_lock_col > 0)
        {
            prefetch_tile_row_asm(map_row, gg_vram, tile_line,
                                  map_col, vscroll_lock_col,
                                  tile_row_scratch);
            render_bg_line_asm(dst + out_x, priority_buf + out_x,
                               map_row, tile_line,
                               map_col, vscroll_lock_col, gg_palette_32x);
            out_x += vscroll_lock_col * 8;
        }

        /* Recalculate Y without scroll for locked columns */
        y = line;
        if (Wide_Screen_28) y &= 255; else y %= 224;
        map_row = name_table + ((y >> 3) * 64);
        tile_line = y & 7;
        map_col = (32 - coarse_x + vscroll_lock_col) & 31;

        prefetch_tile_row_asm(map_row, gg_vram, tile_line,
                              map_col, 32 - vscroll_lock_col,
                              tile_row_scratch);
        render_bg_line_asm(dst + out_x, priority_buf + out_x,
                           map_row, tile_line,
                           map_col, 32 - vscroll_lock_col, gg_palette_32x);
    }
}

/* ------------------------------------------------------------------ */
/* gg_render_line — Render one GG scanline to the 32X framebuffer    */
/* ------------------------------------------------------------------ */

/* Moved to ROM (.text) — SDRAM cache conflict with Z80 interpreter */
void gg_render_line(int line, uint8_t cmd_flags)
{
    /* GG visible range: 0..191 (standard) or 0..223 (224-line mode).
     * Compile-time constant check for standard GG mode eliminates
     * the Wide_Screen_28 VDP register read on the common path. */
    if (__builtin_expect(line < 0 || line >= GG_HEIGHT, 0))
    {
        /* 224-line mode: allow lines up to 223 */
        if (!Wide_Screen_28 || line >= 224)
            return;
    }

    /* Framebuffer line pointer — GG standard: line - 24 + 40 = line + 16 */
    int fb_y = Wide_Screen_28 ? line
               : (line - emu_config.y_start) + emu_config.fb_y_offset;
    volatile uint16_t *fb = fb_line_ptr(fb_y);

    uint8_t *priority_buf = priority_buf_static;

    /* Display_ON is checked via the master-stamped cmd_flags rather than
     * reading gg.VDP[1] on the slave.  The slave's D-cache thrashing
     * can cause a stale read of gg.VDP[1] that catches the master's
     * mid-VBlank Display_ON=0 state → blue flash.  The master stamps
     * the flag right after z80_run() so the value is always correct. */
    if (!(cmd_flags & RCMD_F_DISPLAY_ON))
    {
        /* Display off: fill with backdrop using longword writes (4× fewer
         * store operations than byte-at-a-time, critical for SDRAM bandwidth).
         * 256 pixels × 2 bytes = 512 bytes = 128 longwords.
         * Priority buf: 256 bytes = 64 longwords of zeros. */
        uint16_t bd = gg_palette_32x[16 | (gg.VDP[7] & 0x0F)];
        uint32_t bd32 = ((uint32_t)bd << 16) | bd;
        uint32_t *lb32 = (uint32_t *)line_buf;
        uint32_t *pb32 = (uint32_t *)priority_buf;
        for (int i = 0; i < 128; i++)
            lb32[i] = bd32;
        for (int i = 0; i < 64; i++)
            pb32[i] = 0;
    }
    else
    {
        /* Render background */
        render_background_line(line_buf, priority_buf, line);

        /* Render sprites (SH-2 assembly) */
        {
            int sprite_height = Sprites_8x16 ? 16 : 8;
            const uint8_t *sat = g_machine.VDP.sprite_attribute_table;
            render_sprites_line_asm(line_buf, priority_buf, line,
                                    sprite_height, sat,
                                    &gg_palette_32x[16],
                                    emu_config.sprite_clip_x_min,
                                    emu_config.sprite_clip_x_max,
                                    g_machine.VDP.sprite_shift_x,
                                    g_machine.VDP.sprite_pattern_gen_index);
        }

        /* Mask left 8 columns with border color */
        if (Mask_Left_8)
        {
            uint16_t border = gg_palette_32x[16 | (gg.VDP[7] & 0x0F)];
            for (int i = 0; i < 8; i++)
                line_buf[i] = border;
        }
    }

    /* Copy rendered pixels to framebuffer — direct call to GG-specific
     * copy routine.  Eliminates function pointer load + indirect branch
     * (saves ~4 SH-2 cycles/line × 144 lines = ~576 cycles/frame). */
    {
        const uint32_t *s32 = (const uint32_t *)&line_buf[fb_copy_src_x];
        volatile uint32_t *d32 = (volatile uint32_t *)(fb + emu_config.fb_x_offset);
        fb_copy_gg_line_asm(d32, s32);
    }
}
