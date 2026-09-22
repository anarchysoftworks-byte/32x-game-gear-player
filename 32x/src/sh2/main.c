/*
 * SH-2 main entry point — 32X Game Gear Player
 *
 * Master SH-2: runs Z80 CPU interpreter + scanline scheduler, synced to VBlank.
 * Slave SH-2: runs VDP rendering (slave() is in gg_psg.c).
 *
 * Optimization: scanline callback is inlined and the 262-line loop is
 * split into three phases (active display / vblank trigger / blanking)
 * to eliminate per-line mode branches.
 */

#include "32x.h"
#include "gg_emu.h"
#include "gg_vdp.h"
#include <stdint.h>

static inline void sh2_backoff_nops(uint32_t count)
{
    while (count--) {
        __asm__ volatile ("nop");
    }
}

/* ------------------------------------------------------------------ */
/* Performance debug overlay                                           */
/*                                                                     */
/* Set PERF_DEBUG to 1 to draw FRT timing bars on the framebuffer      */
/* border.  The bar maps one full 60 Hz frame to 320 pixels:           */
/*   RED     = Z80 active display                                     */
/*   ORANGE  = Z80 blanking                                           */
/*   BLUE    = render-wait (slave busy)                                */
/*   MAGENTA = VBlank wait (idle budget)                               */
/*   GREEN   = remaining frame budget                                  */
/* ------------------------------------------------------------------ */
/* Controllable from Makefile: -DPERF_DEBUG=1 */
#ifndef PERF_DEBUG
#define PERF_DEBUG  0
#endif

/* Z80 blank-burst idle-skip. When enabled, if the Z80 is spinning in HALT
 * during VBlank it reclaims those cycles instead of burning them. Default OFF:
 * a cleanly-halted Z80 burns its whole budget in O(1) (_z80_halt), so halted
 * blanking is nearly free and "mostly orange" blanking usually means polling-jr
 * or real VBlank work, which this cannot see — MEASURE first (see below).
 * Assembly-free: detection reads R->IFF & 0x80 + R->PC stability only.
 * Provably safe: it skips ONLY genuine halt-spin (zero memory/I/O side effects);
 * never touches the active phase or sound/input-critical code. */
#ifndef Z80_BLANK_IDLE_SKIP
#define Z80_BLANK_IDLE_SKIP  0
#endif

#if PERF_DEBUG
/* FRT at clk/128 with 23.01 MHz SH-2 → ~179,766 Hz.
 * 60 fps frame ≈ 2,996 ticks.  16-bit FRT wraps at 65,536 ticks
 * = ~364 ms = ~21.8 frames → no wrap even if frame overruns 20×.
 * 320 px = 1 frame budget → ~9 ticks/px.
 * OLD: clk/8 wrapped at 22.7ms — a 4× overrun frame (67ms) wraps
 * 3 times, making the bars look green (fast) when the game is slow! */
#define PERF_TICKS_PER_PX  9
/* One NTSC frame at 60 Hz ≈ 2,996 FRT ticks (clk/128). Used by the slack
 * marker to express headroom vs. budget as a percentage. */
#define PERF_TICKS_PER_FRAME 2996
#endif

/* ------------------------------------------------------------------ */
/* GG-only compile-time constants                                      */
/* ------------------------------------------------------------------ */
#define GG_Y_INT            192   /* GG never uses 224-line mode */
#define GG_RENDER_START     24    /* emu_config.y_start */
#define GG_RENDER_END       168   /* y_start + y_res */

/* Referenced by SH-2 IRQ glue in crt0_cart.s. */
volatile uint32_t overlay_hint_active = 0;

/* Global emulator config (Game Gear only) */
emu_config_t emu_config;

/* ------------------------------------------------------------------ */
/* Framebuffer management                                              */
/*                                                                     */
/* 32X has two framebuffers (front/back).  We render to the back       */
/* buffer, then flip after completing frame rendering.                 */
/* The framebuffer base depends on the FS (frame select) bit.          */
/*                                                                     */
/* Line table: first 256 words hold per-line word offsets.              */
/* We map a 320-wide scanout and draw the active GG image centered       */
/* in the frame. To stay within one 32X framebuffer (64K words), only    */
/* active GG lines get unique 320-word storage; top/bottom borders       */
/* point to one shared black line.                                      */
/* ------------------------------------------------------------------ */

/* 32X framebuffer constants */
#define FB_LINETABLE_SIZE   256
#define FB_DISPLAY_LINES    224
#define FB_LINE_STRIDE      320     /* 320 display pixels per scanline */
#define FB_BLACK_LINE_BASE  FB_LINETABLE_SIZE
#define FB_ACTIVE_BASE      (FB_BLACK_LINE_BASE + FB_LINE_STRIDE)

#if PERF_DEBUG
/* Draw timing bars on framebuffer.
 * TOP BAR:  1× scale (320px = 1 frame = ~3000 ticks). Shows detail.
 * BOT BAR: 10× scale (320px = 10 frames = ~30000 ticks). Shows overrun.
 * Plus numeric readout of t1 (active display ticks) on bottom bar. */

/* Simple 3×5 digit font.  Each digit is stored as 5 bytes (one per
 * row), with bits 2..0 representing columns left-to-right.
 * bit2 (4) = LEFT pixel, bit1 (2) = MIDDLE, bit0 (1) = RIGHT.
 * E.g. 0x7 = 0b111 = all 3 pixels lit. */
static const uint8_t font3x5[10][5] = {
    {7,5,5,5,7}, /* 0: XXX / X_X / X_X / X_X / XXX */
    {2,6,2,2,7}, /* 1: _X_ / XX_ / _X_ / _X_ / XXX */
    {7,1,7,4,7}, /* 2: XXX / __X / XXX / X__ / XXX */
    {7,1,7,1,7}, /* 3: XXX / __X / XXX / __X / XXX */
    {5,5,7,1,1}, /* 4: X_X / X_X / XXX / __X / __X */
    {7,4,7,1,7}, /* 5: XXX / X__ / XXX / __X / XXX */
    {7,4,7,5,7}, /* 6: XXX / X__ / XXX / X_X / XXX */
    {7,1,1,1,1}, /* 7: XXX / __X / __X / __X / __X */
    {7,5,7,5,7}, /* 8: XXX / X_X / XXX / X_X / XXX */
    {7,5,7,1,7}, /* 9: XXX / X_X / XXX / __X / XXX */
};

