/*
 * gg_io.c — Game Gear I/O port dispatch
 *
 * Joypad input comes from MARS COMM8 (written by M68K VBL handler).
 * Button mapping: 32X active-high → active-low GG-compatible pad bits.
 */

#include "gg_emu.h"
#include "gg_io.h"
#include "gg_vdp.h"
#include "32x.h"

/* AUDIT counters */
#if PERF_DEBUG
volatile uint32_t g_in_calls = 0;
volatile uint32_t g_out_calls = 0;

/* ---- ED / CB sub-opcode histograms (prefix-handler cache-thrash audit) ----
 *
 * The Z80 dispatch loop is pure SH-2 assembly (z80_asm.S): every opcode —
 * including the ED/DD/FD/CB prefixes — jumps through a table to an inline
 * handler, so these histograms are bumped there, not in any C function.  Each
 * prefix pull pulls cold handler code into the shared 4KB I/D cache and evicts
 * the hot interpreter stream (the ~4x cyc thrash seen during active display).
 * The per-prefix COUNTS come straight from g_op_hist[0xED/0xDD/0xFD/0xCB]
 * (also bumped in the asm fetch loop); these per-sub-opcode histograms instead
 * show WHICH specific ED / CB opcodes dominate — the top entry is the worst
 * offender.  g_ed_sub_hist covers every ED sub-opcode; g_cb_sub_hist covers both
 * standalone CB (via _z80_cb_prefix) and compound DD+CB / FD+CB (via the DDCB/
 * FDCB handler), e.g. ED DMA 0x42/0x53 or a common LD reg,(IX/IY+d). */
volatile uint16_t g_ed_sub_hist[256] = {0};
volatile uint16_t g_cb_sub_hist[256] = {0};
#endif

/* ------------------------------------------------------------------ */
/* Country / nationalization constants                                 */
/* ------------------------------------------------------------------ */

#define COUNTRY_EXPORT  0
#define COUNTRY_JAPAN   1

/* ------------------------------------------------------------------ */
/* V-counter (Beam_Y equivalent)                                       */
/*                                                                     */
/* NTSC 262 lines: 0x00-0xDA map 1:1, then jump back by 6             */
/*   (0xDB→0xD5, 0xDC→0xD6, ... 0x105→0xFF)                          */
/* We only support NTSC for now.                                       */
/* ------------------------------------------------------------------ */

__attribute__((section(".sdram_code")))
static uint8_t vcounter_read(void)
{
    int line = tgg.VDP_Line;
    /* V-counter jump point: 0xDA (192-line) or 0xEA (224-line) */
    int jump = Wide_Screen_28 ? 0xEA : 0xDA;
    if (line <= jump)
        return (uint8_t)line;
    return (uint8_t)(line - 6);
}

/* ------------------------------------------------------------------ */
/* H-counter (simplified)                                              */
/*                                                                     */
/* Returns an approximation based on remaining Z80 cycles in the       */
/* current scanline.  Good enough for most games.                      */
/* ------------------------------------------------------------------ */

__attribute__((section(".sdram_code")))
static uint8_t hcounter_read(void)
{
    extern z80_t z80;
    int elapsed = z80.IPeriod - z80.ICount;
    if (elapsed < 0) elapsed = 0;
    /* Scale 0..228 cycles → 0..255 counter range */
    return (uint8_t)((elapsed * 256) / z80.IPeriod);
}

/* ------------------------------------------------------------------ */
/* Joypad port DC (controller 1 + partial controller 2)                */
/*                                                                     */
/* GG-compatible DC layout (active-low: 1 = not pressed):              */
/*   Bit 0: P1 Up                                                     */
/*   Bit 1: P1 Down                                                   */
/*   Bit 2: P1 Left                                                   */
/*   Bit 3: P1 Right                                                  */
/*   Bit 4: P1 Button 1 (TL / B)                                     */
/*   Bit 5: P1 Button 2 (TR / C)                                     */
/*   Bit 6: P2 Up                                                     */
/*   Bit 7: P2 Down                                                   */
/* ------------------------------------------------------------------ */

