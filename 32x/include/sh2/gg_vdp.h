/*
 * gg_vdp.h — GG VDP register bit macros and constants
 *
 * Ported from MEKA vdp.h.  These macros reference the global gg.VDP[]
 * register array from gg_emu.h.
 */

#ifndef GG_VDP_H
#define GG_VDP_H

#include "gg_emu.h"

/* ------------------------------------------------------------------ */
/* VDP Register 0 bits                                                 */
/* ------------------------------------------------------------------ */

#define VDP_REG0_SYNC_DIS       0x01    /* sync disable (unused on GG) */
#define VDP_REG0_M2             0x02    /* mode bit 2 */
#define VDP_REG0_M4             0x04    /* mode bit 4 (1 = Mode 4) */
#define VDP_REG0_SPRITES_SHIFT  0x08    /* shift sprites left 8 pixels */
#define VDP_REG0_HBLANK_EN      0x10    /* H-blank interrupt enable */
#define VDP_REG0_MASK_COL0      0x20    /* mask left 8 pixels with border */
#define VDP_REG0_HSCROLL_LOCK   0x40    /* lock top 2 rows for H-scroll */
#define VDP_REG0_VSCROLL_LOCK   0x80    /* lock right 8 cols for V-scroll */

/* Convenience macros using global gg state */
#define HBlank_ON           (gg.VDP[0] & VDP_REG0_HBLANK_EN)
#define Mask_Left_8         (gg.VDP[0] & VDP_REG0_MASK_COL0)
#define Sprites_Left_8      (gg.VDP[0] & VDP_REG0_SPRITES_SHIFT)
#define HScroll_Lock        (gg.VDP[0] & VDP_REG0_HSCROLL_LOCK)
#define VScroll_Lock        (gg.VDP[0] & VDP_REG0_VSCROLL_LOCK)

/* ------------------------------------------------------------------ */
/* VDP Register 1 bits                                                 */
/* ------------------------------------------------------------------ */

#define VDP_REG1_SPRITE_DBL     0x01    /* double-height sprites */
#define VDP_REG1_SPRITE_8x16    0x02    /* 8×16 sprites (else 8×8) */
#define VDP_REG1_M1             0x08    /* mode bit 1 */
#define VDP_REG1_M3             0x10    /* mode bit 3 (224-line) */
#define VDP_REG1_VBLANK_EN      0x20    /* V-blank interrupt enable */
#define VDP_REG1_DISPLAY_EN     0x40    /* display enable */
#define VDP_REG1_RAM_16K        0x80    /* 16 KB VRAM (always 1 on GG) */

#define VBlank_ON           (gg.VDP[1] & VDP_REG1_VBLANK_EN)
#define Display_ON          (gg.VDP[1] & VDP_REG1_DISPLAY_EN)
#define Sprites_Double      (gg.VDP[1] & VDP_REG1_SPRITE_DBL)
#define Sprites_8x16        (gg.VDP[1] & VDP_REG1_SPRITE_8x16)
#define Wide_Screen_28      (gg.VDP[1] & VDP_REG1_M3)

/* ------------------------------------------------------------------ */
/* VDP Status register bits                                            */
/* ------------------------------------------------------------------ */

#define VDP_STATUS_SPRITE_COLLISION  0x20
#define VDP_STATUS_SPRITE_OVERFLOW   0x40
#define VDP_STATUS_VBLANK            0x80

/* ------------------------------------------------------------------ */
/* VDP register indices                                                */
/* ------------------------------------------------------------------ */

#define VDP_REG_MODE0           0
#define VDP_REG_MODE1           1
#define VDP_REG_NAMETABLE       2
#define VDP_REG_COLORTABLE      3   /* TMS9918 modes only */
#define VDP_REG_PATTERN         4   /* TMS9918 modes only */
#define VDP_REG_SPRITE_ATTR     5
#define VDP_REG_SPRITE_PGEN     6
#define VDP_REG_BORDER_COLOR    7
#define VDP_REG_SCROLL_X        8
#define VDP_REG_SCROLL_Y        9
#define VDP_REG_LINE_COUNTER    10

/* ------------------------------------------------------------------ */
/* Video mode IDs (Mode 4 is the standard GG mode)                    */
/* ------------------------------------------------------------------ */

#define GG_VDP_MODE_0      0   /* TMS9918 graphic 1 */
#define GG_VDP_MODE_1      1   /* TMS9918 text */
#define GG_VDP_MODE_2      2   /* TMS9918 graphic 2 */
#define GG_VDP_MODE_3      3   /* TMS9918 multicolor */
#define GG_VDP_MODE_4      4   /* GG 192-line */
#define GG_VDP_MODE_4_224  5   /* GG 224-line */

/* Dirty-tracking callbacks from gg_render.c */
extern void gg_tile_dirty(uint16_t vram_addr);
extern void gg_cram_dirty(void);

#endif /* GG_VDP_H */