static void draw_number(volatile uint16_t *fb, int line_y, int col_x,
                        uint16_t value, uint16_t color)
{
    /* Convert to decimal digits */
    char buf[6];
    int n = 0;
    if (value == 0) buf[n++] = 0;
    else { uint16_t v = value; while (v) { buf[n++] = v % 10; v /= 10; } }
    /* 2× scale: each font pixel = 2×2 screen pixels.
     * Digit size = 6×10.  Draw right-to-left digits left-to-right. */
    int x = col_x;
    for (int i = n - 1; i >= 0; i--) {
        int d = buf[i];
        for (int row = 0; row < 5; row++) {
            volatile uint16_t *line0 = fb + fb[line_y + row * 2];
            volatile uint16_t *line1 = fb + fb[line_y + row * 2 + 1];
            uint8_t bits = font3x5[d][row];
            if (bits & 4) { line0[x+0] = color; line0[x+1] = color;
                            line1[x+0] = color; line1[x+1] = color; }
            if (bits & 2) { line0[x+2] = color; line0[x+3] = color;
                            line1[x+2] = color; line1[x+3] = color; }
            if (bits & 1) { line0[x+4] = color; line0[x+5] = color;
                            line1[x+4] = color; line1[x+5] = color; }
        }
        x += 7; /* 6px digit + 1px gap */
    }
}

static void perf_draw_bar(volatile uint16_t *fb,
                          uint16_t t0, uint16_t t1,
                          uint16_t t2, uint16_t t3, uint16_t t4)
{
    int top_y = emu_config.fb_y_offset;
    int bot_y = emu_config.fb_y_offset + emu_config.y_res - 1;
    int width = 320;
    int x, i, px;
    uint16_t seg;

    /* TOP BAR: 1× scale (normal) — 2 lines thick */
    for (int r = 0; r < 2; r++) {
        volatile uint16_t *bar = fb + fb[top_y + r];
        x = 0;
        seg = t1 - t0; px = seg / PERF_TICKS_PER_PX;
        if (px < 0) px = 0; if (px > width - x) px = width - x;
        for (i = 0; i < px; i++) bar[x++] = COLOR(31, 0, 0) | 0x8000;
        seg = t2 - t1; px = seg / PERF_TICKS_PER_PX;
        if (px < 0) px = 0; if (px > width - x) px = width - x;
        for (i = 0; i < px; i++) bar[x++] = COLOR(31, 16, 0) | 0x8000;
        seg = t3 - t2; px = seg / PERF_TICKS_PER_PX;
        if (px < 0) px = 0; if (px > width - x) px = width - x;
        for (i = 0; i < px; i++) bar[x++] = COLOR(0, 0, 31) | 0x8000;
        seg = t4 - t3; px = seg / PERF_TICKS_PER_PX;
        if (px < 0) px = 0; if (px > width - x) px = width - x;
        for (i = 0; i < px; i++) bar[x++] = COLOR(31, 0, 31) | 0x8000;
        while (x < width) bar[x++] = COLOR(0, 31, 0) | 0x8000;
    }

    /* BOTTOM BAR: 10× scale — shows HOW MUCH over budget.
     * 320px = 10 frames. One frame budget marker at pixel 32.
     * If red reaches px 160, we're 5× over budget. */
    #define PERF_TICKS_PER_PX_10X  (PERF_TICKS_PER_PX * 10)
    for (int r = 0; r < 2; r++) {
        volatile uint16_t *bar = fb + fb[bot_y - r];
        x = 0;
        seg = t1 - t0; px = seg / PERF_TICKS_PER_PX_10X;
        if (px < 0) px = 0; if (px > width - x) px = width - x;
        for (i = 0; i < px; i++) bar[x++] = COLOR(31, 0, 0) | 0x8000;
        seg = t2 - t1; px = seg / PERF_TICKS_PER_PX_10X;
        if (px < 0) px = 0; if (px > width - x) px = width - x;
        for (i = 0; i < px; i++) bar[x++] = COLOR(31, 16, 0) | 0x8000;
        seg = t3 - t2; px = seg / PERF_TICKS_PER_PX_10X;
        if (px < 0) px = 0; if (px > width - x) px = width - x;
        for (i = 0; i < px; i++) bar[x++] = COLOR(0, 0, 31) | 0x8000;
        seg = t4 - t3; px = seg / PERF_TICKS_PER_PX_10X;
        if (px < 0) px = 0; if (px > width - x) px = width - x;
        for (i = 0; i < px; i++) bar[x++] = COLOR(31, 0, 31) | 0x8000;
        while (x < width) bar[x++] = COLOR(0, 31, 0) | 0x8000;
        /* 1-frame marker: white tick at pixel 32 */
        bar[32] = COLOR(31, 31, 31) | 0x8000;
    }

}
#endif

/* 32X framebuffer addressing:
 * The SH-2 always accesses the current WRITE frame at 0x24000000.
 * The FS bit in FBCTL selects which physical frame is the write frame.
 * Toggling FS swaps which frame is written vs displayed.
 * 0x24020000 is overwrite-image mode, NOT the second framebuffer. */

#define FB_WRITE_ADDR   ((volatile uint16_t *)0x24000000)

static void fb_init_linetable(volatile uint16_t *fb)
{
    int i;
    int active_lines = emu_config.y_res;
    int top_border = emu_config.fb_y_offset;

    /* Default all lines to the shared black border line. */
    for (i = 0; i < FB_LINETABLE_SIZE; i++)
        fb[i] = (uint16_t)FB_BLACK_LINE_BASE;

    /* Active display area: centered vertically in 224-line mode. */
    for (i = 0; i < active_lines; i++)
        fb[top_border + i] = (uint16_t)(FB_ACTIVE_BASE + i * FB_LINE_STRIDE);
}

