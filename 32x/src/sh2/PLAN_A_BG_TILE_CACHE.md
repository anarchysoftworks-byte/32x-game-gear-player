# PLAN A — Cached-Word Rewrite of `render_bg_line_asm` (BG tile-row cache)

**Status:** Design finalized, awaiting implementation approval.
**Goal:** Cut BG scanline rendering to ~1 decode per unique (tile_n,row) instead of
per-column, removing the dominant hotspot in the GG render path.

## 0. Recommendation

Implement **Plan A**: a per-(tile_n,row) cache of pre-decoded `hi`/`lo` packed index
words (`bg_tile_cache[idx]`, idx = tile_n*8 + row ∈ [0,4095]) with an independent
validity array `bg_tile_state[idx]`. This is the highest-impact change in this audit:

- BG scanlines are rendered for **all 192 lines/frame** (vs. sprites ≈36 calls), so any
  per-column work there dominates.
- A typical level reuses a handful of tile rows; caching turns ~50–80 decode columns
  into ~5–15 decodes + cache hits, eliminating the LUT-expansion inner loop and prefetch
  entirely from the hot path.
- Correctness is **byte-for-byte identical** to the current path: the C decode helper
  reads the same 4 VRAM bytes and ORs them through the *same* `tile_lut_hi/lo` tables,
  so cached hi/lo words match exactly (verified against render_asm.S:100–172).

## 1. Why BG needs its OWN cache + validity array (not shared with sprites)

Two independent facts rule out reusing the existing sprite `tile_cache` /
`tile_cache_dirty`:

1. **Index-space collision.** Sprite decode computes `cache_idx = (tile_n*32 + sy*4)>>2`
   (render_asm.S:841), which spans the same `[0,4095]` range as BG's `idx = tile_n*8+row`.
   A bg tile and a sprite pattern can share an index.

2. **Render order.** `gg_render_line()` renders BG first (`gg_render.c:552`) then sprites
   (`gg_render.c:558`). If BG reused the shared validity flag, BG would clear it to 0 on
   decode; a colliding sprite read immediately afterward would see "clean" and use an
   un-decoded `tile_cache[idx]` → **sprite corruption**.

Therefore BG gets its own `bg_tile_cache[]` (data) and `bg_tile_state[]` (validity),
invalidated independently. No cross-contamination with sprites.

## 2. Cache key == VRAM address >> 2 (invalidation lines up for free)

prefetch computes, per column: `vram_ptr = tile_n*32 + row*4` where `row = v_flip ? 7-tile_line : tile_line`.
Therefore:

    idx = vram_ptr >> 2 = tile_n*8 + row

This is *exactly* the index that `gg_tile_dirty(vram_addr)` already sets via
`tile_cache_dirty[vram_addr>>2] = 1`. So BG invalidation reuses the existing dirty-store
scaffolding — I add **one byte-store** (`bg_tile_state[addr>>2]=1`) at each of the three
VRAM-write sites that already invalidate `tile_cache_dirty`.
VRAM-write sites that already invalidate `tile_cache_dirty`.

## 3. Memory layout & budget (linker_mars.ld)

- SDRAM: origin 0x06000000, length 0x3D100 (~244 KB). ~62.7 KB free at audit time.
- New arrays (both in .bss, zero-filled by crt0; `bg_tile_state` set to 1 in gg_render_init):

    struct { u32 hi; u32 lo; } bg_tile_cache[4096] __attribute__((aligned(16)));  /* 32 KB */
    uint8_t   bg_tile_state[4096]                 __attribute__((aligned(16)));   /*  4 KB */

  (TILE_CACHE_ENTRIES = 512 name entries × 8 rows = 4096; same size as tile_cache_dirty.)
- Total new: **36,864 bytes (~36 KB)** → ~26 KB free margin. Reuses existing `tile_lut_hi/lo`
  (already in SDRAM) for the decode helper — no extra LUT memory.
- Verify after link; linker will error if .bss overflows the SDRAM window.

