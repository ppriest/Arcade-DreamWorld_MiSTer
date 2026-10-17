#!/usr/bin/env python3
"""Render a captured frame the way dreamwld.cpp's screen_update does, and compare it with MAME's.

    python scripts/render_model.py debug/dreamwld-t19            # model.png, model_idx.bin, report
    python scripts/render_model.py debug/dreamwld-t19 --layers   # also l0.png, l1.png, spr.png

Input: a scripts/mame_capture.py directory (vram0/vram1/lineram/vregs/palette .bin, spritebuf.bin
= sprite RAM a frame earlier = m_spritebuf[0], the copy the frame was drawn from, reference.png,
manifest.txt) and the set's
ROM regions, taken from the .mra image build_mra.py makes (cached in debug/<set>-image.bin).

Output, beside the capture: model.png (RGB), model_idx.bin (palette index per pixel, u16 LE,
308 x 224 row-major), model_top.bin (the layer on top per pixel, u8: 0 layer 0, 1 layer 1,
2 sprite) -- scripts/frame_compare.py compares the RTL against these -- and the match against
reference.png. The model is checked against MAME here; the RTL is checked against the model.

Line references are to dreamwld.cpp at MAME_SRC.
"""
import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_mra   # noqa: E402

REPO = Path(__file__).resolve().parent.parent
W, H = 308, 224                      # set_visarea(0, 308-1, 0, 224-1)


def image_for(setname, rebuild=False):
    cache = REPO / "debug" / f"{setname}-image.bin"
    if rebuild or not cache.exists():
        img = build_mra.build(setname, build_mra.sdram_map(), REPO / "releases" / "_dev", write=False)
        if not img:
            sys.exit(f"{setname}: no ROM image (zip not found)")
        cache.write_bytes(img)
    return cache.read_bytes()


def regions(setname, rebuild=False):
    """Each region at its own ROM_REGION size: a gfx element wraps codes at its tile count."""
    img, sm = image_for(setname, rebuild), build_mra.sdram_map()
    body = build_mra.ers.blocks(build_mra.DRIVER.read_text(encoding="utf-8", errors="replace"))[setname]
    get = lambda region, key: img[sm[key]:sm[key] + build_mra.region_size(body, region)]
    return {"gfx1": get("gfx1", "SPRITES_BASE"), "gfx2": get("gfx2", "TILES_BASE"),
            "spritelut": get("spritelut", "SPRITELUT_BASE")}


def decode_16x16x4_packed_msb(data):
    """gfx_16x16x4_packed_msb: 8 bytes a row, the high nibble is the left pixel."""
    b = np.frombuffer(data, dtype=np.uint8).reshape(-1, 16, 8)
    out = np.empty((b.shape[0], 16, 16), dtype=np.uint8)
    out[:, :, 0::2] = b >> 4
    out[:, :, 1::2] = b & 15
    return out


def load_capture(d):
    be16 = lambda n: np.frombuffer((d / n).read_bytes(), dtype=">u2").astype(np.int64)
    be32 = lambda n: np.frombuffer((d / n).read_bytes(), dtype=">u4").astype(np.int64)
    return {"vram": [be16("vram0.bin"), be16("vram1.bin")], "lineram": be16("lineram.bin"),
            "vregs": be32("vregs.bin"), "palette": be16("palette.bin"), "spritebuf": be32("spritebuf.bin")}


def draw_tilemap(cap, tiles, layer):
    """One layer as palette indices (H x W) and its opaque mask; screen_update lines 338-385."""
    vregs = cap["vregs"]
    ctrl = int(vregs[4 + layer])                                    # 0x010 / 0x014
    scrolly = (int(vregs[2 * layer]) + 32) & 0xffffffff             # 0x000 / 0x008, + 32
    scrollx = (int(vregs[2 * layer + 1]) + (2 if layer else 0)) & 0xffffffff   # 0x004 / 0x00c
    bank = (ctrl >> 6) & 1
    size = (ctrl >> 10) & 1                                         # 0: 64x64 tiles, 1: 128x32
    cols, rows = (64, 64) if size == 0 else (128, 32)
    tw, th = cols * 16, rows * 16

    v = cap["vram"][layer][:cols * rows].reshape(rows, cols)        # TILEMAP_SCAN_ROWS
    code = ((v & 0x1fff) | (bank << 13)) % tiles.shape[0]
    colour = layer * 0x40 + (v >> 13)
    pens = tiles[code].transpose(0, 2, 1, 3).reshape(th, tw)        # rows of tiles -> pixel rows
    base = np.repeat(np.repeat(colour, 16, axis=0), 16, axis=1) * 16 + 0x800

    if ctrl & 0x0300:                                               # row scroll from lineram
        shift = (ctrl & 0x0200) >> 7                                # 0: per line, 4: per 16 lines
        line = cap["lineram"][layer * 0x100:(layer + 1) * 0x100]
        sx = [(scrollx + int(line[((y + 32) & 0xff) >> shift])) for y in range(H)]
    else:
        sx = [scrollx] * H

    idx = np.empty((H, W), dtype=np.int64)
    opaque = np.empty((H, W), dtype=bool)
    xs = np.arange(W)
    for y in range(H):
        ry = (y + scrolly) & (th - 1)
        rx = (xs + sx[y]) & (tw - 1)
        p = pens[ry, rx].astype(np.int64)
        idx[y] = base[ry, rx] + p
        opaque[y] = (p != 0) if layer else True                     # layer 1: set_transparent_pen(0)
    return idx, opaque