static volatile uint16_t *fb_get_write_ptr(void)
{
    /* FS already selects which physical frame is at 0x24000000 */
    return FB_WRITE_ADDR;
}

/* Track which framebuffer we own in software.  Avoids read-modify-write
 * on FBCTL (which can glitch if FS read returns a stale value).
 * This matches ChillyWilly's 32X reference code. */
static int currentFB = 0;

__attribute__((section(".sdram_code")))
static void fb_flip(void)
{
    /* Toggle frame select.  Writing FS immediately changes which
     * physical frame the SH-2 accesses at 0x24000000.  The VDP
     * display source swaps at VBlank.
     *
     * CRITICAL FIX: The old code spin-waited for the FS readback to
     * match.  The readback reflects the VDP's DISPLAY source, which
     * only updates at VBlank start.  If we write FS even a few lines
     * into VBlank (after drawing perf bars), we miss the latch window
     * and the spin-wait stalls for an ENTIRE FRAME (~16.67ms),
     * halving the effective frame rate to 30fps.
     *
     * Fix: just write FS.  The SH-2 address mapping updates immediately
     * (confirmed by 32X hardware docs and ChillyWilly reference code).
     * No readback spin needed when preceded by wait_vblank(). */
    currentFB ^= 1;
    MARS_VDP_FBCTL = currentFB;
}

/* ------------------------------------------------------------------ */
/* Wait for 32X VBlank                                                 */
/* ------------------------------------------------------------------ */

__attribute__((section(".sdram_code")))
static void wait_vblank(void)
{
    /* Robust VBlank sync: first wait for active video (VBLK LOW), then
     * wait for VBlank start (VBLK HIGH).  This two-phase approach
     * catches a FRESH VBlank edge even when the frame overruns by
     * more than one VBlank period — preventing the stale-VBLK-catch
     * that can cause fb_flip() to execute twice in the same VBlank
     * interval and corrupt double-buffered frame display order. */
    while (MARS_VDP_FBCTL & MARS_VDP_VBLK)
        ;   /* wait for active video (skip any stale VBlank) */
    while (!(MARS_VDP_FBCTL & MARS_VDP_VBLK))
        ;   /* wait for fresh VBlank start */
}

/* ------------------------------------------------------------------ */
/* Set write framebuffer pointer for renderer                          */
/* ------------------------------------------------------------------ */

/* Renderer uses this to get the framebuffer write destination */
extern volatile uint16_t *gg_fb_ptr;

static void emu_config_init_gg(void)
{
    emu_config.mode         = EMU_MODE_GG;
    emu_config.x_res        = 160;
    emu_config.y_res        = 144;
    emu_config.x_start      = 48;
    emu_config.y_start      = 24;
    emu_config.fb_x_offset  = 80;   /* (320-160)/2 */
    emu_config.fb_y_offset  = 40;   /* (224-144)/2 */
    emu_config.tile_start   = 6;
    emu_config.tile_end     = 26;   /* 20 tiles × 8 = 160 pixels */
    emu_config.cram_bytes   = 64;
    emu_config.palette_12bit = 1;
    emu_config.sprite_clip_x_min = 48;
    emu_config.sprite_clip_x_max = 208;
}

/* ================================================================== */
/* z80_run_frame scanline callback                                     */
/*                                                                     */
/* Called by z80_run_frame after each scanline's Z80 cycles complete.  */
/* Handles: scanline tick, H-scroll latch, IRQ delivery, VBlank       */
/* trigger, and render command posting.                                */
/* Returns per-line cycles to continue, 0 when frame is done.         */
/* ================================================================== */

/* Maximum render commands the master can queue ahead of the slave.
 * The command buffer (RENDER_CMDS) holds 224 entries, and GG posts at
 * most 144 (visible lines 24-167).  Buffer overflow is impossible.
 *
 * CRITICAL PERF FIX: Previously GG_RENDER_LEAD=32, which caused the
 * master to spin-poll RENDER_DONE_COUNT (uncached SDRAM) on every
 * visible line, waiting for the slave to keep up.  This serialized
 * master and slave, wasting ~75% of the frame budget in a polling
 * loop that showed up as solid-red perf bars.
 *
 * Setting LEAD > 144 (max visible lines) eliminates backpressure
 * entirely.  The master blasts through Z80 + command posting at full
 * speed, the slave renders in parallel, and any remaining slave work
 * is waited on ONCE at frame end (the blue perf bar). */
#define GG_RENDER_LEAD  200

/* Publish RENDER_CMD_COUNT to the slave after every command so the
 * slave can start rendering immediately instead of waiting for a
 * batch of 4 commands to accumulate.  Maximizes slave parallelism.
 * Cost: 144 uncached writes/frame × ~6 cycles = ~864 cycles total. */
#define GG_RENDER_PUBLISH_STRIDE 1

/* Exported for inline scanline asm in z80_asm.S. */
int frame_line;
int frame_cmd_idx;
int skip_render;   /* 1 = skip rendering this frame (frame skip for 30fps) */
#if PERF_DEBUG
static uint16_t frame_perf_t1b;  /* time between first and second z80_run_frame */
/* Blanking-mode flag (see overlay marker + COMM14): 1 = the blanking burst is
 * HALT(0x76)-dominant with ~2 distinct ops, so the built-in Z80_BLANK_IDLE_SKIP
 * would remove it and shrink the orange bar; 0 = polling-jr / real VBlank work
 * that must NOT be skipped. Drives the on-screen blanking-mode marker below. */
static uint8_t  perf_blank_halt;
/* Blanking hot-opcodes (hoisted so the overlay below can read them back).
 * b_top_op[0] is exactly COMM14's high byte — the single most-frequent opcode
 * executed during the VBlank burst. We can't skip that work (marker is amber),
 * so this tells us WHICH handler to optimize next. */
