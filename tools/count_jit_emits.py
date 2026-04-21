#!/usr/bin/env python3
import re
from pathlib import Path

src = Path('32x/src/sh2/z80_jit.c').read_text()

patterns = [
    ('NOP', r"if \(op == 0x00\)"),
    ('LD_r_r', r"if \(op >= 0x40 && op <= 0x7F && op != 0x76\)"),
    ('LD_r_n', r"if \(\(op & 0xC7\) == 0x06\)"),
    ('LD_rr_nn', r"if \(\(op & 0xCF\) == 0x01\)"),
    ('INC_rr', r"if \(\(op & 0xCF\) == 0x03\)"),
    ('ADD_HL_rr', r"if \(\(op & 0xCF\) == 0x09\)"),
    ('EX_DE_HL', r"if \(op == 0xEB\)"),
    ('LD_A_BC', r"if \(op == 0x0A\)"),
    ('LD_A_DE', r"if \(op == 0x1A\)"),
    ('LD_A_nn', r"if \(op == 0x3A\)"),
    ('LD_(BC)_A', r"if \(op == 0x02\)"),
    ('LD_(nn)_A', r"if \(op == 0x32\)"),
    ('LD_HL_nn', r"if \(op == 0x2A\)"),
    ('LD_(nn)_HL', r"if \(op == 0x22\)"),
    ('INC_r', r"if \(\(op & 0xC7\) == 0x04\)"),
    ('DEC_r', r"if \(\(op & 0xC7\) == 0x05\)"),
    ('AND_A_r', r"if \(op >= 0xA0 && op <= 0xA7\)"),
    ('AND_A_n', r"if \(op == 0xE6\)"),
    ('OR_A_r', r"if \(op >= 0xB0 && op <= 0xB7\)"),
    ('JP_CALL', r"emit_chain_or_epilogue|JP|CALL"),
]

results = []
for name, pat in patterns:
    m = re.search(pat, src)
    if not m:
        results.append((name, 0, 'missing'))
        continue
    start = m.start()
    # crude slice until next 'return 1;' after start
    tail = src[start:]
    ri = tail.find('return 1;')
    if ri == -1:
        # fallback: take 400 chars
        snippet = tail[:2000]
    else:
        snippet = tail[:ri+10]
    count = len(re.findall(r'JIT_EMIT\(', snippet))
    results.append((name, count, 'ok'))

# print table
print('OpcodeBlock, JIT_EMIT_count')
for name, count, status in results:
    print(f'{name}, {count}, {status}')
