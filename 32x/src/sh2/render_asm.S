/*
 * render_asm.S - SH-2 assembly GG VDP background renderer
 *
 * void render_bg_line_asm(uint16_t *dst, uint8_t *pri,
 *                         const uint8_t *map_row, int tile_line,
 *                         int map_col, int num_cols,
 *                         const uint16_t *pal_base)
 *
 * void fb_copy_line_asm(volatile uint32_t *dst, const uint32_t *src)
 */

        .section .sdram_code,"ax"

/* ================================================================ */
/* External symbols used by sprite renderer                          */
/* ================================================================ */
        .extern _sat_line_count
        .extern _sat_line_idx
        .extern _tile_cache
        .extern _tile_cache_dirty
        .extern _tile_lut_hi
        .extern _tile_lut_lo
        .extern _gg_vram
        .extern _gg_palette_32x
        .extern _g_machine
        .extern _sms
        .extern _tile_row_scratch

/* ================================================================ */
/* render_bg_line_asm                                                 */
/*                                                                    */
/* R4 = dst (uint16_t *, advances each column by 16 bytes)            */
/* R5 = priority_buf (uint8_t *, advances by 8)                       */
/* R6 = map_row (const uint8_t * - name table row base pointer)       */
/* R7 = tile_line (0-7, row within tile)                              */
/* @(32+0, sp) = map_col (starting column, 0-31)                      */
/* @(32+4, sp) = num_cols (usually 32)                                */
/* @(32+8, sp) = pal_base (gg_palette_32x)                           */
/* ================================================================ */
        .align 2
        .global _render_bg_line_asm

_render_bg_line_asm:
        /* Save callee-saved registers (8 regs = 32 bytes) */
        mov.l   r8, @-r15
        mov.l   r9, @-r15
        mov.l   r10, @-r15
        mov.l   r11, @-r15
        mov.l   r12, @-r15
        mov.l   r13, @-r15
        mov.l   r14, @-r15
        sts.l   pr, @-r15

        /* Stack args at sp + 32 + offset */
        mov.l   @(32, r15), r10   /* r10 = map_col */
        mov.l   @(36, r15), r14   /* r14 = num_cols */
        mov.l   @(40, r15), r12   /* r12 = pal_base */

        /* Persistent registers:
         * r9  = map_row
         * r10 = map_col (advances each column)
         * r12 = pal_base
         * r13 = tile_row_scratch cursor (advances +4 per column)
         * r14 = num_cols (countdown)
         * Prefetch has already consumed tile_line. */
        mov.l   .Lp_scratch, r13   /* r13 = tile_row_scratch */
        mov     r6, r9              /* r9 = map_row */

/* ================================================================ */
/* Column loop — reads tile bytes from prefetch scratch buffer         */
/*                                                                     */
/* Per-column register allocation during LUT decode:                   */
/*   r3  = tile_word (stashed, extracted at .Ltile_ready)              */
/*   r11 = bp0*4     r2 = bp1*4     r6 = bp2*4     r8 = bp3*4        */
/*   r7  = hi accumulator   r11 = lo accumulator                      */
/*   r0, r1 = scratch for address computation                          */
/*                                                                     */
/* Precomputed LUT+plane literals eliminate per-plane base+offset ADD  */
/* Load-use stalls hidden by interleaving literal loads between planes */
/* bf/s loop exit saves 1 cycle/tile vs bt+bra pair                   */
/* ================================================================ */
        .align 4              /* 16-byte cache line alignment */
