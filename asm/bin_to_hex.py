#!/usr/bin/env python3
"""
bin_to_hex.py — convert a raw binary image into a $readmemh-compatible hex
file, one 64-bit word per line, little-endian (lowest byte of the 8-byte
window is the least significant byte of the word).

Usage:
    python3 asm/bin_to_hex.py diagnostic.bin diagnostic.hex

The output format matches what `$readmemh` expects when loading into a
64-bit-wide BRAM: each line is a 16-hex-digit value with no address tag.
"""
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 1

    src = Path(sys.argv[1]).read_bytes()

    # Pad to a multiple of 8 bytes so we can emit whole 64-bit words.
    pad = (-len(src)) % 8
    if pad:
        src += b"\xFF" * pad

    lines = []
    for i in range(0, len(src), 8):
        # Little-endian: byte i is LSB, byte i+7 is MSB of the 64-bit word
        word = int.from_bytes(src[i : i + 8], "little")
        lines.append(f"{word:016x}")

    Path(sys.argv[2]).write_text("\n".join(lines) + "\n")
    print(f"wrote {len(lines)} × 64-bit words → {sys.argv[2]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
