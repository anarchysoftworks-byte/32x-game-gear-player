/**
 * 32X Hardware Definitions for SH-2
 * Based on Chilly Willy's code
 */

#ifndef __32X_H__
#define __32X_H__

#include <stdint.h>

/* Create a 5:5:5 RGB color */
#define COLOR(r,g,b)    (((r)&0x1F)|((g)&0x1F)<<5|((b)&0x1F)<<10)

/* Memory addresses - use 0x24xxxxxx for cached access */
#define MARS_CRAM           (*(volatile uint16_t *)0x20004200)
#define MARS_FRAMEBUFFER    (*(volatile uint16_t *)0x24000000)
#define MARS_OVERWRITE_IMG  (*(volatile uint16_t *)0x24020000)
#define MARS_SDRAM          (*(volatile uint16_t *)0x26000000)

/* System registers */
#define MARS_SYS_INTMSK     (*(volatile uint16_t *)0x20004000)
#define MARS_SYS_DMACTR     (*(volatile uint16_t *)0x20004006)
#define MARS_SYS_DMASAR     (*(volatile uint32_t *)0x20004008)
#define MARS_SYS_DMADAR     (*(volatile uint32_t *)0x2000400C)
#define MARS_SYS_DMALEN     (*(volatile uint16_t *)0x20004010)
#define MARS_SYS_DMAFIFO    (*(volatile uint16_t *)0x20004012)
#define MARS_SYS_VRESI_CLR  (*(volatile uint16_t *)0x20004014)
#define MARS_SYS_VINT_CLR   (*(volatile uint16_t *)0x20004016)
#define MARS_SYS_HINT_CLR   (*(volatile uint16_t *)0x20004018)
#define MARS_SYS_CMDI_CLR   (*(volatile uint16_t *)0x2000401A)
#define MARS_SYS_PWMI_CLR   (*(volatile uint16_t *)0x2000401C)

/*
 * MARS COMM registers (shared MD 68K <-> SH-2 mailbox):
 *   COMM0/2: SH-2 -> MD command/arg
 *   COMM4:   MD -> SH-2 status
 *   COMM6:   Master -> Slave SH-2 command
 *   COMM8/10/12: MD VBL-updated input/tick data (60Hz)
 *
 * Ownership rules must remain strict:
 *   - COMM0/2 written by SH-2, read by MD command loop
 *   - COMM4 written by MD, read by SH-2
 *   - COMM8/10/12 written by MD VBL handler
 */
#define MARS_SYS_COMM0      (*(volatile uint16_t *)0x20004020)  /* SH-2 → MD command */
#define MARS_SYS_COMM2      (*(volatile uint16_t *)0x20004022)  /* SH-2 → MD argument */
#define MARS_SYS_COMM4      (*(volatile uint16_t *)0x20004024)  /* MD → SH-2 status */
#define MARS_SYS_COMM6      (*(volatile uint16_t *)0x20004026)  /* User-defined shared register */
#define MARS_SYS_COMM8      (*(volatile uint16_t *)0x20004028)  /* User-defined shared register */
#define MARS_SYS_COMM10     (*(volatile uint16_t *)0x2000402A)  /* User-defined shared register */
#define MARS_SYS_COMM12     (*(volatile uint16_t *)0x2000402C)  /* User-defined shared register */
#define MARS_SYS_COMM14     (*(volatile uint16_t *)0x2000402E)  /* User-defined shared register */

/*
 * Controller/tick aliases for COMM8/12.
 * Button bits are active-high (1 = pressed).
 */
#define GA_PAD1             MARS_SYS_COMM8     /* Controller 1 via MARS COMM8 */
#define MARS_SYS_USER0      MARS_SYS_COMM10
#define GA_TICK_COUNT       MARS_SYS_COMM12    /* Vblank tick counter (16-bit) */

/* PWM registers */
#define MARS_PWM_CTRL       (*(volatile uint16_t *)0x20004030)
#define MARS_PWM_CYCLE      (*(volatile uint16_t *)0x20004032)
#define MARS_PWM_LEFT       (*(volatile uint16_t *)0x20004034)
#define MARS_PWM_RIGHT      (*(volatile uint16_t *)0x20004036)
#define MARS_PWM_MONO       (*(volatile uint16_t *)0x20004038)

/* VDP registers */
#define MARS_VDP_DISPMODE   (*(volatile uint16_t *)0x20004100)
#define MARS_VDP_FILLEN     (*(volatile uint16_t *)0x20004104)
#define MARS_VDP_FILADR     (*(volatile uint16_t *)0x20004106)
#define MARS_VDP_FILDAT     (*(volatile uint16_t *)0x20004108)
#define MARS_VDP_FBCTL      (*(volatile uint16_t *)0x2000410A)