.Lcol_loop:
        /* Read name table entry: map_row[(map_col & 31) * 2] */
        mov     r10, r0
        and     #31, r0
        shll    r0              /* (map_col & 31) * 2 */
        mov     r9, r1
        add     r0, r1          /* r1 = &entry */
        mov.b   @r1+, r2        /* r2 = lo byte, r1 -> hi byte */
        mov.b   @r1, r0         /* r0 = hi byte (no stall on r1 post-inc) */
        extu.b  r2, r2          /* extend lo (fills r0 load-use gap) */
        extu.b  r0, r0          /* extend hi (r0 ready, no stall) */
        shll8   r0
        or      r2, r0          /* r0 = tile_word */

        /* Stash tile_word in r3 (freed from LUT base duty by precomputed literals) */
        mov     r0, r3

        /* Load 4 prefetched VRAM bytes from scratch:
         * Packed format: bits[31:24]=bp3, [23:16]=bp2, [15:8]=bp1, [7:0]=bp0 */
        mov.l   @r13+, r1      /* r1 = packed; r13 advances +4 */

        /* Extract bitplane bytes and pre-shift to *4 for LUT indexing.
         * Destinations chosen to survive the LUT decode passes:
         *   r11 = bp0*4   r2 = bp1*4   r6 = bp2*4   r8 = bp3*4       */
        extu.b  r1, r11         /* r11 = bp0 */
        shll2   r11             /* r11 = bp0 * 4 */
        mov     r1, r2
        shlr8   r2
        extu.b  r2, r2          /* r2 = bp1 */
        shll2   r2              /* r2 = bp1 * 4 */
        mov     r1, r6
        shlr16  r6
        extu.b  r6, r6          /* r6 = bp2 */
        shll2   r6              /* r6 = bp2 * 4 */
        mov     r1, r8
        shlr16  r8
        shlr8   r8
        extu.b  r8, r8          /* r8 = bp3 */
        shll2   r8              /* r8 = bp3 * 4 */

        /* ---- Build hi word: precomputed LUT+plane addresses, interleaved ---- */

        /* plane 0: lut_hi[0 + bp0*4] */
        mov.l   .Lp_hi_0, r1
        add     r11, r1
        mov.l   @r1, r7         /* r7 = lut_hi[0][bp0] (no stall: r7 not used next) */

        /* plane 1: lut_hi[1024 + bp1*4] */
        mov.l   .Lp_hi_1024, r1
        add     r2, r1
        mov.l   @r1, r0
        mov.l   .Lp_hi_2048, r1 /* interleave: start plane 2 (hides r0 stall) */
        or      r0, r7

        /* plane 2: lut_hi[2048 + bp2*4] (addr started above) */
        add     r6, r1
        mov.l   @r1, r0
        mov.l   .Lp_hi_3072, r1 /* interleave: start plane 3 (hides r0 stall) */
        or      r0, r7

        /* plane 3: lut_hi[3072 + bp3*4] (addr started above) */
        add     r8, r1
        mov.l   @r1, r0
        mov.l   .Lp_lo_0, r1    /* interleave: start lo plane 0 (hides r0 stall) */
        or      r0, r7          /* r7 = hi complete */

        /* ---- Build lo word: precomputed LUT+plane addresses, interleaved ---- */

        /* plane 0: lut_lo[0 + bp0*4] (addr started from hi plane 3 interleave) */
        add     r11, r1
        mov.l   @r1, r11        /* r11 = lo accum start (bp0 consumed, no stall next) */

        /* plane 1: lut_lo[1024 + bp1*4] */
        mov.l   .Lp_lo_1024, r1
        add     r2, r1
        mov.l   @r1, r0
        mov.l   .Lp_lo_2048, r1 /* interleave: start plane 2 (hides r0 stall) */
        or      r0, r11

        /* plane 2: lut_lo[2048 + bp2*4] (addr started above) */
        add     r6, r1
        mov.l   @r1, r0
        mov.l   .Lp_lo_3072, r1 /* interleave: start plane 3 (hides r0 stall) */
        or      r0, r11

        /* plane 3: lut_lo[3072 + bp3*4] (addr started above) */
        add     r8, r1
        mov.l   @r1, r0
        mov     r3, r2          /* tile_word → r2 (hides r0 load-use stall) */
        or      r0, r11         /* r11 = lo complete */

        bra     .Ltile_ready
        mov     r2, r0          /* delay slot: r0 = tile_word for h_flip extract */

/* ---- Literal pool 1 (precomputed LUT+plane offset addresses) ---- */
        .align 2
.Lp_scratch:
        .long   _tile_row_scratch
.Lp_hi_0:
        .long   _tile_lut_hi
.Lp_hi_1024:
        .long   _tile_lut_hi + 1024
.Lp_hi_2048:
        .long   _tile_lut_hi + 2048
.Lp_hi_3072:
        .long   _tile_lut_hi + 3072
.Lp_lo_0:
        .long   _tile_lut_lo
.Lp_lo_1024:
        .long   _tile_lut_lo + 1024
.Lp_lo_2048:
        .long   _tile_lut_lo + 2048
.Lp_lo_3072:
        .long   _tile_lut_lo + 3072

.Ltile_ready:
        /* r7 = hi (packed pixels 0-3), r11 = lo (packed pixels 4-7)
         * r2 = tile_word, r0 = tile_word (from bra delay slot)
         */

        /* h_flip = (tile_word >> 9) & 1  (r0 set in delay slot) */
        shlr8   r0
        shlr    r0
        and     #1, r0
        mov     r0, r6          /* r6 = h_flip */

        /* palette_sel = (tile_word >> 11) & 1, offset = sel * 32 */
        mov     r2, r0
        shlr8   r0
        shlr2   r0
        shlr    r0
        and     #1, r0
        shll2   r0
        shll2   r0
        shll    r0              /* r0 = palette_sel * 32 */
        mov     r12, r1
        add     r0, r1          /* r1 = palette ptr */

        /* priority = (tile_word >> 12) & 1 */
        mov     r2, r0
        shlr8   r0
        shlr2   r0
        shlr2   r0
        and     #1, r0          /* r0 = priority */

        /* Use r8 temporarily for palette (restore gg_vram at col end) */
        mov     r1, r8          /* r8 = palette ptr */
        mov     r0, r2          /* r2 = priority */

        tst     r6, r6
        bf      .Lhflip