__attribute__((section(".sdram_code")))
static uint8_t input_port_dc(void)
{
    uint16_t pad = tgg.Pad;
    uint8_t v = 0xFF;

    /* Player 1 from COMM8 (bits 0-5) */
    if (pad & SEGA_CTRL_UP)    v &= ~GG_PAD_UP;
    if (pad & SEGA_CTRL_DOWN)  v &= ~GG_PAD_DOWN;
    if (pad & SEGA_CTRL_LEFT)  v &= ~GG_PAD_LEFT;
    if (pad & SEGA_CTRL_RIGHT) v &= ~GG_PAD_RIGHT;
    if (pad & (SEGA_CTRL_A | SEGA_CTRL_B))  v &= ~GG_PAD_B1;  /* Genesis A or B → GG button 1 */
    if (pad & SEGA_CTRL_C)     v &= ~GG_PAD_B2;   /* Genesis C → GG button 2 */

    /* Bits 6-7: P2 Up/Down — no player 2, leave as 1 (not pressed) */
    return v;
}

/* ------------------------------------------------------------------ */
/* Joypad port DD (controller 2 + nationalization bits)                */
/*                                                                     */
/* GG-compatible DD layout (active-low):                               */
/*   Bit 0: P2 Left                                                   */
/*   Bit 1: P2 Right                                                  */
/*   Bit 2: P2 Button 1                                               */
/*   Bit 3: P2 Button 2                                               */
/*   Bit 4: Reset button (active-low, active → 0)                     */
/*   Bit 5: unused (active = 1)                                       */
/*   Bit 6: TH-A nationalization                                      */
/*   Bit 7: TH-B nationalization                                      */
/* ------------------------------------------------------------------ */

__attribute__((section(".sdram_code")))
static uint8_t input_port_dd(void)
{
    uint8_t v = 0xFF;

    /* No player 2 — bits 0-3 stay high (not pressed) */
    /* Bit 4: Reset — always high (not pressed) */
    /* Bit 5: unused */

    /* Nationalization bits (same logic as MEKA country.cpp Nationalize) */
    if (gg.Country == COUNTRY_EXPORT)
    {
        if ((gg.Port3F & 0x0F) == 0x05)
        {
            if ((gg.Port3F & 0xF0) == 0xF0)
                v |= 0xC0;     /* set bits 6,7 */
            else
                v &= 0x3F;     /* clear bits 6,7 */
        }
    }

    return v;
}

/* ------------------------------------------------------------------ */
/* Port output (Z80 OUT instruction)                                   */
/*                                                                     */
/* Branch order optimized for GG games: VDP writes (0x80-0xBF) are     */
/* the most frequent OUT target, followed by PSG (0x40-0x7F).         */
/* I/O control and stereo are rare (<1/frame).                         */
/*                                                                     */
/* Using __builtin_expect to hint the compiler toward the VDP path    */
/* so it generates the shortest branch for the common case.            */
/* ------------------------------------------------------------------ */

/* Kept in .sdram_code for lower access latency from SH-2 hot path.
 * Called via +0x20000000 alias from z80_asm.S to avoid cache churn. */
__attribute__((section(".sdram_code")))
void gg_out(uint16_t port, uint8_t val)
{
#if PERF_DEBUG
    g_out_calls++;
#endif
    unsigned int p = port & 0xFF;
    unsigned int range = p & 0xC0;

    /* 0x80-0xBF: VDP (most frequent OUT target in GG games) */
    if (__builtin_expect(range == 0x80, 1))
    {
        if (p & 0x01)
            gg_vdp_addr_write(val);    /* odd: address/control */
        else
            gg_vdp_data_write(val);    /* even: data */
        return;
    }

    /* 0x40-0x7F: SN76489 PSG (second most frequent) */
    if (range == 0x40)
    {
        gg_psg_write(val);
        return;
    }

    /* 0x00-0x3F: I/O control and GG stereo register (rare) */
    if (range == 0x00)
    {
        if (p == 0x06)
        {
            gg.GG_Stereo = val;
            return;
        }
        if (p & 0x01)
            gg.Port3F = val;
        return;
    }

    /* 0xC0-0xFF: unused high port range (writes ignored) */
}

