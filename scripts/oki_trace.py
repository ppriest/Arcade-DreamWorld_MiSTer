#!/usr/bin/env python3
"""MAME's OKI writes and audio for a run, and the transcribed model's mix of them.

    python scripts/oki_trace.py dreamwld --seconds 20                 # attract
    python scripts/oki_trace.py dreamwld --seconds 40 --coin 600      # coin, start, play

Runs MAME with scripts/mame/okitrace.lua (every write to 0xC00018/0xC00028 and the bank
registers 0xC0000F/0xC0002F, with its time) and -wavwrite. Then plays the trace through
scripts/oki_model.py's decoder as okim6295.cpp does -- a command pair starts a voice that is not
playing, 0x08-0x78 stop voices, samples at 1 MHz / 165 -- sums both chips into one mono stream
(full-volume voice = full scale, as MAME), and compares it with MAME's recording: the lag that
lines them up and the correlation there.

Writes debug/oki_trace/<set>[_play]/: okitrace.txt, mame.wav, model.wav (48 kHz), events.txt
(the decoded command stream, for sim/oki_trace_tb).
"""
import argparse
import os
import subprocess
import sys
import wave
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mame_capture as mc   # noqa: E402
import oki_model            # noqa: E402

REPO = Path(__file__).resolve().parent.parent
RATE = 1e6 / 165            # pin 7 low


def capture(setname, out, seconds, coin):
    mame_dir, exe = mc.mame_paths()
    cmd = [str(exe), setname, "-nodebug", "-nowindow", "-video", "none", "-skip_gameinfo",
           "-nothrottle", "-autoboot_delay", "0", "-autoboot_script", str(mc.LUA_DIR / "run.lua"),
           "-rompath", mc.rompath(mame_dir), "-wavwrite", str((out / "mame.wav").resolve()),
           "-seconds_to_run", str(seconds + 5)]
    env = dict(os.environ, **mc.lua_runner_env("okitrace.lua"), CORE_OUT=out.as_posix(),
               CORE_SECONDS=str(seconds), CORE_COIN=str(coin))
    r = subprocess.run(cmd, cwd=mame_dir, env=env, capture_output=True, text=True, **mc.NO_WINDOW)
    mc.check_lua_error(out)
    if "CORE_OKITRACE_OK" not in r.stdout + r.stderr:
        sys.exit("MAME run did not finish:\n" + (r.stdout + r.stderr)[-800:])


def events(out):
    """(time, chip 1/2, 'data'|'bank', value) from the tap's offset and lanes."""
    ev = []
    for line in (out / "okitrace.txt").read_text().split("\n"):
        if not line.strip():
            continue
        t, off, data, mask = line.split()
        t, off, data, mask = float(t), int(off, 16), int(data, 16), int(mask, 16)
        if off == 0xc00018 and mask & 0xff000000:
            ev.append((t, 1, "data", data >> 24 & 255))
        elif off == 0xc00028 and mask & 0xff000000:
            ev.append((t, 2, "data", data >> 24 & 255))
        elif off == 0xc0000c and mask & 0xff:
            ev.append((t, 1, "bank", data & 3))
        elif off == 0xc0002c and mask & 0xff:
            ev.append((t, 2, "bank", data & 3))
    return ev


class Chip:
    """okim6295_device: command pairing, four voices, the bank of dreamwld.cpp's map. With
    rtl=True the voices carry jt6295's integer samples ((signal * vol) >> 5)."""

    def __init__(self, rom, rtl=False):
        self.rom, self.bank, self.cmd, self.rtl = rom, 0, -1, rtl
        self.voices = [None] * 4        # (samples list, position)

    def write(self, d):
        if self.cmd != -1:
            for v in range(4):
                if d >> (4 + v) & 1 and self.voices[v] is None:
                    mame, rtl = oki_model.decode(self.rom, self.cmd, d & 15, self.bank)
                    if mame:
                        self.voices[v] = [rtl if self.rtl else mame, 0]
            self.cmd = -1
        elif d & 0x80:
            self.cmd = d & 0x7f
        else:
            for v in range(4):
                if d >> (3 + v) & 1:
                    self.voices[v] = None

    def sample(self):
        s = 0
        for v in range(4):
            if self.voices[v] is not None:
                seq, i = self.voices[v]
                s += seq[i]
                i += 1
                self.voices[v] = None if i >= len(seq) else [seq, i]
        return s


