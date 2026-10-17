#!/usr/bin/env python3
"""Fixtures for sim/boot_tb: a set's program ROM and MCU ROM from its .mra image.

    python sim/boot_tb/gen_fixture.py [set]     # from the repository root, default dreamwld
    -> sim/boot_tb/maincpu.hex   1M 16-bit words, big-endian (the 68020's view)
       sim/boot_tb/mcu.hex       4096 16-bit words, even byte low (the MCU ROM's block RAM)
       sim/boot_tb/stream.hex    the MCU's C00030 stream: MCU ROM from 0x3C, 1737 bytes
    (not committed)

The image is scripts/build_mra.py --image, so the bench runs exactly what the .mra loads.
"""
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))
import build_mra  # noqa: E402


def main():
    game = sys.argv[1] if len(sys.argv) > 1 else "dreamwld"
    out = REPO / "sim" / "boot_tb"
    img_path = REPO / "debug" / f"{game}_image.bin"
    img_path.parent.mkdir(exist_ok=True)
    subprocess.run([sys.executable, str(REPO / "scripts" / "build_mra.py"), "--image", game, str(img_path)],
                   check=True)
    img = img_path.read_bytes()
    sm = build_mra.sdram_map()
    prg = img[sm["MAINCPU_BASE"]:sm["MAINCPU_BASE"] + 0x200000]
    (out / "maincpu.hex").write_text("".join(f"{prg[i]:02x}{prg[i + 1]:02x}\n" for i in range(0, len(prg), 2)))
    mcu = img[sm["MCU_BASE"]:sm["MCU_BASE"] + 0x2000]
    (out / "mcu.hex").write_text("".join(f"{mcu[i + 1]:02x}{mcu[i]:02x}\n" for i in range(0, len(mcu), 2)))
    (out / "stream.hex").write_text("".join(f"{b:02x}\n" for b in mcu[0x3c:0x3c + 1737]))
    print(f"{game}: maincpu.hex, mcu.hex, stream.hex in {out.relative_to(REPO)}")


if __name__ == "__main__":
    main()