/* ---- Normal order: 16-bit pixel writes, indexed palette, interleaved ---- */
/* Uses mov.w stores (not mov.l) to avoid SH-2 address-error exceptions    */
/* when the destination buffer is not 4-byte aligned (odd fine_x scroll).  */

        /* --- Pixel 0: hi >> 24 --- */
        mov     r7, r0
        shlr16  r0
        shlr8   r0
        extu.b  r0, r0
        mov     r0, r6          /* save idx for priority */
        shll    r0
        mov.w   @(r0, r8), r1   /* r1 = color0 */
        tst     r6, r6
        movt    r0
        xor     #1, r0
        and     r2, r0
        mov.b   r0, @r5
        mov.w   r1, @r4
        add     #2, r4

        /* --- Pixel 1: (hi >> 16) & 0xFF --- */
        mov     r7, r0
        shlr16  r0
        extu.b  r0, r0
        mov     r0, r6
        shll    r0
        mov.w   @(r0, r8), r1   /* r1 = color1 */
        tst     r6, r6
        movt    r0
        xor     #1, r0
        and     r2, r0
        mov.b   r0, @(1, r5)
        mov.w   r1, @r4
        add     #2, r4

        /* --- Pixel 2: (hi >> 8) & 0xFF --- */
        mov     r7, r0
        shlr8   r0
        extu.b  r0, r0
        mov     r0, r6
        shll    r0
        mov.w   @(r0, r8), r1   /* r1 = color2 */
        tst     r6, r6
        movt    r0
        xor     #1, r0
        and     r2, r0
        mov.b   r0, @(2, r5)
        mov.w   r1, @r4
        add     #2, r4

        /* --- Pixel 3: hi & 0xFF --- */
        mov     r7, r0
        extu.b  r0, r0
        mov     r0, r6
        shll    r0
        mov.w   @(r0, r8), r1   /* r1 = color3 */
        tst     r6, r6
        movt    r0
        xor     #1, r0
        and     r2, r0
        mov.b   r0, @(3, r5)
        mov.w   r1, @r4
        add     #2, r4

        /* --- Pixel 4: lo >> 24 --- */
        mov     r11, r0
        shlr16  r0
        shlr8   r0
        extu.b  r0, r0
        mov     r0, r6
        shll    r0
        mov.w   @(r0, r8), r1   /* r1 = color4 */
        tst     r6, r6
        movt    r0
        xor     #1, r0
        and     r2, r0
        mov.b   r0, @(4, r5)
        mov.w   r1, @r4
        add     #2, r4

        /* --- Pixel 5: (lo >> 16) & 0xFF --- */
        mov     r11, r0
        shlr16  r0
        extu.b  r0, r0
        mov     r0, r6
        shll    r0
        mov.w   @(r0, r8), r1   /* r1 = color5 */
        tst     r6, r6
        movt    r0
        xor     #1, r0
        and     r2, r0
        mov.b   r0, @(5, r5)
        mov.w   r1, @r4
        add     #2, r4

        /* --- Pixel 6: (lo >> 8) & 0xFF --- */
        mov     r11, r0
        shlr8   r0
        extu.b  r0, r0
        mov     r0, r6
        shll    r0
        mov.w   @(r0, r8), r1   /* r1 = color6 */
        tst     r6, r6
        movt    r0
        xor     #1, r0
        and     r2, r0
        mov.b   r0, @(6, r5)
        mov.w   r1, @r4
        add     #2, r4

        /* --- Pixel 7: lo & 0xFF --- */
        mov     r11, r0
        extu.b  r0, r0
        mov     r0, r6
        shll    r0
        mov.w   @(r0, r8), r1   /* r1 = color7 */
        tst     r6, r6
        movt    r0
        xor     #1, r0
        and     r2, r0
        mov.b   r0, @(7, r5)
        mov.w   r1, @r4
        add     #2, r4

        bra     .Lcol_done
        nop

.Lhflip:
        /* Reversed order: 16-bit pixel writes, indexed palette, interleaved */

        /* --- Pixel 0: lo & 0xFF --- */
        mov     r11, r0
        extu.b  r0, r0
        mov     r0, r6
        shll    r0
        mov.w   @(r0, r8), r1   /* r1 = color0 */
        tst     r6, r6
        movt    r0
        xor     #1, r0
        and     r2, r0
        mov.b   r0, @r5
        mov.w   r1, @r4
        add     #2, r4

        /* --- Pixel 1: (lo >> 8) & 0xFF --- */
        mov     r11, r0
        shlr8   r0
        extu.b  r0, r0
        mov     r0, r6
        shll    r0
        mov.w   @(r0, r8), r1   /* r1 = color1 */
        tst     r6, r6
        movt    r0
        xor     #1, r0
        and     r2, r0
        mov.b   r0, @(1, r5)
        mov.w   r1, @r4
        add     #2, r4

        /* --- Pixel 2: (lo >> 16) & 0xFF --- */
        mov     r11, r0
        shlr16  r0
        extu.b  r0, r0
        mov     r0, r6
        shll    r0
        mov.w   @(r0, r8), r1   /* r1 = color2 */
        tst     r6, r6
        movt    r0
        xor     #1, r0
        and     r2, r0
        mov.b   r0, @(2, r5)
        mov.w   r1, @r4
        add     #2, r4

        /* --- Pixel 3: lo >> 24 --- */
        mov     r11, r0
        shlr16  r0
        shlr8   r0
        extu.b  r0, r0
        mov     r0, r6
        shll    r0
        mov.w   @(r0, r8), r1   /* r1 = color3 */
        tst     r6, r6
        movt    r0
        xor     #1, r0
        and     r2, r0
        mov.b   r0, @(3, r5)
        mov.w   r1, @r4
        add     #2, r4

        /* --- Pixel 4: hi & 0xFF --- */
        mov     r7, r0
        extu.b  r0, r0
        mov     r0, r6
        shll    r0
        mov.w   @(r0, r8), r1   /* r1 = color4 */
        tst     r6, r6
        movt    r0
        xor     #1, r0
        and     r2, r0
        mov.b   r0, @(4, r5)
        mov.w   r1, @r4
        add     #2, r4

        /* --- Pixel 5: (hi >> 8) & 0xFF --- */
        mov     r7, r0
        shlr8   r0
        extu.b  r0, r0
        mov     r0, r6
        shll    r0
        mov.w   @(r0, r8), r1   /* r1 = color5 */
        tst     r6, r6
        movt    r0
        xor     #1, r0
        and     r2, r0
        mov.b   r0, @(5, r5)
        mov.w   r1, @r4
        add     #2, r4

        /* --- Pixel 6: (hi >> 16) & 0xFF --- */
        mov     r7, r0
        shlr16  r0
        extu.b  r0, r0
        mov     r0, r6
        shll    r0
        mov.w   @(r0, r8), r1   /* r1 = color6 */
        tst     r6, r6
        movt    r0
        xor     #1, r0
        and     r2, r0
        mov.b   r0, @(6, r5)
        mov.w   r1, @r4
        add     #2, r4

        /* --- Pixel 7: hi >> 24 --- */
        mov     r7, r0
        shlr16  r0
        shlr8   r0
        extu.b  r0, r0
        mov     r0, r6
        shll    r0
        mov.w   @(r0, r8), r1   /* r1 = color7 */
        tst     r6, r6
        movt    r0
        xor     #1, r0
        and     r2, r0
        mov.b   r0, @(7, r5)
        mov.w   r1, @r4
        add     #2, r4