static uint8_t  b_top_op[3];
static uint16_t b_top_cnt[3];
#endif

__attribute__((section(".sdram_code")))
int frame_scanline_cb(z80_t *R)
{
    int line = frame_line;
    int state_modified = 0;  /* set when z80_set_irq/nmi dispatches */

    if (line < GG_Y_INT) {
        /* Active display scanlines */
        tgg.VDP_Line = line;

        /* SCANLINE_TICK: H-scroll latch, H-blank counter, IRQ */
        g_machine.VDP.scroll_x_latched = gg.VDP[8];
        if (gg.Lines_Left-- <= 0) {
            gg.Lines_Left = gg.VDP[10];
            gg.Pending_HBlank = 1;
        }
        if (gg.Pending_HBlank && HBlank_ON) {
            z80_set_irq(R, Z80_INT_IRQ);
            state_modified = 1;
        }
        if (gg.Pending_NMI) {
            gg.Pending_NMI = 0;
            z80_nmi(R);
            state_modified = 1;
        }

        /* Render command for GG viewport lines (skipped on frame-skip frames) */
        if (!skip_render && line >= GG_RENDER_START && line < GG_RENDER_END) {
            while (frame_cmd_idx - (int)RENDER_DONE_COUNT >= GG_RENDER_LEAD)
                sh2_backoff_nops(16);
            /* Pack all 4 bytes into a single 32-bit uncached store.
             * Layout: line (bits 31-16) | scroll_x (bits 15-8) | flags (bits 7-0).
             * Matches slave batch-read decomposition in gg_psg.c.
             * Saves 2 uncached write bus transactions per visible line. */
            {
                uint32_t cmd = ((uint32_t)(uint16_t)line << 16)
                             | ((uint32_t)g_machine.VDP.scroll_x_latched << 8)
                             | (Display_ON ? RCMD_F_DISPLAY_ON : 0);
                *(volatile uint32_t *)&RENDER_CMDS[frame_cmd_idx] = cmd;
            }
            frame_cmd_idx++;
            if (((frame_cmd_idx & (GG_RENDER_PUBLISH_STRIDE - 1)) == 0)
                || (line == (GG_RENDER_END - 1))) {
                RENDER_CMD_COUNT = (int16_t)frame_cmd_idx;
            }
        }
    }
    else if (line == GG_Y_INT) {
        /* Line 192: last H-blank tick before VBlank */
        tgg.VDP_Line = GG_Y_INT;
        if (gg.Lines_Left-- <= 0) {
            gg.Lines_Left = gg.VDP[10];
            gg.Pending_HBlank = 1;
        }
        if (gg.Pending_HBlank && HBlank_ON) {
            z80_set_irq(R, Z80_INT_IRQ);
            state_modified = 1;
        }
        if (gg.Pending_NMI) {
            gg.Pending_NMI = 0;
            z80_nmi(R);
            state_modified = 1;
        }
    }
    else if (line == GG_Y_INT + 1) {
        /* Line 193: VBlank flag + VBlank IRQ */
        tgg.VDP_Line = GG_Y_INT + 1;
        gg.VDP_Status |= VDP_STATUS_VBLANK;
        if (VBlank_ON)
            z80_set_irq(R, Z80_INT_IRQ);
        if (gg.Pending_NMI) {
            gg.Pending_NMI = 0;
            z80_nmi(R);
        }
        /* End callback-based execution here.
         * Remaining 68 blanking lines (194–261) are batched as a
         * single z80_run() in the main loop — no per-line callbacks,
         * no IRQ delivery, no render commands.  Eliminates 68
         * callback round-trips (~6,800 SH-2 cycles/frame). */
        return 0;
    }

    frame_line++;
    if (frame_line >= GG_LINES_NTSC) return 0;
    /* Negative return signals assembly to reload PC/ICount from struct
     * (z80_set_irq/nmi modified them). Positive = registers still valid. */
    return state_modified ? -GG_CYCLES_PER_LINE : GG_CYCLES_PER_LINE;
}

/* ------------------------------------------------------------------ */
/* Master SH-2 entry point                                             */
/* ------------------------------------------------------------------ */

