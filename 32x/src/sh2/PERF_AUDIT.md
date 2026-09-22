# Z80 Emulator Performance Audit (sh2 / z80_asm.S)

Target: emulate a 3 MHz Z80 on the Sega 32X's two 23 MHz SH-2 cores.
This file consolidates the hot-path audit of `z80_asm.S` and its callers in
`main.c`. "F3" references elsewhere point here.

## Execution model (how a byte is processed)
1. `_z80_fetch`: `mov.b @(r11,r9), r9` pre-fetches the next opcode in the delay
   slot of `add #-6, r11` — already overlaps fetch with decode. Good.
2. Dispatch: 256-entry table + `calli` to a specialized handler (e.g.
   `_z80_ld_a_hl`). This is a single load + indirect call; optimal for a full
   opcode table.
3. Handler executes, calling `_inline_gg_read` / `_inline_gg_write` for each
   memory access, then `rts` back to `_z80_fetch`.

## Ranked bottlenecks (highest impact first)

### #1 — Per-byte page computation in `_inline_gg_read` (line 920). [HOTTEST]
Every Z80 byte load funnels through this routine. It computes the backing-page
base pointer from a raw 16-bit address with **3 shifts** (`shlr8; shlr2; shlr`)
plus `and #0x1C`, then a table load `mov.l @(r0,r8)` and a masked byte load:

    mov     r4, r0          ; addr
    shlr8   r0              ; >>8
    shlr2   r0              ; >>2  (total >>10)
    shlr    r0              ; >>1  (total >>11 = page*4 after mask)
    mov     #0x1C, r2       ; page*4 mask = bits [4:2]
    and     r2, r0          ; r0 = (addr>>11)&0x1C = Mem_Pages offset
    mov.l   @(r0, r8), r1   ; r1 = Mem_Pages[page] base  <-- the only cache miss per access
    mov     r4, r0
    and     r10, r0         ; addr & 0x1FFF byte index
    mov.b   @(r0, r1), r0   ; load byte

Cost ≈ **7 instructions / byte load**. The `mov.l @(r0,r8)` table fetch is a real
memory access on the hottest path. Multi-byte ops (`POP BC/DE`, etc.) inline this
sequence twice (~40 instr each) — expensive but less frequent than plain loads.

WHY IT HURTS: Z80 game code is dominated by tight loops and sequential RAM access,
so consecutive accesses almost always hit the same page. Recomputing the base
pointer from scratch every time throws away that locality.

FIX (page cache): keep a small table `last_base[topbyte]` + `last_top`, where
`topbyte = addr>>8`. On load: compare top byte to cached; on hit skip all shifts
and reuse the base pointer directly (2 extra instrs, no shifts, no table load).
Invalidate only when mapping actually changes (`gg_map`, save-state restore) —
writes to RAM/mapper do NOT change the backing buffer pointer, so reads stay valid.
Expected: ~7 -> ~3-4 instructions on the common case; `mov.l` removed from hot path.

### #2 — Multi-byte read duplication (POP BC/DE, lines 1938+). [HIGH]
Two full `_inline_gg_read` sequences are inlined per stack pop because a byte-pair
read spans two pages and the compiler/emulator can't share page state across them.
If #1 is implemented as a cached base pointer keyed on top-byte, these become cheap
when both bytes land in one page (common for SP near a fixed region). Reconsider a
single-page-optimized 16-bit stack-pop path once #1 lands.

### #3 — Visible-scanline callback asymmetry (main.c:599 vs :625). [MEDIUM]
Active display lines pay a per-scanline Z80 callback + render-posting overhead, while
blanking runs batched with a NULL callback. This is a renderer-side cost, not in the
Z80 core, but it caps achievable framerate independently of Z80 speedups. Exploit by
batching visible-line callbacks or deferring posting like blanking does where safe.

### #4 — Dispatch `bsr`/`rts` round-trip. [LOW]
One indirect call + return per instruction is already efficient given the specialized
handler model. Only matters if a single mega-handler with inline decode replaced the
table; that trades code size for fewer branches and is a larger, riskier change.

## Already well-optimized (don't touch)
- ED-prefix `LDIR`/`LDDR`: tight hardware loops (no per-byte handler call).
- Fetch pre-fetch in delay slot of `add #-6, r11`.
- `_inline_gg_write` fast path: branch to check base 0xC000, mask, store to flat buffer.
- 256-entry dispatch table + `calli`.

## Validation notes / limitations
- No headless Z80 correctness harness exists; the only way to run is via a 32X core
  (PicoDrive / genesis-plus-gx) on hardware or an SH2 emulator. `sh-elf` toolchain and
  build artifacts are present, so *compile* checks pass, but behavior must be verified
  by loading real games (Z80 drives sound + inputs — wrong reads break them).
- Recommended: implement #1 in isolation, compile with `make`, then verify a couple of
  Z80-heavy titles under an emulator before wider changes.