.Lcol_done:
        /* Advance pointers (dst already advanced +16 by pixel emission) */
        add     #8, r5          /* pri += 8 */

        dt      r14
        add     #1, r10         /* map_col++ (applies on both loop/exit paths) */
        bf      .Lcol_continue

        /* Epilogue */
        lds.l   @r15+, pr
        mov.l   @r15+, r14
        mov.l   @r15+, r13
        mov.l   @r15+, r12
        mov.l   @r15+, r11
        mov.l   @r15+, r10
        mov.l   @r15+, r9
        mov.l   @r15+, r8
        rts
        nop

/* Long-hop loop back keeps short conditional branch in range. */
.Lcol_continue:
        bra     .Lcol_loop
        nop

/* ---- Literal pool 2 (empty — gg_vram no longer needed in BG loop) ---- */

/* ================================================================ */
/* prefetch_tile_row_asm                                              */
/*                                                                    */
/* void prefetch_tile_row_asm(                                        */
/*     const uint8_t *map_row,   R4  — name table row (64 bytes)     */
/*     const uint8_t *vram_base, R5  — gg_vram[0]                   */
/*     int            tile_line, R6  — row within tile (0-7)          */
/*     int            map_col,   R7  — starting column (0-31)         */
/*     int            num_cols,  @(sp+0) before prolog / @(sp+8) after*/
/*     uint8_t       *out)       @(sp+4) before prolog / @(sp+12) after*/
/*                                                                    */
/* For each column: reads the name table entry, computes the VRAM     */
/* address for that tile row, copies 4 bytes (2 bitplanes) into out. */
/* Result: 128-byte scratch buffer populated with raw tile row data.  */
/*                                                                    */
/* Register allocation (callee-saved: r8, r9 only):                  */
/*   r4 = map_row (const, not modified)                               */
/*   r5 = vram_base (const, not modified)                             */
/*   r6 = tile_line (const, not modified)                             */
/*   r7 = map_col (advances each iteration, wraps via &31)            */
/*   r8 = num_cols (countdown, decremented with dt)                   */
/*   r9 = out_ptr  (output cursor, advances +4 each column)           */
/* ================================================================ */
        .align 2
        .global _prefetch_tile_row_asm

_prefetch_tile_row_asm:
        /* Minimal prolog: save r8, r9 only (2 pushes = 8 bytes) */
        mov.l   r8, @-r15
        mov.l   r9, @-r15
        sts.l   pr, @-r15

        /* Load stack args (sp+12 = num_cols, sp+16 = out after 3 pushes) */
        mov.l   @(12, r15), r8    /* r8 = num_cols */
        mov.l   @(16, r15), r9    /* r9 = out_ptr */

.Lpfetch_loop:
        /* Compute map entry offset: (map_col & 31) * 2 */
        mov     r7, r0
        and     #31, r0
        shll    r0                /* r0 = (map_col & 31) * 2 */

        /* Read name table lo/hi bytes */
        mov     r4, r1
        add     r0, r1            /* r1 = &map_row[offset] */
        mov.b   @r1+, r2          /* r2 = lo byte */
        mov.b   @r1, r3           /* r3 = hi byte */
        extu.b  r2, r2
        extu.b  r3, r3

        /* tile_n = (hi & 1) << 8 | lo */
        mov     r3, r0
        and     #1, r0
        shll8   r0
        or      r2, r0            /* r0 = tile_n (0..511) */
        mov     r0, r2            /* r2 = tile_n  (save now — v_flip will overwrite r0) */

        /* v_flip = (hi >> 2) & 1 */
        mov     r3, r0
        shlr2   r0
        and     #1, r0            /* r0 = v_flip */
        mov     r0, r1            /* r1 = v_flip */

        /* row = v_flip ? (7 - tile_line) : tile_line */
        tst     r1, r1
        bt/s    .Lpfetch_novf
        mov     #7, r1
        sub     r6, r1            /* r1 = 7 - tile_line */
        bra     .Lpfetch_vf_done
        nop
