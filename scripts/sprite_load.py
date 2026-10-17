#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Sprite tile rows per scanline, from MAME, for the sprite fetch budget.

    python scripts/sprite_load.py <set> [<set> ...] [--skip 600] [--frames 1800]
    python scripts/sprite_load.py <set> --coin 600 --skip 1500 --tag _play
    python scripts/sprite_load.py <set> --reuse

Dumps the drawn half of sprite RAM (0x400000-0x400FFF, 512 records of two
longs) at every vblank start (scripts/mame/sprdump.lua), which is the list
dreamwld.cpp's screen_vblank copies, and counts, for every visible line of
every frame, the 16-pixel tile rows a per-scanline engine has to fetch.

Geometry is draw_sprites() in dreamwld.cpp (lines 203-260):
    long 0: X 8:0, X size 11:9, Y 24:16, Y size 27:25 (size + 1 tiles)
    X = ((X + 4) & 0x1FF) - 16; each tile is also drawn at -0x200 in X and Y
A flipped block covers the same pixels as an unflipped one.

Two counts per line:
    rows      tile rows of every block whose Y span covers the line -- what an
              engine that does not test X fetches
    visible   only the tile columns that overlap X 0..307
With --blank, visible rows whose 16 pixels are all pen 0 after the spritelut
redirect are not counted (gfx and LUT from the set's zip in MAME_ROMPATH):
the rows that can change a pixel.
Raw dumps: debug/sprload/<set><tag>.bin. Snapshot: debug/sprload/snap<tag>/.
"""
import argparse
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import (NO_WINDOW, lua_env, lua_runner_env, mame_cmd,  # noqa: E402
                          mame_paths, regions)

BASE, LEN = 0x400000, 0x1000
SCREEN_W, SCREEN_H = 308, 224

# set: (zip, gfx1 files in region order, spritelut even-byte file, odd-byte file)
ROMS = {
    "dreamwld":  ("dreamwld", ["9.bin"], "8.bin", "7.bin"),
    "cutefght":  ("cutefght", ["10_semicom", "11_semicom", "13_semicom", "14_semicom"],
                  "7_semicom", "8_semicom"),
    "baryon":    ("baryon", ["10_semicom", "11_semicom"], "6_semicom", "7_semicom"),
    "baryona":   ("baryon", ["10_semicom", "11_semicom"], "6_semicom", "7_semicom"),
    "rolcrush":  ("rolcrush", ["m27c160.8.bin"], "tms27c010_7.bin", "tms27c010_6.bin"),
    "rolcrusha": ("rolcrush", ["rolcrusha/8"], "rolcrusha/7", "rolcrusha/6"),
    "gaialast":  ("gaialast", ["10", "11", "12"], "6", "7"),
}


def load_blank(game):
    """(lut, blank) -- blank[tile * 16 + row] is True when that row is all pen 0."""
    import os
    import zipfile
    zname, gfx, even, odd = ROMS[game]
    for d in os.environ.get("MAME_ROMPATH", "").split(";") + [r"F:/Emulation/roms/MAME ROMs"]:
        zp = Path(d) / f"{zname}.zip"
        if zp.exists():
            break
    z = zipfile.ZipFile(zp)
    g = b"".join(z.read(n) for n in gfx)
    a, b = z.read(even), z.read(odd)
    lut = [a[i] | (b[i] << 8) for i in range(len(a))]
    blank = [g[k * 8:k * 8 + 8] == bytes(8) for k in range(len(g) // 8)]
    return lut, blank


def run(game, skip, frames, coin, tag):
    mame_dir, exe = mame_paths()
    r = regions()
    out = REPO / "debug" / "sprload" / f"{game}{tag}.bin"
    out.parent.mkdir(parents=True, exist_ok=True)
    inp = r.get("inputs", {})
    env = dict(__import__("os").environ, **lua_env(r), **lua_runner_env("sprdump.lua"),
               SD_OUT=out.as_posix(), SD_BASE=f"{BASE:x}", SD_LEN=str(LEN),
               SD_SKIP=str(skip), SD_FRAMES=str(frames), SD_COIN=str(coin),
               SD_IN_COIN=inp.get("coin", "Coin 1"), SD_IN_START=inp.get("start", "1 Player Start"),
               SD_IN_HOLD=inp.get("hold", "P1 Right"), SD_IN_PULSE=inp.get("pulse", "P1 Button 1"))
    cmd = mame_cmd(exe, game, "sprdump.lua", mame_dir,
                   ["-snapshot_directory", (out.parent / f"snap{tag}").as_posix(),
                    "-snapview", "native"])
    subprocess.run(cmd, cwd=str(mame_dir), env=env, capture_output=True, timeout=3600, **NO_WINDOW)
    return out


def spans(lo, n, limit):
    """Pixels [lo, lo + n) and the copy 0x200 lower, clipped to [0, limit)."""
    out = []
    for base in (lo, lo - 0x200):
        a, b = max(base, 0), min(base + n, limit)
        if a < b:
            out.append((a, b))
    return out


def frame_counts(rec, lut=None, blank=None):
    rows = [0] * SCREEN_H
    vis = [0] * SCREEN_H
    for i in range(512):
        w0 = int.from_bytes(rec[i * 8:i * 8 + 4], "big")
        w1 = int.from_bytes(rec[i * 8 + 4:i * 8 + 8], "big")
        x = w0 & 0x1FF
        w = ((w0 >> 9) & 7) + 1
        y = (w0 >> 16) & 0x1FF
        h = ((w0 >> 25) & 7) + 1
        tile0 = w1 & 0x1FFFF
        yflip = bool(w1 & 0x80000000)
        x = ((x + 4) & 0x1FF) - 16
        ys = spans(y, 16 * h, SCREEN_H)
        if not ys:
            continue
        # tile columns of this block that overlap the screen in X (either copy);
        # flipping mirrors positions, so the set of covered columns is the same
        cols = [t for t in range(w) if spans(x + 16 * t, 16, SCREEN_W)]
        for a, b in ys:
            base = y if a >= y else y - 0x200      # which copy this span is
            for line in range(a, b):
                rows[line] += w
                if blank is None:
                    vis[line] += len(cols)
                    continue
                dy = line - base                   # 0 .. 16*h-1 within the block
                slot = dy // 16                    # tile row on screen
                yct = (h - 1 - slot) if yflip else slot
                r = (15 - dy % 16) if yflip else dy % 16
                for xs in cols:
                    xct = (w - 1 - xs) if (w1 & 0x40000000) else xs
                    code = lut[(tile0 + yct * w + xct) & 0x1FFFF]
                    if not blank[((code * 16) + r) % len(blank)]:
                        vis[line] += 1
    return rows, vis


def analyse(path, lut=None, blank=None):
    data = path.read_bytes()
    nf = len(data) // LEN
    worst_rows = worst_vis = 0
    hist_rows, hist_vis = {}, {}
    where = None
    for f in range(nf):
        rows, vis = frame_counts(data[f * LEN:(f + 1) * LEN], lut, blank)
        for r, v in zip(rows, vis):
            hist_rows[r] = hist_rows.get(r, 0) + 1
            hist_vis[v] = hist_vis.get(v, 0) + 1
        if max(rows) > worst_rows:
            worst_rows = max(rows)
        if max(vis) > worst_vis:
            worst_vis = max(vis)
            where = (f, vis.index(worst_vis))
    return nf, worst_rows, worst_vis, where, hist_rows, hist_vis


def pct(hist, q):
    total = sum(hist.values())
    acc = 0
    for k in sorted(hist):
        acc += hist[k]
        if acc >= q * total:
            return k
    return max(hist)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sets", nargs="+")
    ap.add_argument("--skip", type=int, default=600)
    ap.add_argument("--frames", type=int, default=1800)
    ap.add_argument("--coin", type=int, default=0)
    ap.add_argument("--tag", default="")
    ap.add_argument("--reuse", action="store_true")
    ap.add_argument("--blank", action="store_true",
                    help="do not count visible rows that are all pen 0")
    a = ap.parse_args()
    print(f"{'set':16s} {'frames':>6s}  {'rows: max':>9s} {'p99.9':>6s}  "
          f"{'visible: max':>12s} {'p99.9':>6s} {'p99':>4s} {'mean':>5s}  worst at (frame, line)")
    for g in a.sets:
        path = REPO / "debug" / "sprload" / f"{g}{a.tag}.bin"
        if not a.reuse or not path.exists():
            run(g, a.skip, a.frames, a.coin, a.tag)
        if not path.exists() or path.stat().st_size < LEN:
            print(f"{g}{a.tag}: no dump (MAME failed?)")
            continue
        lut, blank = load_blank(g) if a.blank else (None, None)
        nf, wr, wv, where, hr, hv = analyse(path, lut, blank)
        mean = sum(k * c for k, c in hv.items()) / sum(hv.values())
        print(f"{g + a.tag:16s} {nf:6d}  {wr:9d} {pct(hr, 0.999):6d}  "
              f"{wv:12d} {pct(hv, 0.999):6d} {pct(hv, 0.99):4d} {mean:5.1f}  {where}")


if __name__ == "__main__":
    sys.exit(main())