def model_mix(setname, ev, seconds):
    chips = {1: Chip(oki_model.rom_of(setname, "oki1")), 2: Chip(oki_model.rom_of(setname, "oki2"))}
    n = int(seconds * RATE)
    out = np.zeros(n)
    j = 0
    for k in range(n):
        t = k / RATE
        while j < len(ev) and ev[j][0] <= t:
            _, c, kind, v = ev[j]
            if kind == "bank":
                chips[c].bank = v
            else:
                chips[c].write(v)
            j += 1
        out[k] = (chips[1].sample() + chips[2].sample()) / 2048.0     # full-volume voice = 1.0
    return out


def window(setname, ev, start, dur, out):
    """The bench's stimulus and expectation for [start, start + dur): every write in the window
    as "clk chip kind value" (54 MHz from the window start; banks set before it go first, at clk
    0), and jt6295's mixed output for the same writes, one OKI sample a line."""
    lines = []
    banks = {1: 0, 2: 0}
    for t, c, k, v in ev:
        if t < start and k == "bank":
            banks[c] = v
    lines += [f"0 {c} bank {banks[c]}\n" for c in (1, 2)]
    lines += [f"{int(round((t - start) * 54e6)) + 100} {c} {k} {v}\n" for t, c, k, v in ev if start <= t < start + dur]
    (out / "window_events.txt").write_text("".join(lines))
    chips = {1: Chip(oki_model.rom_of(setname, "oki1"), True), 2: Chip(oki_model.rom_of(setname, "oki2"), True)}
    for c in (1, 2):
        chips[c].bank = banks[c]
    wev = [(t - start, c, k, v) for t, c, k, v in ev if start <= t < start + dur]
    exp, j = [], 0
    for k in range(int(dur * RATE)):
        while j < len(wev) and wev[j][0] <= k / RATE:
            _, c, kind, v = wev[j]
            if kind == "bank":
                chips[c].bank = v
            else:
                chips[c].write(v)
            j += 1
        m = 16 * (chips[1].sample() + chips[2].sample())
        exp.append(max(-32768, min(32767, m)))
    (out / "window_expected.txt").write_text("".join(f"{x}\n" for x in exp))
    return len(lines), len(exp)


def read_wav(p):
    with wave.open(str(p)) as w:
        ch, rate, n = w.getnchannels(), w.getframerate(), w.getnframes()
        a = np.frombuffer(w.readframes(n), dtype="<i2").astype(np.float64).reshape(-1, ch)[:, 0]
    return a / 32768.0, rate


def write_wav(p, x, rate):
    with wave.open(str(p), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate)
        w.writeframes(np.clip(np.round(x * 32767), -32768, 32767).astype("<i2").tobytes())


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("set")
    ap.add_argument("--seconds", type=float, default=20)
    ap.add_argument("--coin", type=int, default=0)
    ap.add_argument("--reuse", action="store_true", help="use the existing MAME run")
    ap.add_argument("--window", type=float, nargs=2, metavar=("START", "SECONDS"),
                    help="also write the RTL bench's stimulus and expectation for this window")
    a = ap.parse_args()
    out = REPO / "debug" / "oki_trace" / (a.set + ("_play" if a.coin else ""))
    out.mkdir(parents=True, exist_ok=True)
    if not a.reuse:
        capture(a.set, out, a.seconds, a.coin)
    ev = events(out)
    (out / "events.txt").write_text("".join(f"{t:.9f} {c} {k} {v}\n" for t, c, k, v in ev))
    if a.window:
        nw, ns = window(a.set, ev, a.window[0], a.window[1], out)
        print(f"window {a.window[0]}-{a.window[0] + a.window[1]} s: {nw} writes, {ns} samples expected")
    mix = model_mix(a.set, ev, a.seconds)
    ref, rate = read_wav(out / "mame.wav")
    # the model at MAME's output rate, held between its samples
    idx = np.minimum((np.arange(int(a.seconds * rate)) * RATE / rate).astype(int), len(mix) - 1)
    up = mix[idx]
    write_wav(out / "model.wav", up, rate)
    n = min(len(up), len(ref))
    up, ref = up[:n], ref[:n]
    best = max(range(-2000, 2001, 1), key=lambda L: float(np.dot(up[max(0, -L):n - max(0, L)], ref[max(0, L):n - max(0, -L)])))
    a1, b1 = up[max(0, -best):n - max(0, best)], ref[max(0, best):n - max(0, -best)]
    corr = float(np.dot(a1, b1) / (np.linalg.norm(a1) * np.linalg.norm(b1) + 1e-12))
    print(f"{a.set}: {len(ev)} OKI writes in {a.seconds:.0f} s; MAME's audio lags the model by "
          f"{best} samples ({best / rate * 1e3:.2f} ms); correlation {corr:.4f}; "
          f"RMS model {np.sqrt(np.mean(a1 ** 2)):.4f} MAME {np.sqrt(np.mean(b1 ** 2)):.4f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
