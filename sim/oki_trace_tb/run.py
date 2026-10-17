#!/usr/bin/env python3
"""Run sim/oki_trace_tb on a window and compare it with the model's mix of the same writes.

    python sim/oki_trace_tb/run.py dreamwld_play             # simulate, compare
    python sim/oki_trace_tb/run.py dreamwld_play --compare

Needs debug/oki_trace/<run>/window_events.txt and window_expected.txt (scripts/oki_trace.py
--window). The RTL starts each voice a few samples after the model; the comparison takes the
delay that lines them up best and reports how many samples are equal there, and writes both as
WAV files at the OKI rate for listening (rtl_window.wav, model_window.wav).
"""
import argparse
import os
import shutil
import subprocess
import sys
import wave
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[2]
BASH = next((b for b in (os.environ.get("GIT_BASH"), "C:/Program Files/Git/bin/bash.exe",
                         shutil.which("bash")) if b and Path(b).exists()), "bash")


def wav(p, x):
    with wave.open(str(p), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(6061)
        w.writeframes(np.asarray(x, dtype="<i2").tobytes())


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run")
    ap.add_argument("--compare", action="store_true")
    a = ap.parse_args()
    d = REPO / "debug" / "oki_trace" / a.run
    exp = np.array([int(x) for x in (d / "window_expected.txt").read_text().split()])
    setname = a.run.split("_")[0]
    if not a.compare:
        with open(d / "sim.log", "w") as log:
            subprocess.run([BASH, "scripts/run_sim.sh", "oki_trace_tb", f"+DIR={d.relative_to(REPO).as_posix()}",
                            f"+IMG=debug/{setname}-image.sdram", f"+N={len(exp) + 32}"],
                           cwd=REPO, stdout=log, stderr=subprocess.STDOUT)
    got = np.array([int(x) for x in (d / "rtl_window.txt").read_text().split()])
    best = None
    for delay in range(0, 32):
        n = min(len(exp), len(got) - delay)
        eq = int(np.sum(got[delay:delay + n] == exp[:n]))
        if best is None or eq > best[1]:
            best = (delay, eq, n)
    delay, eq, n = best
    err = np.abs(got[delay:delay + n] - exp[:n])
    active = int(np.sum(exp[:n] != 0))
    print(f"{a.run}: {n} samples, {active} not silent; at delay {delay}: {eq} equal "
          f"({100 * eq / n:.2f}%), largest difference {int(err.max())}, "
          f"{int(np.sum(err > 0))} samples differ")
    wav(d / "rtl_window.wav", got[delay:delay + n])
    wav(d / "model_window.wav", exp[:n])
    return 0 if eq == n else 1


if __name__ == "__main__":
    sys.exit(main())
