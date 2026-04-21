/*
 * gg_io.h — GG I/O port dispatch declarations
 *
 * Declarations for the Game Gear I/O port read/write handlers.
 * Implementation in gg_io.c.
 */

#ifndef GG_IO_H
#define GG_IO_H

#include <stdint.h>

/* ------------------------------------------------------------------ */
/* GG I/O port map (active ranges)                                    */
/* ------------------------------------------------------------------ */

/* Reading */
#define GG_PORT_VCOUNTER       0x7E    /* V counter (current scanline) */
#define GG_PORT_HCOUNTER       0x7F    /* H counter */
#define GG_PORT_VDP_DATA       0xBE    /* VDP data read (even 0x80-0xBF) */
#define GG_PORT_VDP_CTRL       0xBF    /* VDP status (odd 0x80-0xBF) */
#define GG_PORT_JOY_A          0xDC    /* joypad port A */
#define GG_PORT_JOY_B          0xDD    /* joypad port B / misc */

/* Writing */
#define GG_PORT_PSG            0x7F    /* SN76489 PSG write */
#define GG_PORT_MEMORY_CTRL    0x3E    /* memory control */
#define GG_PORT_IO_CTRL        0x3F    /* I/O control / nationalization */
#define GG_PORT_FM_REG         0xF0    /* YM2413 FM register (stub) */
#define GG_PORT_FM_DATA        0xF1    /* YM2413 FM data (stub) */
#define GG_PORT_FM_DETECT      0xF2    /* FM detection */

/* ------------------------------------------------------------------ */
/* GG joypad bit layout (active-low in GG, active-high from 32X)     */
/* Port 0xDC returns these bits inverted (1 = not pressed in GG)      */
/* ------------------------------------------------------------------ */

#define GG_PAD_UP      0x01
#define GG_PAD_DOWN    0x02
#define GG_PAD_LEFT    0x04
#define GG_PAD_RIGHT   0x08
#define GG_PAD_B1      0x10    /* button 1 (fire / B on 32X) */
#define GG_PAD_B2      0x20    /* button 2 (C on 32X) */

/* ------------------------------------------------------------------ */
/* Function declarations (implemented in gg_io.c)                     */
/* ------------------------------------------------------------------ */

uint8_t gg_in(uint16_t port);
void    gg_out(uint16_t port, uint8_t val);

/* Called once per frame to translate 32X joypad -> GG format */
void    gg_input_update(void);

#endif /* GG_IO_H */
