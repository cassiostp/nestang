#!/usr/bin/env python3
"""Golden model of src/video_fx.v, written from the spec (the video_config table and the
mask / grid definitions in the header of video_fx.v), not from the Verilog.

  model.py selfcheck      hand-computed spot values, fixed point error against real arithmetic
  model.py gen            write the test vectors (vec_*.hex) for tb_video_fx.v
  model.py check LOGFILE  check a log of the filters running inside nes2hdmi
                          (written by tb_nes_fx.v) against the model
  model.py check_smooth LOGFILE SRCFILE
                          check a log of the smoothing running inside nes2hdmi
                          (tb_nes_smooth.v: nes_smooth.log, nes_src.hex) against the model

The smoothing (video_config[19:18], see the header of src/smooth.v) is modelled from its
definition: the area an output pixel covers in the source picture, the weights of the source
pixels it overlaps (sharp) or the bilinear weights at its centre (soft), in 1/256 and rounded
to nearest, the vertical blend first and then the horizontal one, each rounded to nearest.

Run with python3 -I.
"""
import os
import random
import re
import sys
from fractions import Fraction

HERE = os.path.dirname(os.path.abspath(__file__))


def clamp(v):
    return 0 if v < 0 else 255 if v > 255 else v


def gamma_table(code):
    if code == 0:
        return list(range(256))
    g = {1: 1.2, 2: 0.83, 3: 2.4 / 2.2}[code]
    return [int(255 * (i / 255) ** g + 0.5) for i in range(256)]


GAMMA = [gamma_table(c) for c in range(4)]


def signed3(v):
    return v - 8 if v >= 4 else v


