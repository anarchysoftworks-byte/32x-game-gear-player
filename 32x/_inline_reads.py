#!/usr/bin/env python3
# Uniform inline transform for _inline_gg_read call sites.
# Rule: replace  "bsr _inline_gg_read\n<DS>"  with  "<DS>\n<read_body>"
# <DS> (the bsr delay-slot line) sets up the address arg in r4 and now runs
# immediately before the inlined body, so the body reads the correct addr.
import re, sys

path = "src/sh2/z80_asm.S"
read_body = """        mov     r4, r0          /* page computation; preserve r4 for multi-read */
        shlr8   r0
        shlr2   r0
        shlr2   r0
        shlr    r0              /* >>13 = page */
        shll2   r0              /* offset = page * 4 into Mem_Pages[] */
        mov.l   @(r0, r8), r1   /* r1 = Mem_Pages[page] base (LOAD) */
        mov     r4, r0          /* copy addr again for byte index */
        and     r10, r0         /* r0 = addr & 0x1FFF (R0 short form) */
        mov.b   @(r0, r1), r0   /* value -> r0 */"""

pat = re.compile(r'^\s*bsr\s+_inline_gg_read\s*$')
lines = open(path).read().split("\n")
out, i, n = [], 0, 0
while i < len(lines):
    if pat.match(lines[i]):
        assert i + 1 < len(lines), f"bsr _inline_gg_read at end of file (line {i+1})"
        ds = lines[i + 1]
        out.append(ds)          # keep the delay-slot instruction (sets up r4/r7)
        out.append(read_body)   # inlined read body
        n += 1
        i += 2
    else:
        out.append(lines[i])
        i += 1
open(path, "w").write("\n".join(out))
print(f"read inline transform applied to {n} sites")