def draw_sprites(cap, tiles, lut):
    """draw_sprites, lines 203-260: 512 two-long entries from m_spritebuf[0], pen 0 transparent,
    later entries over earlier ones."""
    idx = np.zeros((H, W), dtype=np.int64)
    opaque = np.zeros((H, W), dtype=bool)
    src = cap["spritebuf"]
    ntiles = tiles.shape[0]
    for n in range(512):
        s0, s1 = int(src[2 * n]), int(src[2 * n + 1])
        xpos, ypos = s0 & 0x1ff, (s0 >> 16) & 0x1ff
        xsize, ysize = (s0 >> 9) & 7, (s0 >> 25) & 7
        tileno = s1 & 0x1ffff
        colour = (s1 >> 24) & 0x3f
        xflip, yflip = bool(s1 & 0x40000000), bool(s1 & 0x80000000)
        xinc = yinc = 16
        xpos = (xpos + 4) & 0x1ff
        if xflip:
            xinc = -16
            xpos += 16 * xsize
        if yflip:
            yinc = -16
            ypos += 16 * ysize
        xpos -= 16
        for yct in range(ysize + 1):
            for xct in range(xsize + 1):
                # tileno past the LUT reads beyond the region in MAME; wrapped here
                t = tiles[int(lut[tileno & 0x1ffff]) % ntiles]
                if xflip:
                    t = t[:, ::-1]
                if yflip:
                    t = t[::-1, :]
                for dx, dy in ((0, 0), (-0x200, 0), (-0x200, -0x200), (0, -0x200)):
                    blit(idx, opaque, t, colour * 16, xpos + xct * xinc + dx, ypos + yct * yinc + dy)
                tileno += 1
    return idx, opaque


def blit(idx, opaque, t, base, x, y):
    x0, y0, x1, y1 = max(x, 0), max(y, 0), min(x + 16, W), min(y + 16, H)
    if x0 >= x1 or y0 >= y1:
        return
    p = t[y0 - y:y1 - y, x0 - x:x1 - x]
    m = p != 0
    idx[y0:y1, x0:x1][m] = base + p[m].astype(np.int64)
    opaque[y0:y1, x0:x1] |= m


def pal_rgb(palette):
    """xRGB_555, MAME's pal5bit expansion."""
    r, g, b = (palette >> 10) & 31, (palette >> 5) & 31, palette & 31
    e = lambda c: (c << 3) | (c >> 2)
    return np.stack([e(r), e(g), e(b)], axis=-1).astype(np.uint8)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("capture")
    ap.add_argument("--layers", action="store_true", help="also write each layer alone")
    ap.add_argument("--rebuild-image", action="store_true")
    a = ap.parse_args()
    d = Path(a.capture)
    man = dict(l.split(" ", 1) for l in (d / "manifest.txt").read_text(encoding="utf-8").splitlines() if " " in l)
    setname = man["set"]

    reg = regions(setname, a.rebuild_image)
    spr_tiles = decode_16x16x4_packed_msb(reg["gfx1"])
    bg_tiles = decode_16x16x4_packed_msb(reg["gfx2"])
    # as_u16() on a little-endian host: the even byte (ROM_LOAD16_BYTE at 0) is the low byte
    lut = np.frombuffer(reg["spritelut"], dtype="<u2").astype(np.int64)
    cap = load_capture(d)

    l0, _ = draw_tilemap(cap, bg_tiles, 0)
    l1, m1 = draw_tilemap(cap, bg_tiles, 1)
    sp, ms = draw_sprites(cap, spr_tiles, lut)
    frame = np.where(ms, sp, np.where(m1, l1, l0))

    rgb = pal_rgb(cap["palette"])
    Image.fromarray(rgb[frame]).save(d / "model.png")
    frame.astype("<u2").tofile(d / "model_idx.bin")
    np.where(ms, 2, np.where(m1, 1, 0)).astype(np.uint8).tofile(d / "model_top.bin")   # 0 l0, 1 l1, 2 spr
    if a.layers:
        Image.fromarray(rgb[l0]).save(d / "l0.png")
        Image.fromarray(np.where(m1[..., None], rgb[l1], 0).astype(np.uint8)).save(d / "l1.png")
        Image.fromarray(np.where(ms[..., None], rgb[sp], 0).astype(np.uint8)).save(d / "spr.png")

    ref = np.asarray(Image.open(d / "reference.png").convert("RGB"))
    if ref.shape[:2] != (H, W):
        sys.exit(f"reference.png is {ref.shape[1]}x{ref.shape[0]}, expected {W}x{H}")
    # MAME's snapshot of a ROT90/ROT270 set keeps the native size but comes out turned 180
    # degrees (every baryon and baryona scene of model_sweep.py matches exactly once turned back)
    text = build_mra.DRIVER.read_text(encoding="utf-8", errors="replace")
    if build_mra.game_info(text, setname)["rot"] in (90, 270):
        ref = ref[::-1, ::-1]
    bad = np.any(ref != rgb[frame], axis=-1)
    n = int(bad.sum())
    print(f"{setname} {man.get('frame', '?')}: {W * H - n}/{W * H} pixels match MAME"
          + ("" if n else " (identical)"))
    if n:
        ys, xs = np.nonzero(bad)
        top = np.where(ms, "spr", np.where(m1, "l1", "l0"))
        for y, x in list(zip(ys, xs))[:10]:
            print(f"  ({x},{y}) model {tuple(rgb[frame[y, x]])} [{top[y, x]} 0x{frame[y, x]:03x}] "
                  f"MAME {tuple(ref[y, x])}")
        for k in ("l0", "l1", "spr"):
            print(f"  {k}: {int((bad & (top == k)).sum())} differing pixels on top")
    return 0 if n == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
