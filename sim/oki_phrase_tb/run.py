#!/usr/bin/env python3
"""Choose OKI phrases, run sim/oki_phrase_tb, compare with MAME's decoder (scripts/oki_model.py).

    python sim/oki_phrase_tb/run.py dreamwld              # prep, simulate, compare
    python sim/oki_phrase_tb/run.py dreamwld --compare    # compare an existing run

Cases: from each chip of the set, up to 8 phrases of bank 0 and, where a phrase lies above
0x30000 (banked), the same phrase in banks 1-3, at attenuations 0, 2 and 5 in turn, 400 samples
each. A case passes when the bench's samples equal jt6295's arithmetic for MAME's decode
((signal * vol) >> 5) from some start delay of 0-16 samples, and the MAME float values are
within 1 of them.
"""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))
import oki_model      # noqa: E402
import render_model   # noqa: E402

COUNT = 400
BASH = next((b for b in (os.environ.get("GIT_BASH"), "C:/Program Files/Git/bin/bash.exe",
                         shutil.which("bash")) if b and Path(b).exists()), "bash")


def cases(setname):
    out = []
    chips = ["oki1"] + (["oki2"] if any(oki_model.phrases(oki_model.rom_of(setname, "oki2"))) else [])
    for ci, chip in enumerate(chips, start=1):
        rom = oki_model.rom_of(setname, chip)
        ph = oki_model.phrases(rom)
        low = [p for p in ph if p[2] < 0x30000][:8]
        high = [p for p in ph if p[1] >= 0x30000][:1]
        k = 0
        for p, *_ in low:
            out.append((ci, p, (0, 2, 5)[k % 3], 0)); k += 1
        for p, *_ in high:
            for b in range(4):
                out.append((ci, p, (0, 2, 5)[k % 3], b)); k += 1
    return out


def compare(d, setname):
    lines = (d / "rtl.txt").read_text().split("\n")
    runs, cur = [], None
    for l in lines:
        if l.startswith("case"):
            cur = (tuple(int(x) for x in l.split()[1:]), [])
            runs.append(cur)
        elif l.strip() and cur:
            cur[1].append(int(l))
    bad = 0
    for (chip, phrase, att, bank, count), got in runs:
        rom = oki_model.rom_of(setname, "oki1" if chip == 1 else "oki2")
        mame, rtl = oki_model.decode(rom, phrase, att, bank)
        best = None
        for delay in range(17):
            seg = got[delay:]
            n = min(len(seg), len(rtl))
            if n < count - 17 and n < len(rtl):
                continue
            miss = sum(1 for i in range(n) if seg[i] != rtl[i])
            if best is None or miss < best[1]:
                best = (delay, miss, n)
        delay, miss, n = best
        drift = max(abs(rtl[i] - mame[i]) for i in range(n)) if n else 0
        ok = miss == 0 and drift < 1 and n > 0
        bad += not ok
        print(f"oki{chip} phrase {phrase:3} att {att} bank {bank}: {'PASS' if ok else 'FAIL'} "
              f"({n} samples from delay {delay}, {miss} differ from MAME's decode)")
    print(f"{len(runs) - bad}/{len(runs)} cases equal MAME's decoder")
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("set")
    ap.add_argument("--compare", action="store_true")
    a = ap.parse_args()
    d = REPO / "debug" / "oki_phrase" / a.set
    if not a.compare:
        d.mkdir(parents=True, exist_ok=True)
        cs = cases(a.set)
        (d / "cases.txt").write_text("".join(f"{c} {p} {t} {b} {COUNT}\n" for c, p, t, b in cs))
        render_model.image_for(a.set)
        sd = REPO / "debug" / f"{a.set}-image.sdram"
        if not sd.exists():
            img = bytearray(render_model.image_for(a.set))
            img[0::2], img[1::2] = img[1::2], img[0::2]
            sd.write_bytes(bytes(img))
        print(f"{len(cs)} cases; simulating")
        with open(d / "sim.log", "w") as log:
            subprocess.run([BASH, "scripts/run_sim.sh", "oki_phrase_tb", f"+DIR={d.relative_to(REPO).as_posix()}",
                            f"+IMG={sd.relative_to(REPO).as_posix()}"], cwd=REPO, stdout=log, stderr=subprocess.STDOUT)
    return compare(d, a.set)


if __name__ == "__main__":
    sys.exit(main())
