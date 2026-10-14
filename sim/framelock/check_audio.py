#!/usr/bin/env python3
# Host-side check of the frame-lock HDMI audio dumps (see run.sh): the 49 us
# hold must not click and must not shift DC. Assertions: mean near zero (no
# DC step), no 60 Hz buzz (Goertzel 60 Hz << 440 Hz fundamental), repeated
# samples only in small clusters once per frame (the hold), never a runaway.
import math, sys

def goertzel(xs, f, fs):
    w = 2 * math.pi * f / fs
    c = math.cos(w)
    s = p = 0.0
    for x in xs:
        q = x + 2 * c * s - p
        p, s = s, q
    return math.hypot(s - p * c, p * math.sin(w)) / len(xs)

FS = 48020.0  # measured audio tick in the bench (2x773 pixel clocks)
ok = True
for path in sys.argv[1:]:
    xs = [int(l) for l in open(path) if l.strip()]
    n = len(xs)
    mean = sum(xs) / n
    rms = math.sqrt(sum((x - mean) ** 2 for x in xs) / n)
    g60 = goertzel(xs, 60.0, FS)
    g440 = goertzel(xs, 440.0, FS)
    # repeat clusters: runs of equal neighbours (the hold repeats one sample)
    runs, i, maxrun, singles = 0, 1, 0, 0
    while i < n:
        j = i
        while j < n and xs[j] == xs[j - 1]:
            j += 1
        if j > i:
            runs += 1
            maxrun = max(maxrun, j - i)
            if j - i == 1:
                singles += 1
        i = j if j > i else i + 1
    frames = n / (FS / 60.0)
    print(f"{path}: n={n} mean={mean:.1f} rms={rms:.0f} "
          f"goertzel60={g60:.1f} goertzel440={g440:.0f} "
          f"repeat_runs={runs} maxrun={maxrun} singles={singles} frames~{frames:.0f}")
    checks = [
        (abs(mean) < 50, f"DC mean {mean:.1f}"),
        (g60 < 0.05 * g440, f"60 Hz buzz {g60:.1f} vs 440 Hz {g440:.0f}"),
        (maxrun <= 4, f"max repeat run {maxrun}"),
        (runs < 3 * frames, f"repeat runs {runs} vs frames {frames:.0f}"),
    ]
    for good, what in checks:
        print(("  ok: " if good else "  FAIL: ") + what)
        ok = ok and good
print("check_audio.py: PASS" if ok else "check_audio.py: FAIL")
sys.exit(0 if ok else 1)
