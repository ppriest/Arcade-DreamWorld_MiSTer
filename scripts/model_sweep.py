#!/usr/bin/env python3
"""Capture scenes from every set and check scripts/render_model.py against each.

    python scripts/model_sweep.py                       # all sets, the default scene list
    python scripts/model_sweep.py dreamwld --jobs 4
    python scripts/model_sweep.py --report-only         # re-run the model on existing captures

A scene is (frame, coin): coin 0 is attract, otherwise a coin at that frame and play
(mame_capture.py --coin). Captures go to debug/<set>-sw<frame>[p]/. Prints, per scene, the
model's match and the features it exercises, so a feature no scene reaches is visible.
"""
import argparse
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_mra   # noqa: E402

REPO = Path(__file__).resolve().parent.parent
SCENES = [(600, 0), (1500, 0), (2400, 0), (3600, 0), (1500, 600), (2400, 600), (3600, 600)]


def name(frame, coin):
    return f"sw{frame}" + ("p" if coin else "")


def capture(setname, frame, coin):
    cmd = [sys.executable, str(REPO / "scripts" / "mame_capture.py"), setname, "--frame", str(frame),
           "--name", name(frame, coin)] + (["--coin", str(coin)] if coin else [])
    r = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True)
    return r.returncode == 0, (r.stdout + r.stderr).strip().splitlines()[-1:]


def features(d):
    """What the scene exercises, from the captured registers and sprite buffer."""
    vregs = np.frombuffer((d / "vregs.bin").read_bytes(), dtype=">u4")
    out = []
    for layer in (0, 1):
        c = int(vregs[4 + layer])
        f = [("128x32" if c & 0x400 else "64x64")]
        if c & 0x40:
            f.append("bank1")
        if c & 0x300:
            f.append("rs16" if c & 0x200 else "rs1")
        out.append(f"L{layer}:" + ",".join(f))
    s = np.frombuffer((d / "spritebuf.bin").read_bytes(), dtype=">u4")[:1024].reshape(512, 2).astype(np.int64)
    s0, s1 = s[:, 0], s[:, 1]
    x, y = ((s0 & 0x1ff) + 4) & 0x1ff, (s0 >> 16) & 0x1ff
    w, h = ((s0 >> 9) & 7) + 1, ((s0 >> 25) & 7) + 1
    # on screen: any part of the 4 wrapped copies inside 308 x 224
    vis = np.zeros(512, dtype=bool)
    for dx in (0, -0x200):
        for dy in (0, -0x200):
            x0, y0 = x - 16 + dx, y + dy
            vis |= (x0 < 308) & (x0 + 16 * w > 0) & (y0 < 224) & (y0 + 16 * h > 0)
    wrapped = vis & ((x - 16 + 16 * w > 0x200) | (y + 16 * h > 0x200) | (x < 16))
    out.append(f"spr:{int(vis.sum())}")
    if (vis & (s1 & 0x40000000 > 0)).any():
        out.append("xflip")
    if (vis & (s1 & 0x80000000 > 0)).any():
        out.append("yflip")
    if (vis & ((w > 1) | (h > 1))).any():
        out.append(f"max{int(w[vis].max())}x{int(h[vis].max())}")
    if wrapped.any():
        out.append("wrap")
    return " ".join(out)


def model(d):
    r = subprocess.run([sys.executable, str(REPO / "scripts" / "render_model.py"), str(d)],
                       cwd=REPO, capture_output=True, text=True)
    line = [l for l in r.stdout.splitlines() if "pixels match" in l]
    return r.returncode == 0, (line[0].split(": ", 1)[1] if line else (r.stdout + r.stderr).strip()[-200:])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sets", nargs="*")
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--report-only", action="store_true")
    a = ap.parse_args()
    sets = a.sets or list(build_mra.SETS)
    jobs = [(s, f, c) for s in sets for f, c in SCENES]
    if not a.report_only:
        with ThreadPoolExecutor(a.jobs) as ex:
            for (s, f, c), (ok, tail) in zip(jobs, ex.map(lambda j: capture(*j), jobs)):
                if not ok:
                    print(f"{s} {name(f, c)}: capture failed: {tail}")
    bad = 0
    for s, f, c in jobs:
        d = REPO / "debug" / f"{s}-{name(f, c)}"
        if not (d / "manifest.txt").exists():
            print(f"{s:10} {name(f, c):8} no capture")
            bad += 1
            continue
        ok, msg = model(d)
        bad += not ok
        print(f"{s:10} {name(f, c):8} {'PASS' if ok else 'FAIL'}  {msg:44}  {features(d)}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
