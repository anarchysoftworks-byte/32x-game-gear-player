# 32X Game Gear — Draw/Render Phase Optimization Audit

**Scope:** Read-only analysis of the dual-core (SH-2 master + SH-2 slave) Game
Gear scanline renderer. No code changes proposed; findings are candidates for
follow-up implementation, each with a structural justification and an estimate
of its payoff as a *fraction of the frame budget*.

**Honesty caveat on numbers:** This codebase references `PERF_AUDIT.md` in many
comments but **the file does not exist**, so there are no measured per-line cycle
counts to cite. Every number below is derived from *operation counting* against
known buffer sizes and the documented frame budget, using conservative uncached-
SDRAM op latencies. Absolute values (cycles/ticks) must be pinned with on-hardware
FRT counters before trusting a percentage — the percentages are order-of-magnitude
estimates, not measurements.

---

## 1. Architecture recap

The renderer is split across two SH-2 cores sharing one address space:

| Role | Core | Runs from | Responsibility |
|------|------|-----------|----------------|
| Master | SH-2 (main.c) | ROM `.text` | Drives the Z80 emulator, posts render *commands* to a shared ring buffer, polls completion, draws perf overlay, flips framebuffer. |
| Slave  | SH-2 (gg_psg.c / gg_render.c) | ROM `.text` + SDRAM `.sdram_code` | Consumes the command ring and rasterizes each visible scanline into the back buffer in parallel with the Z80 work. |

### The shared command protocol (`include/sh2/32x.h`)
The ring is a fixed-SDRAM pointer and the counters are memory-mapped words — **not** C
globals (the old draft wrongly listed them as `gg_render.c` variables):
```c
#define RENDER_CMD_MAX       224                                  // 32x.h:210
#define RENDER_CMDS          ((volatile scanline_cmd_t *)0x2603D100)   // 32x.h:221
#define RENDER_CMD_COUNT     (*(volatile int16_t *)0x2603D000)    // 32x.h:207
#define RENDER_DONE_COUNT    (*(volatile int16_t *)0x2603D040)    // 32x.h:210
#define GG_RENDER_LEAD       200                                  // main.c:327
#define GG_RENDER_PUBLISH_STRIDE 1                               // main.c:333
```
The master packs each command as one raw uint32_t (`line<<16 | scroll_x<<8 | flags`) and
stores it at `RENDER_CMDS[frame_cmd_idx]` (`main.c:405`); the slave batch-reads the same
word (`gg_psg.c:119-124`). The gap between RENDER_CMD_COUNT (publish) and RENDER_DONE_COUNT
(consume) is the work-in-flight; `GG_RENDER_LEAD = 200` is the target headroom.

### Frame timing budget (`main.c`)
* One frame ≈ **2996 FRT ticks** (`PERF_TICKS_PER_FRAME`, `main.c:62`).
* Commands are posted for the render window **lines 24–167 = 144 lines**, i.e.
  `[GG_RENDER_START, GG_RENDER_END)` (`main.c:69-70`). (Note: `GG_VISIBLE_LINES` in
  `gg_emu.h:248` is 192 — the full active area; only lines 24–167 post commands.)
* The master posts exactly one render command per visible scanline (plus a small
  blanking burst). See the invariant at `main.c:313-316`: *"The command buffer holds
  224 entries, and GG posts at most 144 … Buffer overflow is impossible."* (= RENDER_CMD_MAX)

---

## 2. Per-line cost model (display-ON path)

For each of ~144 visible scanlines the slave executes `gg_render_line`
(`gg_render.c:510`). In the display-ON case it performs, per line:

| Stage | Work | Memory ops / line |
|-------|------|-------------------|
| `render_background_line` (`gg_render.c:388`) | name-table read + ~32 tile LUT decodes (tile_lut_hi/lo, uncached SDRAM) + fine-scroll gap fill | ~192 writes (line_buf 128 lw + priority 64 lw) + up to ~128 reads (LUTs) |
| `render_sprites_line_asm` | per-active-sprite tile_cache consult (uncached, miss only), ≤ MAX_SPRITES_PER_LINE=8 | variable; usually 0–3 sprites/line |
| optional `Mask_Left_8` (`gg_render.c:568`) | 8 writes | 8 (rare) |
| `fb_copy_gg_line_asm` | copy visible row to back buffer | 128 longword stores |