.Lpfetch_novf:
        mov     r6, r1            /* r1 = tile_line */
.Lpfetch_vf_done:

        /* vram_ptr = vram_base + tile_n * 32 + row * 4
         * r2 = tile_n (saved above), r1 = row
         * tile_n * 32 = tile_n << 5
         * row * 4     = row << 2                        */
        shll2   r2                /* r2 = tile_n * 4 */
        shll2   r2                /* r2 = tile_n * 16 */
        shll    r2                /* r2 = tile_n * 32 */
        mov     r1, r3
        shll2   r3                /* r3 = row * 4 */
        add     r3, r2            /* r2 = tile_n*32 + row*4 */
        add     r5, r2            /* r2 = vram_ptr */

        /* Copy 4 bytes from VRAM to scratch buffer using mov.l
         * VRAM is 8-bit port on 32X, but we alias as 32-bit aligned
         * since tile data starts at tile_n*32 (always 4-byte aligned).
         * Use 4 individual byte loads to avoid SH-2 alignment trap. */
        mov.b   @r2+, r0
        mov.b   @r2+, r1
        mov.b   @r2+, r3
        extu.b  r0, r0
        mov.b   @r2, r2
        extu.b  r1, r1
        extu.b  r3, r3
        extu.b  r2, r2
        shll8   r1
        shll16  r3
        or      r1, r0
        shll8   r2
        shll16  r2                /* r2 = bp3 << 24 */
        or      r3, r0
        or      r2, r0            /* r0 = (bp0<<24)|(bp1<<16)|(bp2<<8)|bp3 */

        /* Store 4 bytes to scratch buffer */
        mov.l   r0, @r9
        add     #4, r9

        /* Advance map_col and loop */
        dt      r8
        bf/s    .Lpfetch_loop
        add     #1, r7

        /* Epilog */
        lds.l   @r15+, pr
        mov.l   @r15+, r9
        mov.l   @r15+, r8
        rts
        nop

/* ================================================================ */
/* render_sprites_line_asm  (SH-2, 32X slave — GG-only)               */
/*                                                                    */
/* void render_sprites_line_asm(                                      */
/*     uint16_t       *dst,          R4                               */
/*     const uint8_t  *priority_buf, R5                               */
/*     int             line,         R6                               */
/*     int             sprite_height,R7  (8 or 16)                    */
/*     const uint8_t  *sat,          @sp+0                            */
/*     const uint16_t *pal,          @sp+4                            */
/*     int             clip_x_min,   @sp+8                            */
/*     int             clip_x_max,   @sp+12                           */
/*     int             shift_x,      @sp+16                           */
/*     int             pat_gen_idx)  @sp+20                           */
/*                                                                    */
/* GG-optimized: handles 8x8 and 8x16 sprites natively.              */
/* No doubled sprite support. Pixel emission fully inlined.           */
/*                                                                    */
/* Callee-saved register assignment:                                  */
/*   R8  = dst                                                        */
/*   R9  = priority_buf                                               */
/*   R10 = sprite palette base                                        */
/*   R11 = line                                                       */
/*   R12 = gg_vram base                                              */
/*   R13 = sat base                                                   */
/*   R14 = sprite loop counter (count-1 downto 0)                    */
/*                                                                    */
/* Stack frame after prologue (36 bytes):                             */
/*   sp+0  = sprite_height                                            */
/*   sp+36 = sat                                                      */
/*   sp+40 = pal                                                      */
/*   sp+44 = clip_x_min                                               */
/*   sp+48 = clip_x_max                                               */
/*   sp+52 = shift_x                                                  */
/*   sp+56 = pat_gen_idx                                              */
/* ================================================================ */

/* -------------------------------------------------------------- */
/* SPIX macro: inline single sprite pixel emission                 */
/*                                                                  */
/* src   — register holding packed pixel data (r5=hi or r6=lo)     */
/* stype — shift type: 0=>>24, 1=>>16, 2=>>8, 3=none              */
/* pxoff — pixel X offset from base (0-7)                          */
/*                                                                  */
/* Inputs (set before first SPIX in a group):                       */
/*   r2  = sprite base X                                            */
/*   r3  = clip_x_min                                               */
/*   r4  = clip_x_max                                               */
/*   r8  = dst, r9 = priority_buf, r10 = sprite palette             */
/* Clobbers: r0, r1, r7                                             */
/* -------------------------------------------------------------- */
.macro SPIX src, stype, pxoff
        mov     \src, r0
.if \stype == 0
        shlr16  r0
        shlr8   r0
.elseif \stype == 1
        shlr16  r0
.elseif \stype == 2
        shlr8   r0
.endif
        extu.b  r0,  r0
        tst     r0,  r0
        bt      .Lsk\@
        mov     r0,  r7
        mov     r2,  r1
.if \pxoff != 0
        add     #\pxoff, r1
.endif
        cmp/ge  r3,  r1
        bf      .Lsk\@
        cmp/ge  r4,  r1
        bt      .Lsk\@
        mov     r1,  r0
        mov.b   @(r0, r9), r0
        tst     r0,  r0
        bf      .Lsk\@
        shll    r7
        mov     r7,  r0
        mov.w   @(r0, r10), r0
        shll    r1
        add     r8,  r1
        mov.w   r0,  @r1