/* ------------------------------------------------------------------ */
/* Port input (Z80 IN instruction)                                     */
/*                                                                     */
/* Ported from MEKA In_SMS(). GG-compatible port map with mirroring:    */
/*   0x80-0xBF: VDP (even→data, odd→status)                           */
/*   0x40-0x7F: counters (even→V, odd→H)                              */
/*   0xDC/0xC0: joypad port A                                         */
/*   0xDD/0xC1: joypad port B                                         */
/*   0xF2:      FM detection                                          */
/* ------------------------------------------------------------------ */

/* ------------------------------------------------------------------ */
/* Port input (Z80 IN instruction)                                     */
/*                                                                     */
/* Branch order optimized for GG games: VDP reads (0x80-0xBF) are     */
/* the most frequent IN target (status read for VBlank spin-loops).    */
/* H/V counters (0x40-0x7F) are second.  Joypad is once per frame.    */
/* GG-specific ports (0x00-0x06) are rare.                             */
/* ------------------------------------------------------------------ */

__attribute__((section(".sdram_code")))
uint8_t gg_in(uint16_t port)
{
#if PERF_DEBUG
    g_in_calls++;
#endif
    unsigned int p = port & 0xFF;
    unsigned int range = p & 0xC0;

    /* 0x80-0xBF: VDP (most frequent IN target — VBlank status loops) */
    if (__builtin_expect(range == 0x80, 1))
    {
        if (p & 0x01)
            return gg_vdp_status_read();   /* odd: status */
        else
            return gg_vdp_data_read();     /* even: data */
    }

    /* 0x40-0x7F: H/V counters (raster effects, timing) */
    if (range == 0x40)
    {
        if (p & 0x01)
            return hcounter_read();
        else
            return vcounter_read();
    }

    /* 0xC0-0xFF: I/O ports — joypad read (once per frame typically) */
    if (range == 0xC0)
    {
        if (p & 0x01)
            return input_port_dd();
        return input_port_dc();
    }

    /* 0x00-0x06: GG-specific ports (very rare) */
    if (p <= 0x06)
    {
        switch (p)
        {
        case 0x00: return gg.GG_Control;
        case 0x01: return 0x7F;
        case 0x02: return 0xFF;
        case 0x03: return 0x00;
        case 0x04: return 0xFF;
        case 0x05: return 0x00;
        case 0x06: return gg.GG_Stereo;
        }
    }

    return 0xFF;
}

/* ------------------------------------------------------------------ */
/* Input update — called once per frame                                */
/*                                                                     */
/* Reads COMM8 (written by M68K VBL handler) and latches into          */
/* tgg.Pad.  Detects Start press → NMI (Pause button).               */
/* ------------------------------------------------------------------ */

__attribute__((section(".sdram_code")))
void gg_input_update(void)
{
    uint16_t pad = GA_PAD1;
    tgg.Pad = pad;

    /* Game Gear: Start button → port 0x00 bit 7 (active low).
     * Region bit 6 = 1 (Export). Bits 5-0 = 0x3F. */
    {
        uint8_t gg_ctrl = 0x7F;   /* bit 6=1 (export), bits 5-0=0x3F */
        if (!(pad & SEGA_CTRL_START))
            gg_ctrl |= 0x80;      /* Start not pressed → bit 7 high */
        gg.GG_Control = gg_ctrl;
    }
}
