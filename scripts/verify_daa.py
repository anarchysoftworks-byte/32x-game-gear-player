#!/usr/bin/env python3
"""
verify_daa.py — Brute-force verify inline DAA against DAATable (all 2048 entries)

Parses DAATable from z80_tables.h and compares every entry against
the z80_compute_daa() algorithm. Zero tolerance for mismatches.
"""

import re
import sys
import os

# Z80 flag bit positions
S_FLAG = 0x80
Z_FLAG = 0x40
H_FLAG = 0x10
P_FLAG = 0x04
N_FLAG = 0x02
C_FLAG = 0x01

def build_pzs_table():
    """Build PZSTable: Parity + Zero + Sign for all byte values."""
    table = []
    for i in range(256):
        f = 0
        if i == 0:
            f |= Z_FLAG
        if i & 0x80:
            f |= S_FLAG
        # Parity: set if even number of 1-bits
        bits = bin(i).count('1')
        if bits % 2 == 0:
            f |= P_FLAG
        table.append(f)
    return table

PZSTable = build_pzs_table()

def z80_compute_daa(a, f):
    """Inline DAA computation — must match z80_compute_daa() in z80_tables.h"""
    old_a = a
    correction = 0
    new_c = f & C_FLAG  # sticky carry

    if (a & 0x0F) > 0x09 or (f & H_FLAG):
        correction |= 0x06
    if a > 0x99 or (f & C_FLAG):
        correction |= 0x60
        new_c = C_FLAG

    if f & N_FLAG:
        a = (a - correction) & 0xFF
    else:
        a = (a + correction) & 0xFF

    f = (PZSTable[a]
         | (a & 0x28)               # undocumented Y (bit 5), X (bit 3)
         | (f & N_FLAG)             # preserve N
         | new_c                    # C = old_C | (old_A > 0x99)
         | ((old_a ^ a) & H_FLAG)) # H = half-carry of correction

    return (a << 8) | f

def parse_daa_table(filepath):
    """Extract DAATable hex values from z80_tables.h"""
    with open(filepath) as fh:
        text = fh.read()

    # Find the DAATable definition
    match = re.search(r'DAATable\[2048\]\s*=\s*\{([^}]+)\}', text, re.DOTALL)
    if not match:
        print("ERROR: Could not find DAATable[2048] in", filepath)
        sys.exit(1)

    body = match.group(1)
    values = [int(x, 16) for x in re.findall(r'0x[0-9A-Fa-f]+', body)]

    if len(values) != 2048:
        print(f"ERROR: Expected 2048 entries, found {len(values)}")
        sys.exit(1)

    return values

def main():
    # Find z80_tables.h relative to this script
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(script_dir)
    tables_path = os.path.join(project_root, '32x', 'include', 'sh2', 'z80_tables.h')

    if not os.path.exists(tables_path):
        print(f"ERROR: {tables_path} not found")
        sys.exit(1)

    print(f"Parsing DAATable from {tables_path}...")
    daa_table = parse_daa_table(tables_path)

    print("Verifying all 2048 DAA entries...")
    mismatches = 0

    for idx in range(2048):
        a_val = idx & 0xFF
        c_flag = C_FLAG if (idx & 256) else 0
        h_flag = H_FLAG if (idx & 512) else 0
        n_flag = N_FLAG if (idx & 1024) else 0

        # Build minimal F register with just the relevant flags
        f_in = c_flag | h_flag | n_flag

        expected = daa_table[idx]
        computed = z80_compute_daa(a_val, f_in)

        if computed != expected:
            mismatches += 1
            exp_a = (expected >> 8) & 0xFF
            exp_f = expected & 0xFF
            got_a = (computed >> 8) & 0xFF
            got_f = computed & 0xFF
            print(f"  MISMATCH idx={idx:4d} A=0x{a_val:02X} "
                  f"C={1 if c_flag else 0} H={1 if h_flag else 0} N={1 if n_flag else 0}: "
                  f"expected A=0x{exp_a:02X} F=0x{exp_f:02X}  "
                  f"got A=0x{got_a:02X} F=0x{got_f:02X}  "
                  f"(F diff: 0x{exp_f ^ got_f:02X})")
            if mismatches >= 20:
                print("  ... (stopping after 20 mismatches)")
                break

    if mismatches == 0:
        print(f"PASS: All 2048 entries match perfectly.")
    else:
        print(f"FAIL: {mismatches} mismatches found.")
        sys.exit(1)

if __name__ == '__main__':
    main()