.Lsk\@:
.endm

        .align 2
        .global _render_sprites_line_asm

_render_sprites_line_asm:
        /* Prologue: save callee-saved + PR (8 pushes = 32 bytes) */
        mov.l   r8,  @-r15
        mov.l   r9,  @-r15
        mov.l   r10, @-r15
        mov.l   r11, @-r15
        mov.l   r12, @-r15
        mov.l   r13, @-r15
        mov.l   r14, @-r15
        sts.l   pr,  @-r15

        /* Set up callee-saved regs */
        mov     r4,  r8          /* R8  = dst */
        mov     r5,  r9          /* R9  = priority_buf */
        mov     r6,  r11         /* R11 = line */
        mov.l   .Lsp_vram, r12   /* R12 = gg_vram */
        mov.l   @(32, r15), r13  /* R13 = sat */
        mov.l   @(36, r15), r10  /* R10 = sprite palette */

        /* Push sprite_height as local (4 bytes → frame 36 total) */
        mov.l   r7,  @-r15       /* sp+0 = sprite_height */

        /* count = sat_line_count[line]; exit if 0 */
        mov.l   .Lsp_lcount, r1
        mov     r11, r0
        add     r1,  r0
        mov.b   @r0, r0
        extu.b  r0,  r0
        tst     r0,  r0
        bf      .Lsp_have_sprites
        bra     .Lsp_exit
        nop

.Lsp_have_sprites:

        /* Clamp count to 8 (hardware max) */
        mov     #8,  r1
        cmp/hi  r1,  r0
        bf      .Lsp_cntok
        mov     r1,  r0
.Lsp_cntok:
        mov     r0,  r14         /* R14 = count (iterate back-to-front) */

/* ============================================================ */
/* Sprite loop                                                    */
/* ============================================================ */
        .align 4              /* 16-byte cache line alignment */
.Lsp_loop:
        add     #-1, r14         /* next index: count-1 down to 0 */
        /* sprite_idx = sat_line_idx[line * 8 + r14] */
        mov.l   .Lsp_lidx, r2
        mov     r11, r0
        shll2   r0
        shll    r0               /* r0 = line * 8 */
        add     r14, r0
        add     r2,  r0
        mov.b   @r0, r0
        extu.b  r0,  r0          /* r0 = sprite_idx (0..63) */
        mov     r0,  r3          /* r3 = sprite_idx (saved) */

        /* Y = sat[idx]; if Y > 224: Y -= 256 */
        mov     r0,  r1
        add     r13, r1
        mov.b   @r1, r1
        extu.b  r1,  r1          /* r1 = Y */
        mov     #-32, r0
        extu.b  r0,  r0          /* r0 = 224 */
        cmp/hi  r0,  r1          /* Y > 224? */
        bf      .Lsp_noyw
        mov.l   .Lsp_n256, r0
        add     r0,  r1
.Lsp_noyw:
        /* sy = line - Y - 1 */
        mov     r11, r2
        sub     r1,  r2
        add     #-1, r2          /* r2 = sy */
        cmp/pz  r2
        bf      .Lsp_skip
        mov.l   @r15, r5         /* sprite_height */
        cmp/ge  r5,  r2
        bt      .Lsp_skip        /* sy >= sprite_height → skip */

        /* X = sat[0x80 + idx*2] - shift_x */
        mov     r3,  r0
        shll    r0               /* idx * 2 */
        mov     #-128, r4
        extu.b  r4,  r4          /* r4 = 0x80 */
        add     r4,  r0
        add     r13, r0
        mov.b   @r0, r1
        extu.b  r1,  r1
        mov.l   @(52, r15), r0   /* shift_x */
        sub     r0,  r1          /* r1 = x */

        /* tile_n = sat[0x80 + idx*2 + 1] | pat_gen_idx */
        mov     r3,  r0
        shll    r0
        add     r4,  r0
        add     r13, r0
        mov.b   @(1, r0), r0
        extu.b  r0,  r0
        mov.l   @(56, r15), r4   /* pat_gen_idx */
        or      r4,  r0          /* r0 = tile_n */

        /* --- 8x16 mode: if sprite_height == 16 --- */
        mov     #16, r7
        cmp/eq  r7,  r5
        bf      .Lsp_not816
        /* tile_n &= ~1 */
        mov     #-2, r4
        and     r4,  r0
        /* if sy >= 8: tile_n++, sy -= 8 */
        mov     #8,  r4
        cmp/ge  r4,  r2
        bf      .Lsp_not816
        add     #1,  r0
        add     #-8, r2