/* System interrupt mask flags */
#define MARS_SH2_ACCESS_VDP 0x8000
#define MARS_68K_ACCESS_VDP 0x0000

/* Display mode flags */
#define MARS_PAL_FORMAT     0x0000
#define MARS_NTSC_FORMAT    0x8000
#define MARS_VDP_PRIO_68K   0x0000
#define MARS_VDP_PRIO_32X   0x0080
#define MARS_224_LINES      0x0000
#define MARS_240_LINES      0x0040
#define MARS_VDP_MODE_OFF   0x0000
#define MARS_VDP_MODE_256   0x0001   /* 8-bit paletted mode */
#define MARS_VDP_MODE_32K   0x0002   /* 15-bit direct color mode */
#define MARS_VDP_MODE_RLE   0x0003

/* Framebuffer control flags */
#define MARS_VDP_VBLK       0x8000
#define MARS_VDP_HBLK       0x4000
#define MARS_VDP_PEN        0x2000
#define MARS_VDP_FEN        0x0002
#define MARS_VDP_FS         0x0001

/* Cache control */
#define SH2_CCTL_CP         0x10
#define SH2_CCTL_TW         0x08
#define SH2_CCTL_OD         0x04  /* Data-replace disable: data misses don't fill cache */
#define SH2_CCTL_ID         0x02  /* Instruction-replace disable */
#define SH2_CCTL_CE         0x01

/* ------------------------------------------------------------------ */
/* SH-2 Free Running Timer (FRT) — on-chip peripheral registers        */
/*                                                                     */
/* The FRT is a 16-bit up-counter clocked from the internal bus clock  */
/* (SH2 clock / divisor).  Used here for frame-time profiling.         */
/* ------------------------------------------------------------------ */

#define SH2_FRT_TIER    (*(volatile uint8_t  *)0xFFFFFE10) /* Timer interrupt enable */
#define SH2_FRT_FTCSR   (*(volatile uint8_t  *)0xFFFFFE11) /* Timer control/status */
#define SH2_FRT_FRCH    (*(volatile uint8_t  *)0xFFFFFE12) /* Free-running counter H */
#define SH2_FRT_FRCL    (*(volatile uint8_t  *)0xFFFFFE13) /* Free-running counter L */
#define SH2_FRT_TCR     (*(volatile uint8_t  *)0xFFFFFE16) /* Timer control register */

/* TCR clock select bits (CKS1:CKS0) */
#define SH2_FRT_CKS_8   0x00  /* internal / 8   → ~2.88 MHz at 23 MHz */
#define SH2_FRT_CKS_32  0x01  /* internal / 32  → ~719 kHz */
#define SH2_FRT_CKS_128 0x02  /* internal / 128 → ~180 kHz */
#define SH2_FRT_CKS_EXT 0x03  /* external clock */

/* Read FRT counter as 16-bit value (read H first, then L is latched) */
static inline uint16_t sh2_frt_read(void)
{
    uint16_t h = SH2_FRT_FRCH;
    return (h << 8) | SH2_FRT_FRCL;
}

/* Reset FRT counter to 0 */
static inline void sh2_frt_reset(void)
{
    SH2_FRT_FRCH = 0;
    SH2_FRT_FRCL = 0;
}

/* Place hot SH-2 routines in SDRAM-backed sections when needed. */
#define ATTR_DATA_CACHE_ALIGN   __attribute__((section(".sdata"), aligned(16)))

/* Optional cache-coloring sections for workload-specific tuning. */
#define ATTR_HOT_LOOP      __attribute__((section(".sdata.hot_loop"), aligned(16)))
#define ATTR_HOT_HELPER    __attribute__((section(".sdata.hot_helpers"), aligned(16)))
#define ATTR_HOT_PLANE     __attribute__((section(".sdata.hot_planes"), aligned(16)))
#define ATTR_HOT_WALL_TEX  __attribute__((section(".sdata.hot_wall_tex"), aligned(16)))