**Framebuffer bandwidth is the dominant fixed cost:** 144 lines × ~128 lw copy =
~18,400 longword stores/line-work + another ~18,400 at the flip (back→front), i.e.
~37K+ uncached SDRAM writes/frame just to move pixels. Background decode adds a
further ~27K longword writes and ~18K reads.


---

## 3. Candidate optimizations (ranked by justified impact)

### C1 — Implement the documented-but-unimplemented per-line dirty-skip  ⭐ biggest
`gg_render.c:94-106` documents a rule for skipping an unchanged scanline: if no
palette change (`cram_dirty==0`), `scroll_x`/`scroll_y` are unchanged from last
frame, and none of the name-table tiles on that row changed (`tile_dirty_bits`),
the line can be skipped (reusing its previous framebuffer content).

**It is not implemented.** Grep confirms:
* `prev_scroll_x[]` — declared **nowhere in code**; it exists only inside the
  comment at `gg_render.c:105`.
* `tile_dirty_bits` (`gg_render.c:107`) is *written* (in the VRAM-write hook,
  `gg_render.c:193`) but **never read** to gate a skip.

So the largest documented optimization in the file is dead documentation.

**Justified payoff (static screen — title/menu):** on a skipped line you avoid the
entire decode + copy. Conservative per-line savings ≈ 448 uncached longword ops
(~192 bg writes + ~128 LUT reads + 128 copy) × ~5-7 cycles ≈ **2,500–3,000
cycles/line**. Over a fully static screen that is up to **~360K–430K cycles/frame**
— potentially the single largest win in static scenes. In scrolling games it degrades
to a cheap per-line compare (read `tile_dirty_bits` for one row + two scroll compares).

**Correctness:** skipping reuses *double-buffered* content ("2 frames ago" per the
comment at `gg_render.c:95`). The skip must be gated on the same conditions the VDP
would produce, and skipped lines must not be clobbered by the flip until needed — a
per-frame dirty mask handles this. Zero visual-corruption risk *if* the gate matches
the 4 documented conditions exactly.

---

### C2 — Remove the always-on backpressure poll  ⭐ provable (IMPLEMENTED)
The poll lived inside the visible-burst posting loop (`frame_scanline_cb`, `main.c`):
```c
while (frame_cmd_idx - (int)RENDER_DONE_COUNT >= GG_RENDER_LEAD)
    sh2_backoff_nops(16);
```
It polled RENDER_DONE_COUNT on **every** visible scanline to keep the master's write head
from outrunning the slave by more than `GG_RENDER_LEAD`.

**Why it is provably dead.** Ring capacity and posting bounds:
* `RENDER_CMD_MAX = 224` (`32x.h:210`) — buffer entries.
* Visible lines that post commands: GG_RENDER_START=24 … GG_RENDER_END=168 → exactly
  **144** (`main.c:69-70`). The master's own comment `main.c:313-326` states this verbatim:
  *"The command buffer holds 224 entries, and GG posts at most 144 … Buffer overflow is
  impossible."*
* Both `frame_cmd_idx` (`main.c:611`) and RENDER_DONE_COUNT (reset at `main.c:628`) are set
  to 0 at frame start.

So the write-read gap is bounded by **144**, which is `< GG_RENDER_LEAD = 200` *and*
`< RENDER_CMD_MAX = 224`. The poll can never fire, and the ring can never overflow — so it
was pure overhead: one uncached read + compare + branch per visible scanline.

**Implementation:** removed the `while` loop; a comment at the site documents the bound and
the exact re-add condition (`GG_RENDER_END - GG_RENDER_START > RENDER_CMD_MAX`, or non-render
commands added to the ring). Behavior is identical because the loop never iterated.

**Justified payoff:** ~144 uncached reads + branch/frame on the visible hot path — small in
absolute cycles but on the hottest loop in the file, and it deletes the last remaining
spin-poll so the code matches its own documentation ("eliminates backpressure entirely").

**Re-add condition:** only if `(GG_RENDER_END - GG_RENDER_START)` ever exceeds `RENDER_CMD_MAX`
(224), or non-render commands are added to the ring.