def colour(rgb, bright, contrast, sat, gamma):
    """brightness -> contrast -> saturation -> gamma, n signed -4..3; floor((x + half) / d)"""
    c = [clamp(x + 16 * bright) for x in rgb]
    f = 8 + contrast
    c = [clamp(128 + ((x - 128) * f + 4) // 8) for x in c]
    y = (77 * c[0] + 150 * c[1] + 29 * c[2]) >> 8
    s = 4 + sat
    c = [clamp(y + ((x - y) * s + 2) // 4) for x in c]
    return [GAMMA[gamma][x] for x in c]


def colour_ideal(rgb, bright, contrast, sat, gamma):
    """the same in real numbers, to bound the fixed point error"""
    c = [min(255.0, max(0.0, x + 16.0 * bright)) for x in rgb]
    c = [min(255.0, max(0.0, 128 + (x - 128) * (8 + contrast) / 8.0)) for x in c]
    y = (77 * c[0] + 150 * c[1] + 29 * c[2]) / 256.0
    c = [min(255.0, max(0.0, y + (x - y) * (4 + sat) / 4.0)) for x in c]
    if gamma:
        g = {1: 1.2, 2: 0.83, 3: 2.4 / 2.2}[gamma]
        c = [255 * (x / 255.0) ** g for x in c]
    return c


def dim(c, darkness):
    """sl_dim: 25, 50, 75, 100 % dark"""
    return [x - (x >> 2) if darkness == 0 else x >> 1 if darkness == 1 else x >> 2 if darkness == 2 else 0
            for x in c]


def mask_loss(x, y, mtype, mstr):
    """per channel (R, G, B) 8ths lost by the CRT mask at output pixel (x, y)"""
    if mtype == 0:
        return [0, 0, 0]
    loss = 2 + mstr
    phase = x % 3
    if mtype == 3:
        phase = (x + (y & 1)) % 3
    out = [0 if phase == ch else loss for ch in range(3)]
    if mtype == 2:
        triad = x // 3
        slot_row = (y % 4) == (2 if triad & 1 else 0)
        if slot_row:
            out = [loss] * 3
    return out


def post(c, x, y, cfg, grid_hit):
    mtype = (cfg >> 11) & 3
    mstr = (cfg >> 13) & 3
    grid = (cfg >> 15) & 1
    gstr = (cfg >> 16) & 3
    gl = 1 + gstr if (grid and grid_hit) else 0
    ml = mask_loss(x, y, mtype, mstr)
    return [(ch * ((8 - gl) * (8 - m))) >> 6 for ch, m in zip(c, ml)]


def fx(rgb, pic, dark, darkness, col_last, row_last, x, y, cfg):
    """one pixel through video_fx: rgb = (r, g, b), x, y = the output position"""
    if not pic:
        c = list(rgb)
        pic_post = False
    else:
        c = colour(rgb, signed3(cfg & 7), signed3((cfg >> 3) & 7), signed3((cfg >> 6) & 7), (cfg >> 9) & 3)
        pic_post = True
    if dark:
        c = dim(c, darkness)
    if pic_post:
        c = post(c, x, y, cfg, col_last or row_last)
    return tuple(c)


def pack(c):
    return (c[0] << 16) | (c[1] << 8) | c[2]


def unpack(v):
    return ((v >> 16) & 255, (v >> 8) & 255, v & 255)


def selfcheck():
    """hand-computed spot values and the fixed point error against real arithmetic"""
    assert colour((100, 100, 100), 1, 0, 0, 0) == [116] * 3
    assert colour((250, 10, 128), 3, 0, 0, 0) == [255, 58, 176]
    assert colour((255, 255, 255), -4, 0, 0, 0) == [191] * 3
    assert colour((200, 60, 128), 0, -4, 0, 0) == [164, 94, 128]          # halfway to grey
    assert colour((255, 0, 0), 0, 0, -4, 0) == [76, 76, 76]               # (77 * 255) >> 8
    assert colour((255, 0, 0), 0, 0, 3, 0) == [255, 0, 0]                 # 7/4 saturation, clamped
    assert colour((90, 120, 150), 0, 0, 0, 0) == [90, 120, 150]
    assert colour((128, 128, 128), 0, 0, 0, 1)[0] == 112                  # 255 * (128 / 255) ** 1.2 = 111.52
    assert colour((128, 128, 128), 0, 0, 0, 2)[0] == 144                  # ** 0.83 = 143.91
    assert colour((128, 128, 128), 0, 0, 0, 3)[0] == 120                  # ** (2.4 / 2.2) = 120.23
    # the fixed point error against real arithmetic: a few LSB at most
    rng = random.Random(1)
    worst = 0.0
    for _ in range(20000):
        rgb = [rng.randrange(256) for _ in range(3)]
        b, c, s, g = rng.randrange(-4, 4), rng.randrange(-4, 4), rng.randrange(-4, 4), rng.randrange(4)
        got = colour(rgb, b, c, s, g)
        ideal = colour_ideal(rgb, b, c, s, g)
        worst = max(worst, max(abs(a - i) for a, i in zip(got, ideal)))
    # (2.2 LSB without gamma: the 8 bit roundings add up, saturation + 3 doubles them;
    #  the 0.83 gamma is steep near black)
    assert worst <= 4.0, worst
    # no filters: identity, whatever the other fields
    assert colour((1, 2, 3), 0, 0, 0, 0) == [1, 2, 3]
    return worst


def gen():
    worst = selfcheck()
    cases = []          # (cfg, nx, nrows, [rows of [(in word, out word)]])
    rng = random.Random(20261010)

    def word_in(rgb, pic, dark, darkness, col, row):
        return pack(rgb) | (pic << 24) | (dark << 25) | (col << 26) | (row << 27) | (darkness << 28)

    # 1. colour: every brightness, contrast, saturation, gamma
    base_px = [(0, 0, 0), (255, 255, 255), (255, 0, 0), (0, 255, 0), (0, 0, 255), (128, 128, 128),
               (127, 127, 127), (1, 1, 1), (254, 254, 254), (255, 255, 0), (0, 255, 255), (255, 0, 255),
               (0x30, 0x30, 0x30), (200, 60, 128), (60, 200, 128), (16, 240, 100)]
    for g in range(4):
        for s in range(8):
            for c in range(8):
                for b in range(8):
                    cfg = b | (c << 3) | (s << 6) | (g << 9)
                    px = list(base_px) + [tuple(rng.randrange(256) for _ in range(3)) for _ in range(240)]
                    row = []
                    for rgb in px:
                        row.append((word_in(rgb, 1, 0, 0, 0, 0), pack(fx(rgb, 1, 0, 0, 0, 0, 0, 1, cfg))))
                    cases.append((cfg, len(px), 1, [row]))

    # 2. mask and grid over a whole output row, rows cy = 1..8
    def mask_case(cfg):
        rows = []
        for r in range(8):
            y = r + 1
            row = []
            for x in range(1280):
                pic = 1 if 8 <= x < 1272 else 0
                rgb = (rng.randrange(120, 256), rng.randrange(120, 256), rng.randrange(120, 256)) if pic else (0x30, 0x30, 0x30)
                col = 1 if x % 4 == 3 else 0
                rowl = 1 if y % 5 == 4 else 0
                row.append((word_in(rgb, pic, 0, 0, col, rowl), pack(fx(rgb, pic, 0, 0, col, rowl, x, y, cfg))))
            rows.append(row)
        return (cfg, 1280, 8, rows)

    for mt in range(4):
        for ms in range(4):
            cases.append(mask_case((mt << 11) | (ms << 13)))
            for gs in range(4):
                cases.append(mask_case((mt << 11) | (ms << 13) | (1 << 15) | (gs << 16)))
    cases.append(mask_case(0))
    # grid with the mask off, strength 0..3, and a grid that is off but with a strength set
    cases.append(mask_case((0 << 11) | (3 << 16)))

    # 3. everything at once: random settings, random flags, random pixels (cy = 1..4)
    for _ in range(300):
        cfg = rng.randrange(1 << 18)
        darkness = rng.randrange(4)             # a setting, not a per-pixel signal
        rows = []
        for r in range(4):
            y = r + 1
            row = []
            for x in range(400):
                pic = 1 if (x >= 8 and rng.random() < 0.9) else 0
                rgb = tuple(rng.randrange(256) for _ in range(3)) if pic else (0x30, 0x30, 0x30)
                dark = 1 if rng.random() < 0.3 else 0
                col = 1 if rng.random() < 0.2 else 0
                rowl = 1 if rng.random() < 0.2 else 0
                row.append((word_in(rgb, pic, dark, darkness, col, rowl),
                            pack(fx(rgb, pic, dark, darkness, col, rowl, x, y, cfg))))
            rows.append(row)
        cases.append((cfg, 400, 4, rows))

    with open(os.path.join(HERE, "vec_case.hex"), "w") as f:
        f.write("%08x\n" % len(cases))
        for cfg, nx, nr, _ in cases:
            f.write("%08x\n%08x\n%08x\n" % (cfg, nx, nr))
    with open(os.path.join(HERE, "vec_in.hex"), "w") as fi, open(os.path.join(HERE, "vec_exp.hex"), "w") as fe:
        for _, _, _, rows in cases:
            for row in rows:
                for win, wexp in row:
                    fi.write("%08x\n" % win)
                    fe.write("%06x\n" % wexp)
    print("model: %d cases, colour error vs real arithmetic <= %.2f LSB" % (len(cases), worst))


# ---- smoothing ---------------------------------------------------------------------------

NES_SV = os.path.join(HERE, "..", "..", "src", "nes2hdmi.sv")
LINES, COLS = 224, 256              # the NES picture


def load_palette():
    """the 2C02 palette, 64 entries, as listed in nes2hdmi.sv"""
    pal = {}
    with open(NES_SV) as f:
        for m in re.finditer(r"NES_PALETTE\[(\d+)\]\s*=\s*24'h([0-9a-fA-F]+)", f.read()):
            pal[int(m.group(1))] = int(m.group(2), 16)
    assert sorted(pal) == list(range(64)), "palette not found in nes2hdmi.sv"
    return [unpack(pal[i]) for i in range(64)]


def load_src(path):
    """the frame buffer dumped by the testbench (6 bit palette indices, 256 x 240), the 224
    lines the scaler shows (the first 8 are the overscan it skips), as RGB"""
    pal = load_palette()
    idx = []
    with open(path) as f:
        for line in f:
            t = line.split()
            if t and t[0][0] not in "@/":
                idx.append(int(t[0], 16))
    assert len(idx) == 256 * 240, len(idx)
    return [[pal[idx[(8 + y) * 256 + x]] for x in range(COLS)] for y in range(LINES)]


def blend_weight(n, step, size, soft, count):
    """Output pixel n of one axis, in which a source pixel is `size` units and an output pixel
    `step` units. Returns (cur, nbr, w): the source pixel the scaler shows (the one that holds
    the start of the output pixel), the neighbour it is blended with and the weight of the
    neighbour in 1/256. sharp: the share of the output pixel in the next source pixel. soft:
    the distance from the output pixel's centre to the source pixel's centre, as a share of a
    source pixel, the neighbour being on the side of the output pixel's centre. A neighbour
    that does not exist (past the first or last of `count`) has weight 0."""
    f = Fraction(step, size)                    # source pixels per output pixel
    left = n * f
    cur = left.numerator // left.denominator
    if not soft:
        over = left + f - (cur + 1)
        frac = max(Fraction(0), over) / f
        nbr = cur + 1
    else:
        d = left + f / 2 - (cur + Fraction(1, 2))
        nbr = cur + 1 if d >= 0 else cur - 1
        frac = abs(d)
    w = int(frac * 256 + Fraction(1, 2))        # rounded to nearest, half up
    if nbr < 0 or nbr >= count:
        w, nbr = 0, cur
    return cur, nbr, w


def lerp(c, n, w):
    """c moved towards n by w / 256, rounded to nearest (half up)"""
    return c + ((n - c) * w + 128) // 256


def smooth_geometry(geom):
    """(columns, left column of the picture, rows, top row of the picture) of the output; the
    picture is 960 x 720 and 896 x 672 with 3 rows per source line in the integer geometry"""
    return (896, 192, 672, 24) if geom else (960, 160, 720, 0)


class Smooth:
    """the smoothed picture of a source image: pixel(mode, geom, m, n) is the output pixel at
    column m, row n of the picture (mode 0 is the nearest neighbour the scaler shows)"""

    def __init__(self, src):
        self.src = src
        self.vrows = {}
        self.hw = {}

    def vrow(self, mode, geom, n):
        key = (mode, geom, n)
        if key not in self.vrows:
            if geom:
                cur, nbr, w = blend_weight(n, 1, 3, mode == 2, LINES)
            else:
                cur, nbr, w = blend_weight(n, LINES, 720, mode == 2, LINES)
            if mode not in (1, 2):
                w = 0
            a, b = self.src[cur], self.src[nbr]
            self.vrows[key] = [tuple(lerp(a[c][k], b[c][k], w) for k in range(3)) for c in range(COLS)]
        return self.vrows[key]

    def pixel(self, mode, geom, m, n):
        key = (mode, geom, m)
        if key not in self.hw:
            xsize = smooth_geometry(geom)[0]
            cur, nbr, w = blend_weight(m, COLS, xsize, mode == 2, COLS)
            self.hw[key] = (cur, nbr, w if mode in (1, 2) else 0)
        cur, nbr, w = self.hw[key]
        v = self.vrow(mode, geom, n)
        return tuple(lerp(v[cur][k], v[nbr][k], w) for k in range(3))


def rtl_weight(pos, step, size, soft):
    """the weight arithmetic of smooth_axis (src/smooth.v): the numerator times a 16 bit
    reciprocal; used to check that the constants it is given are exact"""
    if soft:
        num = abs(2 * pos + step - size)
        k = (65536 * 128 + size // 2) // size
    else:
        num = max(0, pos + step - size)
        k = (65536 * 256 + step // 2) // step
    return min(255, (num * k + 32768) >> 16)


def selfcheck_smooth():
    """hand-computed weights; the reciprocal arithmetic against the exact fractions"""
    # 960 columns, 3.75 per source pixel: 0.8 of the way through source pixel 0 at m = 3,
    # a quarter of that output pixel is in source pixel 1
    assert blend_weight(3, 256, 960, False, 256) == (0, 1, 64)
    assert blend_weight(4, 256, 960, False, 256) == (1, 2, 0)
    assert blend_weight(7, 256, 960, False, 256) == (1, 2, 128)      # [1.8667, 2.1333): half in pixel 2
    assert blend_weight(3, 256, 896, False, 256) == (0, 1, 128)      # [0.857, 1.143): half each
    assert blend_weight(959, 256, 960, False, 256) == (255, 255, 0)  # nothing past the last pixel
    assert blend_weight(3, 224, 720, False, 224) == (0, 1, 201)      # rows: [0.933, 1.244): 0.2444 / 0.3111
    # soft: output pixel m has its centre at (m + 1/2) * 4/15 source pixels
    assert blend_weight(0, 256, 960, True, 256) == (0, 0, 0)         # the first pixel has no left neighbour
    assert blend_weight(1, 256, 960, True, 256) == (0, 0, 0)         # centre 0.4, 0.1 before the centre of pixel 0: no pixel -1
    assert blend_weight(2, 256, 960, True, 256) == (0, 1, 43)        # centre 0.667, 0.1667 past the centre of pixel 0
    assert blend_weight(5, 256, 960, True, 256) == (1, 0, 9)         # centre 1.4667, 0.0333 before the centre of pixel 1
    assert blend_weight(6, 256, 960, True, 256) == (1, 2, 60)        # centre 1.7333, 0.2333 past it
    assert blend_weight(0, 1, 3, True, 224) == (0, 0, 0)             # integer rows: first line, first row has no line above
    assert blend_weight(3, 1, 3, True, 224) == (1, 0, 85)            # a third of a line towards the line above
    assert blend_weight(4, 1, 3, True, 224) == (1, 2, 0)             # the middle row is the line
    assert blend_weight(5, 1, 3, True, 224) == (1, 2, 85)
    assert blend_weight(671, 1, 3, True, 224) == (223, 223, 0)       # and no line below the last
    assert all(blend_weight(r, 1, 3, False, 224)[2] == 0 for r in range(672))     # sharp has nothing to blend
    assert lerp(100, 200, 64) == 125 and lerp(200, 100, 64) == 175 and lerp(10, 11, 128) == 11
    assert lerp(10, 11, 127) == 10 and lerp(255, 0, 255) == 1 and lerp(0, 255, 255) == 254
    # smooth_axis: the 16 bit reciprocal gives the exact rounded weight at every position
    for step, size in ((256, 960), (256, 896), (224, 720)):
        for soft in (False, True):
            for pos in range(size):
                if soft:
                    exact = Fraction(abs(2 * pos + step - size), size) * 128
                else:
                    exact = Fraction(max(0, pos + step - size), step) * 256
                want = min(255, int(exact + Fraction(1, 2)))
                assert rtl_weight(pos, step, size, soft) == want, (step, size, soft, pos)
    # and the position model (xcnt / ycnt) gives the same weights as the pixel model
    for step, size, count in ((256, 960, 256), (256, 896, 256), (224, 720, 224)):
        for soft in (False, True):
            for n in range(size * count // step):
                pos = (n * step) % size
                cur, nbr, w = blend_weight(n, step, size, soft, 10 ** 6)
                if nbr != cur:                  # (the first pixel has no neighbour before it)
                    assert rtl_weight(pos, step, size, soft) == w, (step, size, soft, n)
    return True


def check_smooth(logpath, srcpath):
    """lines: "F on out thick darkness overlay video_config" starting a frame, then
    "cfg x y pic dark darkness 0 0 in out" for the pixels of the logged rows"""
    selfcheck_smooth()
    model = Smooth(load_src(srcpath))
    pos_off = 1             # the picture's first column is shown while the hdmi counter cx = XSTART + 1
    n = bad = 0
    frames = 0
    stats = {}
    f_on = f_out = f_thick = f_dk = f_over = 0
    cfg = mode = 0
    geom = False

    def fail(what, t, want, got):
        nonlocal bad
        bad += 1
        if bad <= 12:
            print("MISMATCH %s cfg=%08x x=%s y=%s on=%d out=%d: got %s, want %s" % (what, cfg, t[1], t[2], f_on, f_out, got, want))

    with open(logpath) as f:
        for line in f:
            t = line.split()
            if t[0] == "F":
                f_on, f_out, f_thick, f_dk, f_over = [int(v) for v in t[1:6]]
                cfg = int(t[6], 16)
                mode = (cfg >> 18) & 3
                mode = 0 if mode == 3 else mode
                geom = bool(f_on and not f_out and not f_over)
                frames += 1
                key = (frames, f_on, f_out, f_thick, f_dk, f_over, cfg)
                stats[key] = [0, 0, 0]      # pixels, picture pixels, picture pixels that differ from the nearest neighbour
                continue
            x, y, pic, dark, darkness = [int(v) for v in t[1:6]]
            rgb = unpack(int(t[8], 16))
            got = unpack(int(t[9], 16))
            n += 1
            xsize, xstart, nrows, ytop = smooth_geometry(geom)
            m, r = x - (xstart + pos_off), y - ytop
            in_pic = (0 <= m < xsize) and (0 <= r < nrows) and not f_over
            st = stats[key]
            st[0] += 1
            if f_over:
                pass                                # the overlay is whatever it is; nothing is smoothed
            elif pic != in_pic:
                fail("picture flag", t, int(in_pic), pic)
            elif in_pic:
                st[1] += 1
                want = model.pixel(mode, geom, m, r)
                if rgb != want:
                    fail("smoothed pixel", t, "%02x%02x%02x" % want, "%02x%02x%02x" % rgb)
                if want != model.pixel(0, geom, m, r):
                    st[2] += 1
            else:
                if rgb != (0x30, 0x30, 0x30):
                    fail("border", t, "303030", "%02x%02x%02x" % rgb)
            # the scanline darkening: the last dark rows of each source line (integer scale) or of every 3 output rows
            dthin = 2 if f_thick else 1
            if f_over or not in_pic:
                want_dark = 0
            elif f_on and not f_out:
                want_dark = int(r % 3 >= 3 - dthin)
            elif f_on and f_out:
                want_dark = int(y % 3 >= 3 - dthin)
            else:
                want_dark = 0
            if not f_over and (dark != want_dark or (in_pic and darkness != f_dk)):
                fail("scanline flags", t, "dark=%d darkness=%d" % (want_dark, f_dk), "dark=%d darkness=%d" % (dark, darkness))
            # the filters on the smoothed picture
            want_out = fx(rgb, pic, dark, darkness, 0, 0, x, y, cfg & 0x3FFFF)
            if got != want_out:
                fail("filters", t, "%02x%02x%02x" % want_out, "%02x%02x%02x" % got)
    print("smooth check: %d pixels in %d frames, %d mismatches" % (n, frames, bad))
    for key, st in stats.items():
        fr, on, out, thick, dk, over, c = key
        print("  frame %2d: scanlines=%d out=%d thick=%d dark=%d overlay=%d video_config=%08x: %d logged, %d picture, %d differ from nearest neighbour"
              % (fr, on, out, thick, dk, over, c, st[0], st[1], st[2]))
        smode = (c >> 18) & 3
        if smode in (1, 2) and not over and st[2] == 0:
            print("    mode %d blended nothing" % smode)
            bad += 1
        if smode in (0, 3) and st[2] != 0:
            print("    mode %d changed the picture" % smode)
            bad += 1
        if not over and st[1] == 0:
            print("    no picture pixels logged")
            bad += 1
    sys.exit(1 if bad or n == 0 else 0)


def check(path):
    """lines: cfg_hex x y pic dark darkness col row in_hex out_hex"""
    n = bad = 0
    pics = 0
    changed = {}        # per setting: picture pixels the filters changed
    with open(path) as f:
        for line in f:
            t = line.split()
            cfg = int(t[0], 16)
            x, y, pic, dark, darkness, col, row = [int(v) for v in t[1:8]]
            rgb = unpack(int(t[8], 16))
            got = unpack(int(t[9], 16))
            want = fx(rgb, pic, dark, darkness, col, row, x, y, cfg)
            n += 1
            pics += pic
            if pic and not dark and got != rgb:
                changed[cfg] = changed.get(cfg, 0) + 1
            if got != want:
                bad += 1
                if bad <= 10:
                    print("MISMATCH cfg=%08x x=%d y=%d pic=%d dark=%d/%d col=%d row=%d in=%06x got=%s want=%s"
                          % (cfg, x, y, pic, dark, darkness, col, row, pack(rgb), "%02x%02x%02x" % got, "%02x%02x%02x" % want))
    print("model check: %d pixels (%d picture), %d mismatches" % (n, pics, bad))
    # a setting with a filter on must have changed something (a vacuous pass is no pass)
    for cfg in sorted(set(changed) | set(seen_cfgs(path))):
        effect = (cfg & 0x1FFF) != 0        # colour or mask type; strengths and the grid bit alone do nothing
        if effect and cfg != 0x0001FFFF and changed.get(cfg, 0) == 0:     # (0001ffff is the overlay frame)
            print("setting %08x changed no picture pixel" % cfg)
            bad += 1
        print("  video_config %08x: %d picture pixels changed" % (cfg, changed.get(cfg, 0)))
    sys.exit(1 if bad or n == 0 else 0)


def seen_cfgs(path):
    with open(path) as f:
        return {int(line.split()[0], 16) for line in f}


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "selfcheck":
        print("model: selfcheck ok, colour error vs real arithmetic <= %.2f LSB" % selfcheck())
        selfcheck_smooth()
        print("model: smoothing selfcheck ok")
    elif len(sys.argv) == 2 and sys.argv[1] == "gen":
        gen()
    elif len(sys.argv) == 3 and sys.argv[1] == "check":
        check(sys.argv[2])
    elif len(sys.argv) == 4 and sys.argv[1] == "check_smooth":
        check_smooth(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)
