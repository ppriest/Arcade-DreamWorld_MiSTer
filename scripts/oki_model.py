#!/usr/bin/env python3
"""MAME's OKI M6295, transcribed, for the sound benches.

    python scripts/oki_model.py dreamwld oki1            # list the valid phrases
    python scripts/oki_model.py dreamwld oki1 --phrase 5 --att 0 --bank 0 --samples 50

Transcribes src/devices/sound/okiadpcm.cpp (oki_adpcm_state: the step and difference tables,
clock(), reset() to signal 0 step 0) and src/devices/sound/okim6295.cpp (write(): the phrase
table at phrase * 8, 18-bit start and stop, 2 * (stop - start + 1) nibbles, high nibble first;
generate_adpcm(): signal * volume, the volume table 32, 22, 16, 11, 8, 6, 4, 3, 2 /32). The ROM
is read through dreamwld.cpp's map: the chip's address below 0x30000 directly, 0x30000-0x3FFFF
as the bank's 64 KB from ROM 0x30000 (oki1_map, machine_start).

decode() returns one voice's samples as MAME computes them (float, signal * vol / 32) and as
jt6295 computes them ((signal * vol) >> 5, arithmetic).
"""
import argparse
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_mra       # noqa: E402
import render_model    # noqa: E402

NBL2BIT = [(1, 0, 0, 0), (1, 0, 0, 1), (1, 0, 1, 0), (1, 0, 1, 1), (1, 1, 0, 0), (1, 1, 0, 1),
           (1, 1, 1, 0), (1, 1, 1, 1), (-1, 0, 0, 0), (-1, 0, 0, 1), (-1, 0, 1, 0), (-1, 0, 1, 1),
           (-1, 1, 0, 0), (-1, 1, 0, 1), (-1, 1, 1, 0), (-1, 1, 1, 1)]
INDEX_SHIFT = [-1, -1, -1, -1, 2, 4, 6, 8]
VOLUME = [32, 22, 16, 11, 8, 6, 4, 3, 2, 0, 0, 0, 0, 0, 0, 0]
DIFF = []
for step in range(49):
    stepval = math.floor(16.0 * pow(11.0 / 10.0, step))
    for s, b2, b1, b0 in NBL2BIT:
        DIFF.append(s * (stepval * b2 + stepval // 2 * b1 + stepval // 4 * b0 + stepval // 8))


def rom_of(setname, chip):
    """The chip's 512 KB sample ROM, from the .mra image."""
    img, sm = render_model.image_for(setname), build_mra.sdram_map()
    base = sm["OKI1_BASE" if chip == "oki1" else "OKI2_BASE"]
    return img[base:base + 0x80000]


def read_byte(rom, addr, bank):
    addr &= 0x3ffff
    return rom[addr if addr < 0x30000 else addr + bank * 0x10000]


def phrase_range(rom, phrase, bank=0):
    b = phrase * 8
    start = (read_byte(rom, b, bank) << 16 | read_byte(rom, b + 1, bank) << 8 | read_byte(rom, b + 2, bank)) & 0x3ffff
    stop = (read_byte(rom, b + 3, bank) << 16 | read_byte(rom, b + 4, bank) << 8 | read_byte(rom, b + 5, bank)) & 0x3ffff
    return start, stop


def phrases(rom, bank=0):
    """Phrases MAME would play (start < stop), with their length in samples."""
    out = []
    for p in range(128):
        start, stop = phrase_range(rom, p, bank)
        if start < stop:
            out.append((p, start, stop, 2 * (stop - start + 1)))
    return out


def decode(rom, phrase, att=0, bank=0, limit=None):
    """([MAME float samples], [jt6295 integer samples]) of one voice playing `phrase`."""
    start, stop = phrase_range(rom, phrase, bank)
    if not start < stop:
        return [], []
    count = 2 * (stop - start + 1)
    if limit is not None:
        count = min(count, limit)
    signal, step, vol = 0, 0, VOLUME[att & 15]
    mame, rtl = [], []
    for n in range(count):
        nibble = (read_byte(rom, start + n // 2, bank) >> (((n & 1) << 2) ^ 4)) & 15
        signal = max(-2048, min(2047, signal + DIFF[step * 16 + nibble]))
        step = max(0, min(48, step + INDEX_SHIFT[nibble & 7]))
        mame.append(signal * vol / 32)
        rtl.append((signal * vol) >> 5)
    return mame, rtl


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("set")
    ap.add_argument("chip", choices=("oki1", "oki2"))
    ap.add_argument("--phrase", type=int)
    ap.add_argument("--att", type=int, default=0)
    ap.add_argument("--bank", type=int, default=0)
    ap.add_argument("--samples", type=int, default=40)
    a = ap.parse_args()
    rom = rom_of(a.set, a.chip)
    if a.phrase is None:
        for p, start, stop, n in phrases(rom, a.bank):
            print(f"phrase {p:3}: 0x{start:05x}-0x{stop:05x}, {n} samples ({n / (1e6 / 165):.2f} s)")
        return 0
    mame, rtl = decode(rom, a.phrase, a.att, a.bank, a.samples)
    print(" ".join(str(v) for v in rtl))
    return 0


if __name__ == "__main__":
    sys.exit(main())
