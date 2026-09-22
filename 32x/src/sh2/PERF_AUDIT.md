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

### #1 — Per-byte page computation in `_inline_gg_read` (line 920). [EVALUATED — REJECTED]
Every Z80 byte load funnels through this routine: `shlr8; shlr2; shlr` + `and #0x1C`
+ a table load `mov.l @(r0,r8)` + masked byte load. Looks like an easy target, but it
was evaluated and **rejected** — see "Why rejected" below.

    mov     r4, r0          ; addr
    shlr8   r0              ; >>8
    shlr2   r0              ; >>2
    shlr    r0              ; >>1  (>>11 combined with mask = page*4)
    mov     #0x1C, r2       ; mask bits [4:2]
    and     r2, r0          ; r0 = Mem_Pages offset
    mov.l   @(r0, r8), r1   ; base pointer for this page
    and     r10, r0         ; addr & 0x1FFF byte index
    mov.b   @(r0, r1), r0   ; load byte

WHY IT LOOKS ATTRACTIVE: Z80 game code is dominated by tight loops / sequential RAM, so
consecutive accesses share a page — recomputing the base pointer each time throws away
that locality. A naive fix keeps a `(key, base)` cache and skips the shifts on a hit.

WHY REJECTED (net ≈ zero):
- The dominant cost is the byte load itself: `main.c:616` documents each Z80 data byte at
  ~6-10 SH-2 cycles of UNCACHED SDRAM access. That load is unavoidable per access and dwarfs
  the shift/page-compute work. Caching cannot remove it.
- r7-r14 are pinned, callee-persistent Z80 state (header lines 9-17), so no register is free
  to hold a persistent cache base across calls without refactoring the prologue save/restore
  AND every handler that uses r5/r6 as scratch. A memory-backed key compare (~3 instrs: load
  key + cmp/eq + branch) saves ~3 shifts → net flat, plus mispredict risk on misses.
- Caching the DATA region instead would reintroduce the interpreter-code thrashing that
  `main.c:612` (OD=1) already avoids — measured at +568 FRT ticks when disabled (line 620).

Fix is not worth it; correctness risk on sound/input-critical code for no gain.

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
- Recommended: do NOT optimize #1 (rejected — net ≈ zero, see above). Instead MEASURE first
  with the existing on-screen PERF_DEBUG instrumentation (t1 = Z80 visible ticks, t2 = blanking,
  plus the opcode histogram at main.c:705) to confirm where time actually goes. The Z80 runs in
  parallel with the slave renderer (main.c:561-571), so it likely has headroom and is NOT the
  framerate limiter — if t1 is small vs the render-wait at main.c:651, target #3 instead. Verify
  any Z80-core change under a real game before wider rollout (sound + inputs depend on reads).
