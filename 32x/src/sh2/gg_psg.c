/*
 * gg_psg.c — Game Gear PSG relay + slave SH-2 main loop
 *
 * Game Gear mode relays PSG writes through COMM4 to the M68K,
 * which forwards bytes to Genesis hardware PSG.
 */

#include "gg_emu.h"
#include "32x.h"

/* Slave CMD wakeup flag — set by slave_cmd ISR, cleared by slave main loop.
 * Placed in .sdram_data so the ISR can write it via uncached alias. */
volatile uint8_t slave_cmd_wakeup __attribute__((section(".sdram_data"))) = 0;

#ifndef PERF_DEBUG
#define PERF_DEBUG  0
#endif

static inline void sh2_backoff_nops(uint32_t count)
{
    while (count--) {
        __asm__ volatile ("nop");
    }
}

/* gg_render.c — per-frame sprite precompute */
extern void sat_precompute(void);

/* ------------------------------------------------------------------ */
/* Mode-specific handlers (set once at init)                           */
/* ------------------------------------------------------------------ */

/* gg_psg_relay.c */
extern void gg_psg_relay_write(uint8_t val);

/* ------------------------------------------------------------------ */
/* PSG init — Game Gear path uses hardware relay only                  */
/*                                                                     */
/* Called on SLAVE SH-2 from slave().  Must run before the main loop   */
/* but AFTER the master has set emu_config.mode.                       */
/* ------------------------------------------------------------------ */

void gg_psg_init(void)
{
    /* GG mode uses hardware PSG relay only — no software audio tick */
}

/* ------------------------------------------------------------------ */
/* PSG write relay — called from Z80 OUT port 0x40-0x7F                */
/* ------------------------------------------------------------------ */

/* Kept in .sdram_code for lower access latency from SH-2 hot path. */
__attribute__((section(".sdram_code")))
void gg_psg_write(uint8_t val)
{
    gg_psg_relay_write(val);
}

/* ================================================================== */
/* Slave SH-2 main loop                                               */
/*                                                                    */
/* Interleaves VDP scanline rendering with optional background work.    */
/* The master SH-2 writes render commands to an async ring buffer;    */
/* between renders the slave services audio (GG mode only).           */
/* ================================================================== */

__attribute__((section(".sdram_code")))
void slave(void)
{
    /* Initialize PSG subsystem (selects mode-specific handlers) */
    gg_psg_init();

    /* Initialize async render pipeline */
    RENDER_CMD_COUNT = 0;
    RENDER_DONE_COUNT = 0;
    RENDER_FRAME_START = 0;

#if PERF_DEBUG
    /* Configure FRT for render profiling (clk/8 → ~2.88 MHz) */
    SH2_FRT_TCR = SH2_FRT_CKS_8;
    uint16_t frame_max_ticks = 0;
#endif
    int16_t read_idx = 0;

    for (;;) {

        /* ---- Check for new frame signal from master ---- */
        if (RENDER_FRAME_START)
        {
            /* Purge data cache so we see master's latest VRAM/palette/VDP.
             * Report previous frame's max render ticks via shared SDRAM. */
            sh2_cache_purge();
#if PERF_DEBUG
            RENDER_SLAVE_PERF = frame_max_ticks;
            frame_max_ticks = 0;
#endif

            /* Build per-line sprite lists from SAT for this frame */
            sat_precompute();

            /* Reset read pointer and done counter for new frame */
            read_idx = 0;
            RENDER_DONE_COUNT = 0;

            /* Acknowledge frame start — unblocks master */
            RENDER_FRAME_START = 0;
        }

        /* ---- Process any available render commands ---- */
        {
            int16_t cmd_count = RENDER_CMD_COUNT;
            if (read_idx < cmd_count)
            {
                /* Process ALL available commands in a tight burst before
                 * polling again.  This reduces uncached RENDER_CMD_COUNT
                 * reads from once-per-line to once-per-burst. */
                do {
                    /* Batch-read entire 4-byte command in one 32-bit load */
                    volatile uint32_t *cmd32 =
                        (volatile uint32_t *)&RENDER_CMDS[read_idx];
                    uint32_t raw = *cmd32;
                    int16_t line    = (int16_t)(raw >> 16);
                    uint8_t scroll_x = (uint8_t)(raw >> 8);
                    uint8_t flags    = (uint8_t)(raw);

                    g_machine.VDP.scroll_x_latched = scroll_x;

#if PERF_DEBUG
                    sh2_frt_reset();
#endif
                    gg_render_line(line, flags);
#if PERF_DEBUG
                    {
                        uint16_t ticks = sh2_frt_read();
                        if (ticks > frame_max_ticks)
                            frame_max_ticks = ticks;
                    }
#endif

                    read_idx++;
                } while (read_idx < cmd_count);
                /* Single uncached write after burst — saves ~8 cycles
                 * per line vs writing inside the loop.  Safe because
                 * master lead (32) >> typical burst size (4). */
                RENDER_DONE_COUNT = read_idx;
            }
            else
            {
                /* No render commands available — brief NOP backoff.
                 *
                 * In parallel mode, new commands arrive at the Z80
                 * scanline rate (~4000 SH-2 cycles apart).  32 NOPs
                 * between polls keeps SDRAM bus traffic low (~1 uncached
                 * read per 42 cycles ≈ 0.024 accesses/cycle) while
                 * maintaining sub-line-interval responsiveness.
                 *
                 * This replaces the SLEEP-based idle loop.
                 * SLEEP required CMD interrupt relay through the M68K
                 * (1000+ cycle latency), which is too slow for parallel
                 * mode where commands arrive continuously.  The polling
                 * overhead (~34K cycles/frame worst case) is far less
                 * than the ~108K-173K cycle savings from parallel
                 * rendering. */
                sh2_backoff_nops(32);
            }
        }
    }
}
