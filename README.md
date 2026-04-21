# 32X Game Gear Player — Failed Experiment

> **Status: abandoned.** This project attempted to build a full-speed Game
> Gear emulator for the stock Sega 32X. After extensive measurement on
> real hardware, I concluded that **full-speed emulation of GG titles is
> not achievable on this platform** without additional hardware. Some
> lighter titles may be playable, but demanding games (such as Sonic the Hedgehog GG, my benchmark title) remain well below
> full speed.
>
> Released as open source in the hope that the code is useful to anyone
> considering similar work.


The 32X Game Gear Player is a Sega Game Gear emulator for Sega 32X hardware. It works by embedding a GG ROM into a `.32x` cartridge image at build time that boots directly into emulation.

This project started as a port of parts of [MEKA](https://github.com/ocornut/meka),
specifically the Z80 core and Game Gear VDP work, but it is not a straight
MEKA port. The 32X runtime, renderer pipeline, audio relay path, and most of
the performance work evolved into their own codebase over time.

## Build

Requires `sh-elf-gcc`, `m68k-elf-as/ld`, and `python3` on PATH.

For 32X homebrew, Chilly Willy's Sega MD/CD/32X devkit is the standard
toolchain. Recommended download: [32XDK releases](https://github.com/viciious/32XDK/releases).

No commercial Game Gear ROM is bundled with this public source release.
Before building, point the YOUR_ROM_HERE.gg `.incbin` in `32x/src/sh2/crt0_cart.s` at your own `.gg` ROM dump.

```
make                 # release build
make clean           # clean
make PERF_DEBUG=1    # build with on-screen FRT-tick overlay + opcode histogram
```

Output: `build/ggplayer.32x`

| Variable | Default | Notes |
| --- | --- | --- |
| `PERF_DEBUG` | `0` | Draws per-frame FRT-tick overlay and top-3 opcode histogram to the framebuffer. Use when profiling. |

## Run

Load `build/ggplayer.32x` in a 32X emulator (Ares, BlastEm) or on real
hardware. Tested on Ares and a stock Genesis Model 2 + 32X with an EverDrive
Pro / EverDrive X5.

## Project Structure

- `32x/` — SH-2 and M68K source, headers, linker scripts, build output
- `scripts/` — ROM header fixup tool
- `tools/` — Small project-specific helper utilities
- `build/` — Final ROM output

## How It Works

- **SH-2 Master**: Runs the Z80 CPU interpreter — hand-optimised SH-2 assembly
  (~9500 lines). All 256 main opcodes, all CB/ED/DD/FD sub-opcodes fully
  inlined. Handles I/O, memory mapping, and scanline scheduling.
- **SH-2 Slave**: Runs VDP Mode 4 scanline rendering (assembly tile decode +
  C sprite renderer) in parallel with the master's Z80 run.
- **M68K**: Boot handshake, VBlank joypad relay, and GG-mode PSG byte relay
  to the Genesis native SN76489 hardware.
- **SDRAM**: All hot code and lookup tables placed in SDRAM for fast SH-2
  access. The 4 KB unified I+D cache is the primary bottleneck.

### Key Optimisations

- **Idle-loop skip**: DD/FD prefix handlers pattern-match `BIT b,(IX/IY+d);
  JR Z,-6` and `LD A,(IX/IY+d); AND/OR A; JR Z,-6` polling loops and yield
  the Z80 time-slice immediately when the tested bit/byte is clear. This
  eliminated the dominant VBlank polling pattern in Sonic.
- **`OD=1` during blanking**: Data-replace-disable mode prevents the VBlank
  ISR's scattered data reads from evicting interpreter code lines from the
  4 KB cache (~855 FRT ticks saved).
- **Pinned `r13` pc_base**: Immediate-byte fetch uses a pre-computed base
  pointer instead of a full page-table walk (15 instructions → 7).
- **Async render pipeline**: `GG_RENDER_LEAD=200` publishes render commands
  ahead of the slave, eliminating all render backpressure during Z80 execution.

### Game Gear Specifics

- 160×144 viewport centred in 320×224 framebuffer with black borders
- 12-bit palette (4096 colours) converted to 32X 15-bit direct colour
- Audio routed to Genesis hardware PSG via M68K — zero slave SH-2 audio cost
- GG I/O ports 0x00-0x06 (Start button, region, stereo, Gear-to-Gear stubs)

## License

The source code in this repository is released under the terms in `LICENSE`.
In short: anyone can use it for any purpose, including commercial use, but
modified redistributions must preserve attribution and make source available
under the same terms.

That structure is intentional because parts of the emulator were ported from
MEKA / Marat Fayzullin code, so the repository uses a license compatible with
that inherited work rather than pretending the whole tree is fresh MIT/BSD
code.

## Thanks

To everyone in the 32X homebrew and MEKA / BlastEm / Ares communities
whose documentation made getting this far possible. The 32X platform
is a fascinating puzzle and it deserves more software; I just could
not make this particular idea fit.

Special credit to Omar Cornut and MEKA: this project began from ported MEKA
emulation code before diverging into a 32X-specific implementation.