/* Controller button masks */
#define SEGA_CTRL_UP        0x0001
#define SEGA_CTRL_DOWN      0x0002
#define SEGA_CTRL_LEFT      0x0004
#define SEGA_CTRL_RIGHT     0x0008
#define SEGA_CTRL_B         0x0010
#define SEGA_CTRL_C         0x0020
#define SEGA_CTRL_A         0x0040
#define SEGA_CTRL_START     0x0080
#define SEGA_CTRL_Z         0x0100
#define SEGA_CTRL_Y         0x0200
#define SEGA_CTRL_X         0x0400
#define SEGA_CTRL_MODE      0x0800
#define SEGA_CTRL_TYPE      0xF000
#define SEGA_CTRL_THREE     0x0000
#define SEGA_CTRL_SIX       0x1000
#define SEGA_CTRL_NONE      0xF000

/* ------------------------------------------------------------------ */
/* Uncached SDRAM access                                               */
/*                                                                     */
/* SDRAM at 0x06xxxxxx is cached by each SH-2.  For cross-CPU shared  */
/* data, use the uncached alias at 0x26xxxxxx (OR with 0x20000000).   */
/* ------------------------------------------------------------------ */

#define SH2_UNCACHED(ptr) \
    ((volatile void *)((uint32_t)(ptr) | 0x20000000))

/* ------------------------------------------------------------------ */
/* Async scanline render pipeline                                      */
/*                                                                     */
/* Replaces the old synchronous per-line RENDER_CMD/ACK handshake.     */
/* Master writes render commands to a ring buffer; slave consumes them */
/* at its own pace. Master only blocks once at frame end.              */
/*                                                                     */
/* Layout at shared RAM 0x0603D000 (uncached alias 0x2603D000):       */
/*   +0x00: render_cmd_count  (int16) — master: total cmds this frame */
/*   +0x40: render_done_count (int16) — slave: total lines rendered   */
/*   +0x80: render_frame_start(int16) — master sets 1 to start frame  */
/*   +0x100: render_cmds[0..223] — 4 bytes each (scanline_cmd_t)      */
/*                                                                     */
/* Hot sync words are cache-line separated to reduce false sharing and  */
/* uncached ping-pong under dual-SH2 polling.                           */
/* ------------------------------------------------------------------ */

/* Per-scanline render command — snapshotted by master for slave */
typedef struct {
    int16_t line;       /* Scanline number to render (0-223) */
    uint8_t scroll_x;   /* H-scroll value latched for this line */
    uint8_t flags;      /* RCMD_F_* bits snapshotted by master */
} scanline_cmd_t;

/* Render command flags (master stamps these per-line so the slave
 * doesn't need to read gg.VDP[] across the CPU boundary) */
#define RCMD_F_DISPLAY_ON   0x01  /* Display_ON was set for this line */

#define RENDER_CMD_MAX      224

/* Master → Slave: total commands written for this frame */
#define RENDER_CMD_COUNT    (*(volatile int16_t *)0x2603D000)

/* Slave → Master: total lines the slave has finished rendering */
#define RENDER_DONE_COUNT   (*(volatile int16_t *)0x2603D040)

/* Master → Slave: set to 1 at frame start; slave clears to 0 after ack */
#define RENDER_FRAME_START  (*(volatile int16_t *)0x2603D080)

/* Slave → Master: max render ticks for previous frame (PERF_DEBUG).
 * Placed in shared SDRAM instead of COMM14 to avoid clobbering the
 * PSG relay overflow channel. */
#define RENDER_SLAVE_PERF   (*(volatile uint16_t *)0x2603D0C0)

/* Ring buffer of per-line render commands (starts at +0x08) */
#define RENDER_CMDS         ((volatile scanline_cmd_t *)0x2603D100)

/* SH-2 cache control register */
#define SH2_CCR             (*(volatile uint8_t *)0xFFFFFE92)

/* Purge and re-enable cache (set CP + CE bits) */
static inline void sh2_cache_purge(void)
{
    SH2_CCR = SH2_CCTL_CP | SH2_CCTL_CE;
}

/* ------------------------------------------------------------------ */
/* Slave CMD wakeup flag                                                */
/*                                                                     */
/* Set by slave_cmd ISR (crt0_cart.s), cleared by slave main loop      */
/* (gg_psg.c). Kept for command-interrupt compatibility.               */
/* ------------------------------------------------------------------ */
extern volatile uint8_t slave_cmd_wakeup;

/* Trigger slave CMD interrupt via 68K relay.
 * Master writes COMM6 → 68K polls and writes INTS at 0xA15102 →
 * slave CMD fires → slave_cmd ISR sets slave_cmd_wakeup → slave
 * wakes from SLEEP. */
#define TRIGGER_SLAVE_CMD()  (MARS_SYS_COMM6 = 0x0001)

#endif /* __32X_H__ */
