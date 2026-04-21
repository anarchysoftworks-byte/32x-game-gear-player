#!/usr/bin/env python3
"""
Genesis/32X ROM Header Fixup

Patches a 32X ROM binary with correct checksum and ROM end address.
Based on Chilly Willy's romheaderfix.c from d32xr.

Fields patched:
  0x18E: 16-bit checksum (sum of all big-endian words from 0x200 to EOF)
  0x1A4: 32-bit ROM end address (file_size - 1)

Usage:
  python3 romheaderfix.py <romfile.32x>
"""

import struct
import sys
import os


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <romfile>")
        sys.exit(1)

    rompath = sys.argv[1]

    with open(rompath, "r+b") as f:
        data = f.read()
        size = len(data)

        print(f"ROM size: {size} bytes (0x{size:X}), end boundary: 0x{size - 1:X}")

        # Calculate checksum: sum of all big-endian 16-bit words from 0x200 to EOF
        checksum = 0
        for i in range(0x200, size - 1, 2):
            word = struct.unpack_from(">H", data, i)[0]
            checksum = (checksum + word) & 0xFFFF

        print(f"Checksum: 0x{checksum:04X}")

        # Write checksum at 0x18E (big-endian)
        f.seek(0x18E)
        f.write(struct.pack(">H", checksum))

        # Write ROM end address at 0x1A4 (big-endian, size - 1)
        rom_end = size - 1
        f.seek(0x1A4)
        f.write(struct.pack(">I", rom_end))

        print(f"Patched checksum=0x{checksum:04X}, ROM end=0x{rom_end:06X}")


if __name__ == "__main__":
    main()