## 4. Invalidation sites (3 total — add one store each)

| Site | File:line | Current store | Add |
|------|-----------|---------------|-----|
| A C slow path | gg_render.c `gg_tile_dirty` :187 | `tile_cache_dirty[addr>>2]=1;` | `bg_tile_state[addr>>2]=1;` |
| B OTIR DMA fast path | z80_asm.S ~4069 | `mov.b r6, @(r0,r13)` tile_cache_dirty | store 1 to bg_tile_state[addr>>2] |
| C OUTI/OUTB multi-byte fast path | z80_asm.S ~4403 | tile_cache_dirty store | store 1 to bg_tile_state[addr>>2] |

`bg_tile_state` mirrors `tile_cache_dirty`: declared non-static global in gg_render.c, same
size (TILE_CACHE_ENTRIES=4096), aligned(16). Because sites B/C already load the dirty-array
base into a register (`r13` at z80_asm.S:4016 for OTIR), reuse that base or load
`.Lbg_tile_state_base`; store byte 1 after the existing dirty store.

## 5. Exact code changes

### 5a. gg_render.c — declarations, decode helper, init

```c
/* Background tile-row cache (Plan A). One entry per (tile_n,row); idx=tile_n*8+row. */
typedef struct { uint32_t hi; uint32_t lo; } gg_tile_word_t;
gg_tile_word_t bg_tile_cache[TILE_CACHE_ENTRIES] __attribute__((aligned(16)));  /* 32 KB */
uint8_t        bg_tile_state[TILE_CACHE_ENTRIES] __attribute__((aligned(16)));  /* 4 KB  */

/* Decode one BG tile row into bg_tile_cache[idx]. Byte-identical to the asm LUT
 * expansion (render_asm.S:100–172): reads the same 4 VRAM bytes, ORs through the
 * SAME tile_lut_hi/lo tables. Runs only on cache miss. */
__attribute__((section(".sdram_code")))
void gg_bg_decode(int idx)
{
    int tile_n = idx >> 3;                                  /* = vram_ptr>>5   */
    int row    = idx & 7;                                   /* incl. v_flip    */
    uint8_t *base = gg_vram + (tile_n << 5) + (row << 2);   /* tile_n*32+row*4 */
    uint8_t bp0 = base[0], bp1 = base[1], bp2 = base[2], bp3 = base[3];

    bg_tile_cache[idx].hi = tile_lut_hi[0][bp0] | tile_lut_hi[1][bp1]
                          | tile_lut_hi[2][bp2] | tile_lut_hi[3][bp3];
    bg_tile_cache[idx].lo = tile_lut_lo[0][bp0] | tile_lut_lo[1][bp1]
                          | tile_lut_lo[2][bp2] | tile_lut_lo[3][bp3];

    bg_tile_state[idx] = 0;   /* now valid */
}
```

In `gg_render_init`, alongside the existing `tile_cache_dirty` reset (line ~258–259):

```c
for (int i = 0; i < TILE_CACHE_ENTRIES; i++) {
    tile_cache_dirty[i] = 1;
    bg_tile_state[i] = 1;     /* everything needs decode on first frame */
}
```

### 5b. gg_render.c — `render_background_line`: drop prefetch, pass tile_line

Remove the two `prefetch_tile_row_asm(...)` calls (currently lines ~296–300). BG now reads
name entries + gg_vram directly; it still needs `map_row`, `tile_line`, `map_col`,
`num_cols`, `pal_base` as arguments — keep all of them.

### 5c. render_asm.S — per-column block rewrite (lines ~84–172)

Replace the LUT-expansion block with a cache-load-or-decode:

1. Keep name-entry read (lines 84–95): produces `tile_word`. Extract additionally
   `v_flip = (hi>>2)&1` and `tile_n = lo | ((hi&1)<<8)` for the idx; keep hflip/bit9,
   pal_sel/bit11, pri/bit12 extraction (lines 203–226) unchanged.
