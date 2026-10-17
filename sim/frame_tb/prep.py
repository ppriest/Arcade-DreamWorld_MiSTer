#!/usr/bin/env python3
"""Inputs for sim/frame_tb from a scripts/mame_capture.py directory.

    python sim/frame_tb/prep.py debug/dreamwld-sw600

Writes <capture>/cpu_state.hex: 5 x 4096 16-bit words in the order the bench writes them
through the CPU ports -- sprite RAM (spritebuf.bin, the copy the frame was drawn from), palette,
VRAM 0, VRAM 1, then the 0x804000 region (lineram words 0x000-0x1FF, vregs 0x200-0xFFF).
And debug/<set>-image.sdram: the .mra image with each byte pair swapped, so the bench's
$fread (first byte to the high half) leaves the even byte in the low half, as the download does.
Runs render_model.py on the capture if its model files are missing.
"""
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))
import render_model   # noqa: E402


def main():
    d = Path(sys.argv[1])
    setname = dict(l.split(" ", 1) for l in (d / "manifest.txt").read_text().splitlines() if " " in l)["set"]
    words = []
    for name, size in (("spritebuf.bin", 0x2000), ("palette.bin", 0x2000), ("vram0.bin", 0x2000),
                       ("vram1.bin", 0x2000)):
        b = (d / name).read_bytes()
        assert len(b) == size, (name, len(b))
        words += [b[i] << 8 | b[i + 1] for i in range(0, size, 2)]
    vr = (d / "lineram.bin").read_bytes() + (d / "vregs.bin").read_bytes()
    assert len(vr) == 0x2000, len(vr)
    words += [vr[i] << 8 | vr[i + 1] for i in range(0, 0x2000, 2)]
    (d / "cpu_state.hex").write_text("".join(f"{w:04x}\n" for w in words))

    sd = REPO / "debug" / f"{setname}-image.sdram"
    if not sd.exists():
        img = bytearray(render_model.image_for(setname))
        img[0::2], img[1::2] = img[1::2], img[0::2]
        sd.write_bytes(bytes(img))
    if not (d / "model_idx.bin").exists() or not (d / "model_top.bin").exists():
        subprocess.run([sys.executable, str(REPO / "scripts" / "render_model.py"), str(d)], check=False)
    print(f"{d}/cpu_state.hex, {sd.relative_to(REPO)}")
    print(f"scripts/run_sim.sh frame_tb +CAP={d.as_posix()} +IMG={sd.relative_to(REPO).as_posix()}")


if __name__ == "__main__":
    main()
