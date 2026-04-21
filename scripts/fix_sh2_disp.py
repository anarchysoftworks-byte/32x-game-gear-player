#!/usr/bin/env python3
"""Fix SH-2 displacement addressing constraint violations.

SH-2 rules:
  mov.b @(disp, Rn), Rm — Rm MUST be R0
  mov.b Rm, @(disp, Rn) — Rm MUST be R0

Our Phase B changes introduced illegal mov.b with r12. Fix them.
"""

ASM_PATH = '32x/src/sh2/z80_asm.S'

with open(ASM_PATH, 'r') as f:
    content = f.read()

original = content
changes = 0

# Fix STORE patterns: mov.b r12, @(2, r14) → mov r12, r0 / mov.b r0, @(2, r14)
store_patterns = [
    ('        mov.b   r12, @(2, r14)            /* sync A back to struct */\n',
     '        mov     r12, r0\n'
     '        mov.b   r0, @(2, r14)            /* sync A back to struct */\n'),
    ('        mov.b   r12, @(2, r14)  /* sync A to struct (generic handler) */\n',
     '        mov     r12, r0\n'
     '        mov.b   r0, @(2, r14)  /* sync A to struct (generic handler) */\n'),
    ('        mov.b   r12, @(2, r14)  /* sync A to struct for C fallback */\n',
     '        mov     r12, r0\n'
     '        mov.b   r0, @(2, r14)  /* sync A to struct for C fallback */\n'),
    ('        mov.b   r12, @(2, r14)  /* sync A to struct (CB generic) */\n',
     '        mov     r12, r0\n'
     '        mov.b   r0, @(2, r14)  /* sync A to struct (CB generic) */\n'),
]

for old, new in store_patterns:
    count = content.count(old)
    if count > 0:
        content = content.replace(old, new)
        changes += count
        print(f"Fixed {count} store(s): {old.strip()[:60]}")
    else:
        print(f"WARNING: not found: {old.strip()[:60]}")

# Fix LOAD patterns: mov.b @(2, r14), r12 → mov.b @(2, r14), r0
# These are followed by extu.b r12, r12 → change to extu.b r0, r12

# Pattern 1: plain reload
old = '        mov.b   @(2, r14), r12\n        extu.b  r12, r12\n'
new = '        mov.b   @(2, r14), r0\n        extu.b  r0, r12\n'
count = content.count(old)
if count > 0:
    content = content.replace(old, new)
    changes += count
    print(f"Fixed {count} plain reload(s)")
else:
    print("WARNING: plain reload pattern not found")

# Pattern 2: commented reload
old = '        mov.b   @(2, r14), r12           /* reload A from struct */\n        extu.b  r12, r12\n'
new = '        mov.b   @(2, r14), r0            /* reload A from struct */\n        extu.b  r0, r12\n'
count = content.count(old)
if count > 0:
    content = content.replace(old, new)
    changes += count
    print(f"Fixed {count} commented reload(s)")
else:
    print("WARNING: commented reload pattern not found")

# Pattern 3: reload in delay slot context (inc_r, dec_r, ld_rr, ld_r_xhl, ld_r_n)
# These have: mov.b @(2,r14),r12 / bra _z80_fetch / extu.b r12,r12
old = '        mov.b   @(2, r14), r12\n        bra     _z80_fetch\n        extu.b  r12, r12 /* delay slot */\n'
new = '        mov.b   @(2, r14), r0\n        bra     _z80_fetch\n        extu.b  r0, r12 /* delay slot */\n'
count = content.count(old)
if count > 0:
    content = content.replace(old, new)
    changes += count
    print(f"Fixed {count} delay-slot reload(s)")
else:
    print("WARNING: delay-slot reload pattern not found")

# Pattern 4: CB writeback reload:
# mov.b @(2,r14),r12 / bra .Lcb_return_fetch / extu.b r12,r12
old = '        mov.b   @(2, r14), r12\n        bra     .Lcb_return_fetch\n        extu.b  r12, r12 /* delay slot */\n'
new = '        mov.b   @(2, r14), r0\n        bra     .Lcb_return_fetch\n        extu.b  r0, r12 /* delay slot */\n'
count = content.count(old)
if count > 0:
    content = content.replace(old, new)
    changes += count
    print(f"Fixed {count} CB writeback reload(s)")
else:
    print("WARNING: CB writeback reload pattern not found")

# Verify no remaining violations
import re
violations = re.findall(r'mov\.b\s+r12,\s*@\(2,\s*r14\)|mov\.b\s+@\(2,\s*r14\),\s*r12', content)
if violations:
    print(f"\nERROR: {len(violations)} violations remaining!")
    for v in violations:
        print(f"  {v}")
else:
    print(f"\nAll violations fixed. No remaining mov.b r12/@(2,r14) patterns.")

if content != original:
    with open(ASM_PATH, 'w') as f:
        f.write(content)
    print(f"Total: {changes} fixes applied")
else:
    print("ERROR: No changes made!")