2. Capture `tile_line` early into a persistent register right after prologue (it is arg 4 =
   r7 at entry and is clobbered by the removed LUT block). Recommended: `mov r7, r13`; use
   r13 for tile_line throughout; restore in epilogue. Verify extraction/emission do not use
   r13 (they currently don't — it was prefetch's scratch cursor).
3. Compute per column: `row = v_flip ? 7 - r13 : r13`; `idx = tile_n*8 + row`.
4. Load bg_tile_cache base into a register (e.g., `.Lbg_tile_cache_base` via mov.l, mirror
   the existing `.Ltile_cache_base` pattern). Check `bg_tile_state[idx]`:
   - if == 1 → `jsr gg_bg_decode(idx)`; then load hi/lo from `bg_tile_cache[idx]`.
   - else → load hi/lo directly from `bg_tile_cache[idx]`.
5. Continue to extraction (203–226) and emission (235–351) **unchanged** — they consume the
   hi(r7)/lo(r11) words + palette + priority exactly as before.

Register map for the rewritten loop: r4=dst cursor, r5=pri cursor, r6=name-row base pointer,
r7=hi word, r8=palette ptr (recomputed per column), r9/r10=row-entry scratch, r11=lo word,
r12=bg_tile_cache base, **r13=tile_line** (callee-saved). Reserve one stack slot for the `idx`
value if it cannot be kept in a register across the jsr.

### 5d. z80_asm.S — add bg invalidation at sites B & C

Mirror the existing `tile_cache_dirty[addr>>2]=1` store: after each dirty-store, emit one byte
store of 1 to `bg_tile_state[addr>>2]`. For OTIR (z80_asm.S:4069) reuse the loaded dirty base
register or load `.Lbg_tile_state_base`; for OUTI/OUTB (~4403) same. Keep stores adjacent so a
single extra byte-store per written byte is added to an already-DMA-bound path — negligible vs
the BG decode savings it enables.

## 6. Correctness argument

- **Decode fidelity:** `gg_bg_decode` reproduces render_asm.S:100–172 exactly (same tables, same
  OR accumulation over bp0..bp3). Cached hi/lo == non-cached output bit-for-bit.
- **Index alignment:** bg idx = tile_n*8+row = vram_ptr>>2 = the index invalidated by all three
  write sites. A VRAM write to a row marks that exact entry dirty → re-decode on next access.
- **v_flip preserved:** row already includes vflip (moved from prefetch into bg), so idx and the
  decoded pixel order match the previous path.
- **No sprite corruption:** separate arrays; BG-first render order no longer risks clobbering
  sprite validity.
- **First frame:** `bg_tile_state` all 1 at init → every row decodes once, then stays cached until
  a VRAM write invalidates it (same cross-frame caching semantics as sprites).

## 7. Verification plan (must run before touching sprites/prefetch)

1. Build with `PERF_DEBUG=1`. Confirm BG decode count drops and per-line time delta improves.
2. Visual regression: run a representative level; compare to current build frame-by-frame for the
   exact pixel output the cached path must reproduce.
3. Disassemble render_bg_line_asm + gg_bg_decode after change; confirm no clobber of r4/r5/r7/r8/
   r11 (emission regs) and correct tile_line persistence.
4. Stress invalidation: write VRAM mid-frame then re-render the same line → must show a cache miss
   (re-decode) and identical pixels to a full decode.
5. Re-check .bss size in linker map — confirm no SDRAM overflow.

## 8. Risks & mitigations

- **Register allocation** in the rewritten loop is intricate; tune with build+PERF_DEBUG, not blind.
- **Inline-Z80 edits** (sites B/C) touch a hot DMA path; keep each addition to one byte-store and
  rebuild/verify thoroughly — this is the riskiest part of the plan.
- **Memory budget:** +36 KB is within margin but verify post-link; if tight, defer to Plan B.

## Next after Plan A lands
Re-measure deltas with PERF_DEBUG=1 on BG only, then evaluate sprites (reuse pattern) and prefetch
removal as follow-ups.