__attribute__((section(".sdram_code")))
int main(void)
{
    MARS_SYS_COMM12 = 0x0001;  /* DEBUG: entered main */

    /* --- Game Gear-only runtime configuration --- */
    emu_config_init_gg();

    /* --- Initialize memory subsystem --- */
    gg_mem_init(rom_data, rom_size);
    MARS_SYS_COMM12 = 0x0002;  /* DEBUG: mem init done */

    /* --- Initialize mapper (autodetect) --- */
    gg_mapper_init(rom_data, rom_size);
    MARS_SYS_COMM12 = 0x0003;  /* DEBUG: mapper init done */

    /* --- Initialize VDP --- */
    gg_vdp_init();
    MARS_SYS_COMM12 = 0x0004;  /* DEBUG: vdp init done */

    /* --- Initialize renderer (tile decode LUT) --- */
    gg_render_init();

    /* --- Initialize Z80 CPU --- */
    z80_reset(&z80);
    z80.IPeriod = GG_CYCLES_PER_LINE;
    MARS_SYS_COMM12 = 0x0005;  /* DEBUG: z80 reset done */

    /* --- Initialize emulator state --- */
    gg.Country = 0;        /* COUNTRY_EXPORT */
    gg.Port3F  = 0xFF;
    gg.GG_Control = 0xFF;  /* all bits high = not pressed, export region */
    gg.GG_Stereo  = 0xFF;  /* all channels enabled both speakers */
    tgg.VDP_Line = -1;     /* Will wrap to 0 on first scanline_callback */
    tgg.Pad = 0;
    tgg.Pause_Pressed = 0;
    g_machine.TV_lines = GG_LINES_NTSC;

    /* --- Set up 32X display: direct-color, 32X priority, 224 lines --- */
    MARS_SYS_COMM12 = 0x0006;  /* DEBUG: before FEN wait */
    while (MARS_VDP_FBCTL & MARS_VDP_FEN)
        ;   /* Wait for framebuffer access */
    MARS_SYS_COMM12 = 0x0007;  /* DEBUG: FEN clear, setting DISPMODE */
    MARS_VDP_DISPMODE = MARS_NTSC_FORMAT | MARS_VDP_PRIO_32X
                      | MARS_224_LINES | MARS_VDP_MODE_32K;
    MARS_SYS_COMM12 = 0x0008;  /* DEBUG: DISPMODE set */

    /* Initialize line tables and clear both framebuffers.
       Since 0x24000000 always maps to the FS-selected write frame,
       we toggle FS to access each physical frame in turn.
       Wait for FEN after each toggle to ensure the buffer is accessible. */
    {
        volatile uint16_t *fb = FB_WRITE_ADDR;
        int i;
        int fb_total = FB_ACTIVE_BASE + emu_config.y_res * FB_LINE_STRIDE;

        /* Frame 0: FS=0 → write frame is physical FB0 */
        MARS_VDP_FBCTL = 0;
        while (MARS_VDP_FBCTL & MARS_VDP_FEN) ;
        fb_init_linetable(fb);
        for (i = FB_LINETABLE_SIZE; i < fb_total; i++)
            fb[i] = 0x8000;

        /* Need VBlank for FS swap to take effect on display side */
        wait_vblank();

        /* Frame 1: FS=1 → write frame is physical FB1 */
        MARS_VDP_FBCTL = 1;
        while (MARS_VDP_FBCTL & MARS_VDP_FEN) ;
        fb_init_linetable(fb);
        for (i = FB_LINETABLE_SIZE; i < fb_total; i++)
            fb[i] = 0x8000;
    }

    /* Start with FS=0: write frame = FB0.  After first render + flip,
       FB0 becomes the display frame and FB1 becomes the write frame. */
    currentFB = 0;
    MARS_VDP_FBCTL = 0;
    while ((MARS_VDP_FBCTL & MARS_VDP_FS) != 0)
        ;

    /* Wait for first VBlank to synchronize */
    wait_vblank();

    /* ================================================================ */
    /* Main emulation loop                                              */
    /*                                                                  */
    /* Each iteration = one frame (262 scanlines at 228 Z80 cycles).    */
    /* Game Gear-only path uses callback-driven active/VBlank handling   */
    /* plus batched blanking-line execution for lower overhead.          */
    /* ================================================================ */

    MARS_SYS_COMM12 = 0x0010;  /* DEBUG: entering main loop */

#if PERF_DEBUG
    /* Configure master FRT for frame profiling (clk/128 → ~180 kHz).
     * Clear status flags and disable interrupts so the counter
     * free-runs without clearing on compare match. */
    SH2_FRT_TIER  = 0x00;             /* no FRT interrupts */
    SH2_FRT_FTCSR = 0x00;             /* clear flags, CCLRA=0 */
    SH2_FRT_TCR   = SH2_FRT_CKS_128;  /* internal / 128 — prevents 16-bit wrap */
    uint16_t perf_frame_count = 0;
    /* Total frame time (incl. wait_vblank + fb_flip) from the previous frame,
     * used by the on-screen slack marker shown at the top of each new frame. */
    uint16_t perf_prev_used = 0;
#endif

    for (;;)
    {
        /* Update joypad from COMM8 (written by M68K VBL handler) */
        gg_input_update();

        /* Frame skip disabled — perf bar shows >50% green (idle budget).
         * Z80 JIT + slave renderer both finish well within one 60Hz frame. */
        skip_render = 0;

        if (!skip_render) {
            /* Set framebuffer pointer for renderer (slave reads this) */
            gg_fb_ptr = fb_get_write_ptr();
        }

        /* ---- Line 0: frame start, latch scroll, reload H-counter ---- */
        tgg.VDP_Line = 0;
        g_machine.VDP.scroll_x_latched = gg.VDP[8];
        g_machine.VDP.scroll_y_latched = gg.VDP[9];
        gg.Lines_Left = gg.VDP[10];

#if PERF_DEBUG
        sh2_frt_reset();
        uint16_t perf_t0 = sh2_frt_read();
        extern volatile uint16_t g_op_hist[256];
        /* Reset per-opcode histogram at frame start — accumulates
         * over the whole frame (active + blanking) for this pass. */
        for (int i = 0; i < 256; i++) g_op_hist[i] = 0;
#endif

        /* ============================================================ */
        /* Parallel emulation: master runs Z80, slave renders.          */
        /*                                                              */
        /* The slave renders scanlines in parallel with the master Z80  */
        /* interpreter.  The scanline callback (frame_scanline_cb)      */
        /* posts render commands to RENDER_CMDS[] and publishes         */
        /* RENDER_CMD_COUNT incrementally.  The slave picks up commands  */
        /* as they arrive and renders them during Z80 execution.        */
        /*                                                              */
        /* Both CPUs access SDRAM; each has its own 4KB cache.  The     */
        /* slave's render hot-path runs from ROM (adapter bus), so only  */
        /* data reads hit SDRAM from the slave side.                     */
        /* ============================================================ */

        frame_line = 0;
        frame_cmd_idx = 0;

        if (!skip_render) {
            /* Flush master cache to SDRAM so the slave sees our latest
             * writes to scroll_y_latched, scroll_x_latched, gg_fb_ptr,
             * and other frame-global state before it starts rendering. */
            SH2_CCR = SH2_CCTL_CP | SH2_CCTL_CE;

            /* Reset command pipeline and signal slave start.  The slave
             * polls RENDER_FRAME_START directly (async ring-buffer
             * handshake) — no COMM6→M68K→INTS relay is needed, so the
             * vestigial TRIGGER_SLAVE_CMD() wake path has been dropped
             * (see PERF_AUDIT.md F3): slave_cmd_wakeup is never read and
             * nothing else writes COMM6.  The slave does cache_purge +
             * sat_precompute during the ~24 non-visible Z80 lines, then
             * processes render commands as they arrive from inline cb. */
            RENDER_CMD_COUNT = 0;
            RENDER_DONE_COUNT = 0;
            RENDER_FRAME_START = 1;
        }

        z80_run_frame(&z80, GG_CYCLES_PER_LINE, frame_scanline_cb);

#if PERF_DEBUG
        frame_perf_t1b = sh2_frt_read();
#endif
        /* Blanking Z80 run with data-replace-disable (OD=1).
         *
         * The Z80 interpreter is ~17KB but the SH-2 cache is only 4KB.
         * During a long uninterrupted run, Z80 data reads (ROM bytes,
         * RAM, lookup tables) fill cache lines that evict interpreter
         * code, causing severe thrashing (~47 SH-2 cycles per Z80 cycle
         * instead of ~5).
         *
         * Setting CCR.OD=1 tells the SH-2 that data-read misses should
         * NOT replace cache lines.  Only instruction fetches fill cache.
         * This means the interpreter's hot instruction stream stays
         * cached while Z80 data reads go direct to SDRAM (no eviction).
         * Each Z80 data byte costs ~6-10 SH-2 cycles (uncached SDRAM)
         * but interpreter dispatch stays at 1 cycle/instruction. */
#define GG_BLANKING_LINES  (GG_LINES_NTSC - (GG_Y_INT + 2))
        /* OD=1 is the measured optimum for the blanking burst.
         * Disabling it costs +568 FRT ticks: the VBlank ISR touches
         * scattered data causing D-cache fills that evict hot interpreter
         * code.  With OD=1, data-read misses bypass the cache entirely
         * (SDRAM direct), keeping the interpreter stream resident. */

        /* PERF_DEBUG: snapshot the whole-frame opcode histogram BEFORE blanking
         * so we can isolate the blanking-phase workload by differencing.
         * g_op_hist is bumped unconditionally in z80_asm.S's fetch loop; at
         * this point it holds only t1 (active-display) contributions. */
#if PERF_DEBUG
        extern volatile uint16_t g_op_hist[256];
        static uint16_t hist_blank_before[256];
        for (int i = 0; i < 256; i++) hist_blank_before[i] = g_op_hist[i];
#endif

#if Z80_BLANK_IDLE_SKIP
        /* ---- Blank-burst idle-skip (see PERF_AUDIT.md §HALT-IDLE-SKIP) ---- */
        /* If the Z80 is spinning in HALT during VBlank, reclaim those cycles.
         * Detection after one line-chunk: halt-bit (IFF&0x80) set AND PC has not
         * advanced past the HALT opcode = genuine halt-spin. A jr/poll loop moves
         * no net PC but never sets IFF&0x80, so it is correctly NOT skipped here
         * (that path needs side-effect instrumentation instead). */
        SH2_CCR = SH2_CCTL_OD | SH2_CCTL_CE;
        {
            int remaining = GG_BLANKING_LINES * GG_CYCLES_PER_LINE;
            uint16_t pc_probe = z80.PC.W;
            z80_run(&z80, GG_CYCLES_PER_LINE);   /* probe one line */
            remaining -= GG_CYCLES_PER_LINE;
            if ((z80.IFF & 0x80) && (z80.PC.W == pc_probe)) {
                /* Confirmed halt-spin: self-perpetuating through all of VBlank,
                 * zero memory/I/O side effects. Skip the rest — those cycles
                 * would otherwise burn in _z80_halt with no effect. ICount is
                 * already ~0 after the probe (halt-burn leaves it at the mod-4
                 * remainder), so next frame starts fresh: no carry-over. */
            } else if (remaining > 0) {
                /* Not halting: real VBlank work or polling-jr without HALT.
                 * Run the remainder normally — never skip active code. */
                z80_run(&z80, remaining);
            }
        }
        SH2_CCR = SH2_CCTL_CP | SH2_CCTL_CE;
#else
        /* ---- Original blanking burst (OD=1 cache strategy) ---- */
        SH2_CCR = SH2_CCTL_OD | SH2_CCTL_CE;
        z80_run_frame(&z80, GG_BLANKING_LINES * GG_CYCLES_PER_LINE, (void*)0);
        SH2_CCR = SH2_CCTL_CP | SH2_CCTL_CE;
#endif
        tgg.VDP_Line = GG_LINES_NTSC - 1;

        MARS_SYS_COMM12 = 0xBBBB;  /* marker: blanking Z80 complete */

#if PERF_DEBUG
        {
            /* Isolate the blanking-phase opcode workload by differencing against
             * the pre-blanking snapshot. Ground truth for choosing an
             * optimization: HALT(0x76)-dominant with zero writes → idle-skip
             * helps; polling-jr (0x18/0xC3/DD...) with zero writes → needs a
             * side-effect detector; port I/O / real opcodes → VBlank work, do NOT
             * skip the Z80. Exposed via free COMM registers for hardware readout. */
             /* Hoisted to function scope (see above). Clear each frame: blanking
              * workload varies, so stale ranking entries from a previous frame would
              * otherwise skew the results below. */
             b_top_op[0]=b_top_op[1]=b_top_op[2] = 0;
             b_top_cnt[0]=b_top_cnt[1]=b_top_cnt[2] = 0;
             uint16_t g_blank_distinct = 0;
            for (int i = 0; i < 256; i++) {
                uint16_t d = g_op_hist[i] - hist_blank_before[i];
                if (d > 0) {
                    g_blank_distinct++;
                    if (d > b_top_cnt[0]) {
                        b_top_op[2]=b_top_op[1]; b_top_cnt[2]=b_top_cnt[1];
                        b_top_op[1]=b_top_op[0]; b_top_cnt[1]=b_top_cnt[0];
                        b_top_op[0]=(uint8_t)i; b_top_cnt[0]=d;
                    } else if (d > b_top_cnt[1]) {
                        b_top_op[2]=b_top_op[1]; b_top_cnt[2]=b_top_cnt[1];
                        b_top_op[1]=(uint8_t)i; b_top_cnt[1]=d;
                    } else if (d > b_top_cnt[2]) {
                        b_top_op[2]=(uint8_t)i; b_top_cnt[2]=d;
                    }
                }
            }
             /* low byte = distinct blanking opcode count (primary discriminator); high byte = most-frequent blanking opcode (0x76 => HALT-dominated). COMM8/10/12 are MD-VBL-owned (32x.h) and COMM6 feeds slave-wake, so COMM14 is the only unambiguously free shared register. */
             MARS_SYS_COMM14 = ((uint16_t)b_top_op[0] << 8) | g_blank_distinct;
             /* On-screen discriminator marker (see overlay below): HALT-dominated
              * => idle-skip safe; anything else => real work, leave the Z80 running. */
             perf_blank_halt = (g_blank_distinct <= 2 && b_top_op[0] == 0x76) ? 1 : 0;
        }
#endif

#if PERF_DEBUG
        /* t1 is the END-OF-VISIBLE timestamp (frame_perf_t1b, captured right
         * after the visible z80_run_frame returns).  Splitting vis = t1 - t0
         * from blk = t2 - t1 here makes the bars honest: red = visible
         * scanlines, orange = the blanking burst.  (frame_perf_t1b was chosen
         * over the old frame_perf_t1 because it is captured once in main()'s
         * flow at a single point rather than inside the per-scanline callback.) */
        uint16_t perf_t1 = frame_perf_t1b;   /* end of visible phase */
        uint16_t perf_t2 = sh2_frt_read();   /* end of blanking burst */
        uint16_t vis = (uint16_t)(perf_t1 - perf_t0);  /* visible scanline cycles */
        uint16_t blk = (uint16_t)(perf_t2 - perf_t1);  /* blanking-burst cycles */
#endif

        if (!skip_render) {
            /* Wait for slave to finish any remaining render commands.
             * Render ran in parallel with Z80; usually the slave is already
             * done so this exits immediately.  The slave advances
             * RENDER_DONE_COUNT on its next poll of RENDER_CMD_COUNT — its
             * bounded ~32-NOP backoff guarantees a re-poll within tens of
             * cycles, and these are volatile shared-SDRAM words the compiler
             * cannot reorder or hide — so no COMM6 wakeup is needed.  The
             * vestigial TRIGGER_SLAVE_CMD() relay has been dropped (see
             * PERF_AUDIT.md F3).  Worst case is a few extra spin iterations,
             * never a stall: RENDER_DONE_COUNT can only reach frame_cmd_idx
             * once every posted command has actually been rendered. */
            while (RENDER_DONE_COUNT < frame_cmd_idx)
                sh2_backoff_nops(32);
        }

#if PERF_DEBUG
        uint16_t perf_t3 = sh2_frt_read();  /* end of render wait */
        uint16_t rw  = (uint16_t)(perf_t3 - perf_t2);    /* render-wait overhead */
#endif

        /* Draw perf overlay BEFORE vblank so the drawing time doesn't
         * eat into the vblank window and delay fb_flip().  Without t4
         * (post-vblank timestamp), the magenta segment is omitted and
         * GREEN shows the full remaining frame budget. */
        if (!skip_render) {
#if PERF_DEBUG
            perf_draw_bar(gg_fb_ptr, perf_t0, perf_t1,
                          perf_t2, perf_t3, perf_t3);
            perf_frame_count++;
             /* On-screen diagnostics: one value per row, 2x font.
              * Each row = 11px tall (10px digits + 1px gap). Values are FRT
              * cycle deltas between the timestamps captured above; FRT is a
              * free-running 16-bit counter that does not wrap within one frame
              * even at ~20x overrun. Colors mirror the timing bars:
              *   Row 0: visible  (white)  - Z80 cycles for visible scanlines
              *   Row 1: blanking (orange) - Z80 cycles in the VBlank burst
              *        (dominant cost; matches the orange bar segment)
              *   Row 2: rwait    (blue)  - master's render-wait overhead
              *   Row 3: frame#   (yellow) - cumulative frame counter
              *   Row 4: slack%   (g/a/r) - headroom vs one-frame budget,
              *        using total frame time measured AFTER fb_flip last frame
              *        (green = headroom, amber = tight ~8%, red = over budget)
              * Plus a 10x10 block that alternates white/red each frame. */
            {
                int base_y = emu_config.fb_y_offset + 3;
                uint16_t black   = 0x8000;
                uint16_t white   = COLOR(31,31,31) | 0x8000;
                uint16_t orange  = COLOR(31,16,0) | 0x8000;
                uint16_t yellow  = COLOR(31,31,0) | 0x8000;

                /* Clear background: 50px left, 80px right × 44 rows.
                 * Right panel widened to fit 5-digit histogram counts. */
                /* Extend one extra row below the marker so the blanking-opcode
                 * readout at base_y+44 has clean black background to sit on. */
                for (int row = 0; row < 55; row++) {
                    volatile uint16_t *line = gg_fb_ptr + gg_fb_ptr[base_y + row];
                    for (int cx = 0; cx < 50; cx++) {
                        line[cx] = black;
                    }
                    for (int cx = 0; cx < 80; cx++) {
                        line[320 - 80 + cx] = black;
                    }
                }

                draw_number(gg_fb_ptr, base_y +  0, 1, vis, white);
                draw_number(gg_fb_ptr, base_y + 11, 1, blk, orange);
                draw_number(gg_fb_ptr, base_y + 22, 1, rw, COLOR(0,0,31) | 0x8000);
                draw_number(gg_fb_ptr, base_y + 33, 1, perf_frame_count, yellow);

                /* Frame-slack marker (Tier-1 item 1): headroom vs. one-frame
                 * budget, using total frame time measured AFTER fb_flip last
                 * frame.  Green = headroom, amber = tight (~8%), red = over
                 * budget.  Shows last frame's value (one-frame display latency,
                 * which is fine for steady-state diagnosis). */
                {
                    int32_t slack = (int32_t)PERF_TICKS_PER_FRAME - perf_prev_used;
                    uint16_t slack_pct = (uint16_t)(((slack >= 0 ? slack : -slack) * 100)
                                                    / PERF_TICKS_PER_FRAME);
                    uint16_t scolor = slack > 0 ? (COLOR(0,31,0) | 0x8000)
                              : slack < 0 ? (COLOR(31,0,0) | 0x8000)
                                          : (COLOR(31,31,0) | 0x8000);
                    draw_number(gg_fb_ptr, base_y + 44, 1, slack_pct, scolor);
                }

                /* Top-3 main-opcode histogram for this frame.
                 * Replaces the broken g_op_count/out/in readouts: g_op_count
                 * was never incremented for main opcodes, only for prefix
                 * handlers. This histogram is bumped unconditionally in the
                 * fetch loop (z80_asm.S) and is the ground truth. */
                uint8_t  top_op[3]  = {0,0,0};
                uint16_t top_cnt[3] = {0,0,0};
                for (int i = 0; i < 256; i++) {
                    uint16_t c = g_op_hist[i];
                    if (c > top_cnt[0]) {
                        top_op[2] = top_op[1]; top_cnt[2] = top_cnt[1];
                        top_op[1] = top_op[0]; top_cnt[1] = top_cnt[0];
                        top_op[0] = (uint8_t)i; top_cnt[0] = c;
                    } else if (c > top_cnt[1]) {
                        top_op[2] = top_op[1]; top_cnt[2] = top_cnt[1];
                        top_op[1] = (uint8_t)i; top_cnt[1] = c;
                    } else if (c > top_cnt[2]) {
                        top_op[2] = (uint8_t)i; top_cnt[2] = c;
                    }
                }
                /* Right panel (80px wide): 3 rows of (opcode_dec, count_dec).
                 * Opcode at col 241 (max 3 digits = 21px, ends at 262).
                 * Count at col 263 (up to 8 digits fits in remaining 57px).
                 * Cyan = most frequent, orange = 2nd, yellow = 3rd. */
                draw_number(gg_fb_ptr, base_y +  0, 320 - 80 + 1,  top_op[0],  COLOR(0,31,31) | 0x8000);
                draw_number(gg_fb_ptr, base_y +  0, 320 - 80 + 23, top_cnt[0], COLOR(0,31,31) | 0x8000);
                draw_number(gg_fb_ptr, base_y + 11, 320 - 80 + 1,  top_op[1],  orange);
                draw_number(gg_fb_ptr, base_y + 11, 320 - 80 + 23, top_cnt[1], orange);
                draw_number(gg_fb_ptr, base_y + 22, 320 - 80 + 1,  top_op[2],  yellow);
                draw_number(gg_fb_ptr, base_y + 22, 320 - 80 + 23, top_cnt[2], yellow);

                /* Blanking-mode marker (bottom row of left panel): tells you whether the
                 * built-in Z80_BLANK_IDLE_SKIP would shrink the orange bar THIS frame.
                 *   green = HALT(0x76)-dominant, ~2 distinct ops -> idle-skip safe
                 *   amber = polling-jr / real VBlank work          -> leave Z80 running */
                {
                    volatile uint16_t *line = gg_fb_ptr + gg_fb_ptr[base_y + 43];
                    uint16_t mark = perf_blank_halt ? (COLOR(0,31,0) | 0x8000) : (COLOR(31,16,0) | 0x8000);
                    for (int cx = 0; cx < 12; cx++) line[cx] = mark;
                }

                /* Blanking-isolated hot-opcodes (same opcode-decimal + count-decimal
                 * format as the whole-frame histogram above, but isolated to the VBlank
                 * burst via frame-differencing). Distinct colors so it reads as its own
                 * section below the histogram — tells us WHICH instruction eats the
                 * orange bar. Marker is amber so we can't skip them; this targets the fix. */
                draw_number(gg_fb_ptr, base_y + 33, 320 - 80 + 1, b_top_op[0], COLOR(0,31,0) | 0x8000);
                draw_number(gg_fb_ptr, base_y + 33, 320 - 80 + 23, b_top_cnt[0], COLOR(0,31,0) | 0x8000);
                draw_number(gg_fb_ptr, base_y + 44, 320 - 80 + 1, b_top_op[1], white);
                draw_number(gg_fb_ptr, base_y + 44, 320 - 80 + 23, b_top_cnt[1], white);

                /* Alternating block: 10×10 pixels at col 40. */
                {
                    uint16_t blk_color = (perf_frame_count & 1)
                                       ? white : COLOR(31,0,0) | 0x8000;
                    for (int row = 0; row < 10; row++) {
                        volatile uint16_t *line = gg_fb_ptr +
                            gg_fb_ptr[base_y + row];
                        for (int cx = 40; cx < 50; cx++)
                            line[cx] = blk_color;
                    }
                }
            }
            /* COMM register readout (Tier-1). Only even-numbered shared regs
             * exist; COMM6=wake, COMM8=pad1, COMM14=blanking histogram are all
             * committed, so COMM10/COMM12 carry the two dominant Z80 lumps.
             *   COMM10 = visible-scanline cycles (white bar segment)
             *   COMM12 = blanking-burst cycles    (orange bar segment; dominant)
             * rw and slack% are shown on-screen only. */
            MARS_SYS_COMM10 = vis;
            MARS_SYS_COMM12 = blk;
#endif
        }

        /* Sync to VBlank then flip.  On 32X, the FS readback updates
         * at VBlank.  wait_vblank ensures we're in VBlank, then fb_flip
         * writes FS and the readback matches immediately (same VBlank). */
        wait_vblank();

        if (!skip_render) {
            fb_flip();
#if PERF_DEBUG
            /* Capture total frame time (incl. wait_vblank + fb_flip) now that
             * fb_flip is done, so the slack marker at the top of NEXT frame has
             * a real denominator vs. one-frame budget (~2996 FRT ticks). Modular
             * subtraction against perf_t0 (VBlank entry) stays correct across any
             * 16-bit FRT wrap within the frame. */
            perf_prev_used = (uint16_t)(sh2_frt_read() - perf_t0);
#endif
        }
    }
}