---

### C3 — Increase `GG_RENDER_PUBLISH_STRIDE` above 1  ⭐ cheap, likely net win
The master writes `RENDER_CMD_COUNT` after **every** command (`GG_RENDER_PUBLISH_STRIDE = 1`; publish store at `main.c:408-410`).
~144 uncached SDRAM writes/frame. The code comment itself estimates ~864 cycles.

But the slave already consumes in bursts — its loop does `{ ... } while (read_idx <
cmd_count)` with a 32-NOP backoff, so it only needs to see the count at burst
boundaries. Intermediate per-command publishes for commands it won't reach until its
next burst are wasted writes.

**Justified payoff:** stride = 4 → ~36 writes vs 144, saving **~650 cycles/frame (~22%)**;
stride = 8 → ~18 writes, **~750 cycles/frame (~25%)**. Cost is batch latency for the
first command of each new burst; since commands arrive one per scanline and the slave's
burst is fast, this delay is absorbed by the existing backoff. **Net win if the blue
frame-end wait stays ~0** — measurable without changing correctness.

---

### C4 — Eliminate the frame-end "blue" wait as pure idle (cascades to C1–C3)
`main.c:767`:
```c
while (RENDER_DONE_COUNT < frame_cmd_idx) sh2_backoff_nops(32);
```
This is the serialization tail **after all Z80 work is done** — it overlaps nothing. If
the slave finishes after the Z80 blanking completes, this wait is permanent waste that
caps effective throughput at "slave render time," independent of how fast the Z80 runs
(the classic *slave-bound* regime).

The wait already exits immediately when `RENDER_DONE_COUNT >= frame_cmd_idx` (slave done),
so it is not mis-designed — its existence just means the slave is slower than the
Z80's visible+blanking window. **Reducing per-line cost via C1–C3 is what makes this
wait shrink toward zero.** An alternative framing: overlap the wait with vblank-entry or
flip-setup so it stops being idle, but that risks breaking the 60fps lock and stale-frame

---

### C5 — `sat_precompute` is already handled (no action)
Per-line sprite lists are built once per frame in `sat_precompute` (`gg_render.c:291`)
with a **working static-sprite-frame guard** (`gg_render.c:306-313`) that byte-compares
the SAT to the previous frame and skips re-scanning — documented as saving ~89K
cycles/frame on static frames. This is already the optimized form; no candidate here.

---

### C6 — Sprite tile_cache reads are uncached SDRAM (harder win)
`render_sprites_line_asm` consults `tile_cache` (`gg_render.c:173-181`, ~36 KB in SDRAM) on
a miss, but the access is uncached, so there is **no cross-line reuse benefit** — the
"cache" only saves decode work, not memory latency. Improving this requires a user-
controllable D-cache policy and a trusted region, which the shared-SRAM coherency model
(`gg_render.c:529-533` shows how fragile cache assumptions already are) does not easily
support. Low priority / high risk; noted for completeness.

---

## 4. Recommended order of work

1. **C2** — provably redundant, near-zero risk, quick cycle win + cleaner code. Do first.
2. **C3** — cheap, correctness-preserving (slave already bursts); measure the blue wait.
3. **C1** — largest upside in static scenes; implement behind the exact 4 documented gates;
   verify against double-buffer flip semantics. Biggest bang when it triggers.
4. Re-measure with real FRT counters (the missing `PERF_AUDIT.md`) to convert these
   order-of-magnitude estimates into committed percentages before relying on any of them.

## 5. Files & references
* Master scheduler / frame-end wait: `main.c` (visible-burst posting loop + removed C2 poll at
  lines ~380-399; publish store at 408, GG_RENDER_LEAD 327, RENDER_CMD_MAX in 32x.h:210, frame-end
  spin at 767).
* Slave renderer + protocol constants: `gg_render.c` (`RENDER_CMDS`/`LEAD`/`PUBLISH_STRIDE`,
  per-line skip doc `94-106`, `sat_precompute` `291-381`, `render_background_line` `388-503`,
  `gg_render_line` `510-584`).
* Slave rasterizer entry: `gg_psg.c`. Tile decode / copy / sprite asm: `render_asm.S`.

latency — generally not worth it for an emulator.