.Lsp_not816:
        /* r0 = tile_n (adjusted), r1 = x, r2 = sy (adjusted) */

        /* Quick clip: skip if x+8 <= clip_min or x >= clip_max */
        mov.l   @(44, r15), r4   /* clip_x_min */
        mov     r1,  r5
        add     #8,  r5
        cmp/ge  r4,  r5          /* (x+8) >= clip_min? */
        bf      .Lsp_skip
        mov.l   @(48, r15), r4   /* clip_x_max */
        cmp/ge  r4,  r1          /* x >= clip_max? */
        bt      .Lsp_skip

        /* Push x and cache_idx for later use by emit and cache store */
        /* tile_data_offset = tile_n*32 + sy*4 ;  cache_idx = offset/4 */
        mov     r0,  r4          /* save tile_n */
        shll2   r4
        shll2   r4
        shll    r4               /* r4 = tile_n * 32 */
        mov     r2,  r7
        shll2   r7               /* r7 = sy * 4 */
        add     r7,  r4          /* r4 = tile_data_offset */
        mov     r4,  r7
        shlr2   r7               /* r7 = cache_idx */
        mov.l   r1,  @-r15       /* push x */
        mov.l   r7,  @-r15       /* push cache_idx */
        /* sp+0=cache_idx  sp+4=x  sp+8=sprite_height
         * sp+44+8=sat sp+52+8=clip_min sp+56+8=clip_max ... */

        /* Check tile_cache_dirty[cache_idx] */
        mov.l   .Lsp_tcd, r2
        add     r7,  r2
        mov.b   @r2, r2
        extu.b  r2,  r2
        tst     r2,  r2
        bf      .Lsp_cmiss

        /* === Cache hit: load hi/lo === */
        mov     r7,  r2
        shll    r2
        shll2   r2               /* cache_idx * 8 */
        mov.l   .Lsp_tc, r3
        add     r2,  r3
        mov.l   @r3, r5          /* r5 = hi */
        add     #4,  r3
        mov.l   @r3, r6          /* r6 = lo */
        bra     .Lsp_emit
        nop

/* ---- skip trampoline (reachable by bt/bf from Y/X checks) ---- */
.Lsp_skip:
        bra     .Lsp_next
        nop

/* ---- literal pool 1 (general refs within 1020B) ---- */
        .align 2
.Lsp_vram:
        .long   _gg_vram
.Lsp_lcount:
        .long   _sat_line_count
.Lsp_lidx:
        .long   _sat_line_idx
.Lsp_n256:
        .long   -256
.Lsp_tcd:
        .long   _tile_cache_dirty
.Lsp_tc:
        .long   _tile_cache

/* === Cache miss: decode tile row from 4 bitplanes === */
.Lsp_cmiss:
        /* r4 = tile_data_offset (still in r4 from before push) */
        add     r12, r4          /* r4 = &gg_vram[offset] */
        mov.b   @r4+, r2
        mov.b   @r4+, r3
        extu.b  r2,  r2          /* bp0 */
        mov.b   @r4+, r0
        extu.b  r3,  r3          /* bp1 */
        mov.b   @r4,  r1
        extu.b  r0,  r0          /* bp2 */
        extu.b  r1,  r1          /* bp3 */
        /* r2=bp0 r3=bp1 r0=bp2 r1=bp3 */
        mov     r0,  r4          /* r4 = bp2 (free r0 for indexed loads) */

        /* Build hi word — r0 must be offset for @(r0, Rn) */
        mov.l   .Lsp_lhi, r6
        mov     r2,  r0
        shll2   r0               /* r0 = bp0 * 4 */
        mov.l   @(r0, r6), r7   /* r7 = lut_hi[0][bp0] */

        mov.l   .Lsp_lhi1, r6
        mov     r3,  r0
        shll2   r0
        add     r0,  r6
        mov.l   @r6, r0
        or      r0,  r7

        mov.l   .Lsp_lhi2, r6
        mov     r4,  r0
        shll2   r0
        add     r0,  r6
        mov.l   @r6, r0
        or      r0,  r7

        mov.l   .Lsp_lhi3, r6
        mov     r1,  r0
        shll2   r0
        add     r0,  r6
        mov.l   @r6, r0
        or      r0,  r7          /* r7 = hi complete */

        /* Build lo word (accumulate in r5) */
        mov.l   .Lsp_llo, r6
        mov     r2,  r0
        shll2   r0
        mov.l   @(r0, r6), r5   /* r5 = lut_lo[0][bp0] */

        mov.l   .Lsp_llo1, r6
        mov     r3,  r0
        shll2   r0
        add     r0,  r6
        mov.l   @r6, r0
        or      r0,  r5

        mov.l   .Lsp_llo2, r6
        mov     r4,  r0
        shll2   r0
        add     r0,  r6
        mov.l   @r6, r0
        or      r0,  r5

        mov.l   .Lsp_llo3, r6
        mov     r1,  r0
        shll2   r0
        add     r0,  r6
        mov.l   @r6, r0
        or      r0,  r5          /* r5 = lo complete */

        /* Store to tile_cache[cache_idx] and clear dirty */
        mov.l   @r15, r0         /* cache_idx */
        mov     r0,  r2
        shll    r2
        shll2   r2               /* cache_idx * 8 */
        mov.l   .Lsp_tc2, r3
        add     r2,  r3
        mov.l   r7,  @r3         /* store hi */
        add     #4,  r3
        mov.l   r5,  @r3         /* store lo */
        mov.l   .Lsp_tcd2, r3
        mov.l   @r15, r0         /* cache_idx again */
        add     r0,  r3
        mov     #0,  r0
        mov.b   r0,  @r3

        /* r5 = lo already; move hi from r7 to r5, lo to r6 */
        mov     r5,  r6          /* r6 = lo */
        mov     r7,  r5          /* r5 = hi */
        bra     .Lsp_emit
        nop

