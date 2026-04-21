#!/usr/bin/env python3
import argparse
import struct
from pathlib import Path

MODULE_MAGIC = b"MOD0"
HEADER_FMT = ">4s14I"


def load_blob(path: str | None) -> bytes:
    if not path:
        return b""
    return Path(path).read_bytes()


def parse_u32(value: str) -> int:
    return int(value, 0)


def main() -> int:
    parser = argparse.ArgumentParser(description="Pack a Game Gear 32X module (.mod)")
    parser.add_argument("--output", required=True, help="Output .mod file")
    parser.add_argument("--sh2-bin", required=True, help="SH2 module binary blob")
    parser.add_argument("--cd-bin", help="Optional CD M68K module blob")
    parser.add_argument("--assets-bin", help="Optional packed assets blob")

    parser.add_argument("--cd-load-addr", default="0x0000C000", help="CD M68K load addr")
    parser.add_argument("--sh2-load-addr", default="0x06000000", help="SH2 load addr")
    parser.add_argument("--sh2-boot-offset", default="8", help="SH2 boot payload offset inside SH2 blob")
    parser.add_argument("--default-next", default="0", help="Default next module id")

    parser.add_argument("--cd-entry-init", default="0", help="CD init entry offset")
    parser.add_argument("--cd-entry-tick", default="0", help="CD tick entry offset")
    parser.add_argument("--cd-entry-shutdown", default="0", help="CD shutdown entry offset")

    parser.add_argument("--sh2-entry-init", default="0", help="SH2 init entry offset")
    parser.add_argument("--sh2-entry-tick", default="0", help="SH2 tick entry offset")
    parser.add_argument("--sh2-entry-shutdown", default="0", help="SH2 shutdown entry offset")

    args = parser.parse_args()

    cd_blob = load_blob(args.cd_bin)
    sh2_blob = load_blob(args.sh2_bin)
    assets_blob = load_blob(args.assets_bin)

    if not sh2_blob:
        raise SystemExit("sh2 blob is required and cannot be empty")

    header_size = struct.calcsize(HEADER_FMT)
    assets_offset = 0
    if assets_blob:
        assets_offset = header_size + len(cd_blob) + len(sh2_blob)

    header = struct.pack(
        HEADER_FMT,
        MODULE_MAGIC,
        parse_u32(args.cd_load_addr),
        len(cd_blob),
        parse_u32(args.cd_entry_init),
        parse_u32(args.cd_entry_tick),
        parse_u32(args.cd_entry_shutdown),
        parse_u32(args.sh2_load_addr),
        len(sh2_blob),
        parse_u32(args.sh2_boot_offset),
        parse_u32(args.sh2_entry_init),
        parse_u32(args.sh2_entry_tick),
        parse_u32(args.sh2_entry_shutdown),
        assets_offset,
        len(assets_blob),
        parse_u32(args.default_next),
    )

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(header + cd_blob + sh2_blob + assets_blob)

    print(f"Packed {output} ({output.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
