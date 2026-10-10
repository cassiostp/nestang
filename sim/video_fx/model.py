#!/usr/bin/env python3
"""Golden model of src/video_fx.v, written from the spec (the video_config table and the
mask / grid definitions in the header of video_fx.v), not from the Verilog.

  model.py selfcheck      hand-computed spot values, fixed point error against real arithmetic
  model.py gen            write the test vectors (vec_*.hex) for tb_video_fx.v
  model.py check LOGFILE  check a log of the filters running inside nes2hdmi
                          (written by tb_nes_fx.v) against the model

Run with python3 -I.
"""
import os
import random
import sys

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
    elif len(sys.argv) == 2 and sys.argv[1] == "gen":
        gen()
    elif len(sys.argv) == 3 and sys.argv[1] == "check":
        check(sys.argv[2])
    else:
        sys.exit(__doc__)