/* ---- literal pool 2 (LUT refs, forward from cache miss code) ---- */
        .align 2
.Lsp_lhi:
        .long   _tile_lut_hi
.Lsp_lhi1:
        .long   _tile_lut_hi + 1024
.Lsp_lhi2:
        .long   _tile_lut_hi + 2048
.Lsp_lhi3:
        .long   _tile_lut_hi + 3072
.Lsp_llo:
        .long   _tile_lut_lo
.Lsp_llo1:
        .long   _tile_lut_lo + 1024
.Lsp_llo2:
        .long   _tile_lut_lo + 2048
.Lsp_llo3:
        .long   _tile_lut_lo + 3072
.Lsp_tc2:
        .long   _tile_cache
.Lsp_tcd2:
        .long   _tile_cache_dirty

/* === Inline pixel emission (8 pixels) ===
 * r5 = hi (pixels 0-3, pix0 at bits 31-24)
 * r6 = lo (pixels 4-7, pix4 at bits 31-24)
 * Before calling SPIX: load r2=x, r3=clip_min, r4=clip_max   */
.Lsp_emit:
        mov.l   @(4, r15), r2    /* x (sp+4 after cache_idx push) */
        mov.l   @(52, r15), r3   /* clip_x_min (sp+44+8) */
        mov.l   @(56, r15), r4   /* clip_x_max (sp+48+8) */

        /* pixels 0-3 from hi (r5), pixels 4-7 from lo (r6) */
        SPIX    r5, 0, 0         /* pixel 0: hi>>24 */
        SPIX    r5, 1, 1         /* pixel 1: hi>>16 */
        SPIX    r5, 2, 2         /* pixel 2: hi>>8  */
        SPIX    r5, 3, 3         /* pixel 3: hi&FF  */
        SPIX    r6, 0, 4         /* pixel 4: lo>>24 */
        SPIX    r6, 1, 5         /* pixel 5: lo>>16 */
        SPIX    r6, 2, 6         /* pixel 6: lo>>8  */
        SPIX    r6, 3, 7         /* pixel 7: lo&FF  */

        /* Pop per-sprite locals (cache_idx + x = 8 bytes) */
        add     #8,  r15

.Lsp_next:
        tst     r14, r14
        bt      .Lsp_done_loop

.Lsp_continue_loop:
        bra     .Lsp_loop
        nop

.Lsp_done_loop:

.Lsp_exit:
        add     #4,  r15         /* pop sprite_height */
        lds.l   @r15+, pr
        mov.l   @r15+, r14
        mov.l   @r15+, r13
        mov.l   @r15+, r12
        mov.l   @r15+, r11
        mov.l   @r15+, r10
        mov.l   @r15+, r9
        mov.l   @r15+, r8
        rts
        nop


/* ================================================================ */
        .align 2
        .global _fb_copy_line_asm

_fb_copy_line_asm:
        mov     #16, r6         /* 16 groups of 8 = 128 longwords */
.Lfb_loop:
        /* Batch 1: load 4 longwords, then store 4 (hides load-use stalls) */
        mov.l   @r5+, r0
        mov.l   @r5+, r1
        mov.l   @r5+, r2
        mov.l   @r5+, r3
        mov.l   r0, @r4
        add     #4, r4
        mov.l   r1, @r4
        add     #4, r4
        mov.l   r2, @r4
        add     #4, r4
        mov.l   r3, @r4
        add     #4, r4
        /* Batch 2: load 4 longwords, then store 4 */
        mov.l   @r5+, r0
        mov.l   @r5+, r1
        mov.l   @r5+, r2
        mov.l   @r5+, r3
        mov.l   r0, @r4
        add     #4, r4
        mov.l   r1, @r4
        add     #4, r4
        mov.l   r2, @r4
        add     #4, r4
        mov.l   r3, @r4
        add     #4, r4
        dt      r6
        bf      .Lfb_loop
        rts
        nop

/* ================================================================ */
/* fb_copy_gg_line_asm                                                */
/*                                                                    */
/* void fb_copy_gg_line_asm(volatile uint32_t *dst,                   */
/*                          const uint32_t *src)                      */
/* R4 = dst, R5 = src. Copies 80 longwords (160 pixels).             */
/* ================================================================ */
        .align 2
        .global _fb_copy_gg_line_asm

_fb_copy_gg_line_asm:
        mov     #10, r6         /* 10 groups of 8 = 80 longwords */
.Lfb_gg_loop:
        mov.l   @r5+, r0
        mov.l   @r5+, r1
        mov.l   @r5+, r2
        mov.l   @r5+, r3
        mov.l   r0, @r4
        add     #4, r4
        mov.l   r1, @r4
        add     #4, r4
        mov.l   r2, @r4
        add     #4, r4
        mov.l   r3, @r4
        add     #4, r4
        mov.l   @r5+, r0
        mov.l   @r5+, r1
        mov.l   @r5+, r2
        mov.l   @r5+, r3
        mov.l   r0, @r4
        add     #4, r4
        mov.l   r1, @r4
        add     #4, r4
        mov.l   r2, @r4
        add     #4, r4
        mov.l   r3, @r4
        add     #4, r4
        dt      r6
        bf      .Lfb_gg_loop
        rts
        nop
