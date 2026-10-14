#!/usr/bin/env python3
# Host-side check of the frame-lock HDMI audio dumps (see run.sh): the 49 us
# hold must not click and must not shift DC. Windows where the stream
# legitimately freezes (menu pauses, pre-lock startup, resets and pause-offs
# up to re-lock) are masked out using the scenario/halt lines in the tb log:
# while paused hardware mutes the stream (`pause ? 0 : sample`), and a
# re-lock can pass through one longer wait. Assertions on the running stream:
# mean near zero (no DC step), no 60 Hz buzz (Goertzel 60 Hz << 440 Hz
# fundamental), repeated samples only in small clusters once per frame (the
# hold), never a runaway.
import math, sys

FS = 48028.0  # DUT audio tick: 2x773 pixel clocks (AUDIO_CLK_DELAY in nes2hdmi.sv)
OK_WAIT_LO = 30000     # steady waits: 38 us (60K) .. 49 us (138K), both boards
OK_WAIT_HI = 60000

def windows(logpath):
    # Mask every window where the stream legitimately freezes: the menu
    # pauses, the pre-lock startup, each core reset and each pause-off up to
    # the first *steady* release pair (the re-lock can pass through one
    # longer wait on the way). Returns (windows, steady_release_count).
    wins, on, enters = [], None, {}
    events = []  # (time, kind)
    pauses = []  # (on, off)
    rels = []    # (enter, wait)
    for line in open(logpath):
        p = line.split()
        if not p:
            continue
        if p[0] == 'halt' and len(p) >= 6:
            n = int(p[1][1:])
            if p[2] == 'enter':
                enters[n] = int(p[4])
            elif p[2] == 'release' and n in enters:
                rels.append((enters[n], int(p[3].split('=')[1])))
        if len(p) >= 6 and p[0] == 'scenario:':
            t = int(p[-2])
            if p[2] == 'pause' and p[3] == 'on':
                on = t
            elif p[2] == 'pause' and p[3] == 'off' and on is not None:
                pauses.append((on, t))
                events.append((t, 'pause-off'))
                on = None
            elif p[2] == 'reset':
                events.append((t, 'reset'))
    events.insert(0, (0, 'startup'))
    ends = sorted((e + w, OK_WAIT_LO <= w <= OK_WAIT_HI) for e, w in rels)
    # a pause can land mid-halt: extend its mask back over the wait in
    # progress, whose first held samples predate the pause itself
    for on, off in pauses:
        start = min([on] + [e for e, w in rels if e <= on <= e + w])
        wins.append((start, off))
        events.append((on, 'pause-on'))
    for t, _ in events:
        # walk the transition cluster: stop after the first steady release
        # that is itself followed by a steady one
        stop = None
        after = [(te, st) for te, st in ends if te > t]
        for k, (te, st) in enumerate(after):
            nxt_steady = k + 1 < len(after) and after[k + 1][1]
            if st and nxt_steady:
                stop = te
                break
        wins.append((t, stop if stop is not None else t))
    # every long wait must sit inside a masked window (else the bench's
    # forgive logic missed a freeze class: fail loudly, not silently)
    for e, w in rels:
        if w > OK_WAIT_HI and not any(a <= e and e + w <= b for a, b in wins):
            sys.exit(f"unmasked long wait: enter {e} wait {w}")
    nsteady = sum(1 for e, w in rels if OK_WAIT_LO <= w <= OK_WAIT_HI)
    return wins, nsteady

def masked(path, wins):
    # returns (kept values, kept raw indices). Window edges get a 16-sample
    # margin each way: the dump index<->time map uses the nominal audio rate
    # while the DUT divider runs the exact one (15 ppm apart, ~8 samples over
    # the run), plus a sample of print/effect race at each edge.
    xs = [int(l) for l in open(path) if l.strip()]
    keep = [True] * len(xs)
    for a, b in wins:
        i0 = max(0, int(a * FS / 1e9) - 16)
        i1 = min(len(xs), int(b * FS / 1e9) + 2 + 16)
        for i in range(i0, i1):
            keep[i] = False
    return [x for x, k in zip(xs, keep) if k], [i for i, k in enumerate(keep) if k]

def goertzel(xs, f, fs):
    w = 2 * math.pi * f / fs
    c = math.cos(w)
    s = p = 0.0
    for x in xs:
        q = x + 2 * c * s - p
        p, s = s, q
    return math.hypot(s - p * c, p * math.sin(w)) / len(xs)

def main(argv):
    if len(argv) < 3 or len(argv) % 2 == 0:
        sys.exit("usage: check_audio.py audio.hex tb.log [audio.hex tb.log ...]")
    ok = True
    pairs = [(argv[i], argv[i + 1]) for i in range(1, len(argv) - 1, 2)]
    for path, logpath in pairs:
        wins, nsteady = windows(logpath)
        xs, kept = masked(path, wins)
        print(f"{path}: steady_releases={nsteady}")
        n = len(xs)
        mean = sum(xs) / n
        rms = math.sqrt(sum((x - mean) ** 2 for x in xs) / n)
        g60 = goertzel(xs, 60.0, FS)
        g440 = goertzel(xs, 440.0, FS)
        # repeat clusters: runs of equal neighbours (the hold repeats one sample)
        runs, i, maxrun, maxat, singles = 0, 1, 0, 0, 0
        while i < n:
            j = i
            while j < n and xs[j] == xs[j - 1]:
                j += 1
            if j > i:
                runs += 1
                if j - i > maxrun:
                    maxrun, maxat = j - i, kept[i - 1] / FS
                if j - i == 1:
                    singles += 1
            i = j if j > i else i + 1
        frames = n / (FS / 60.0)
        print(f"{path}: n={n} mean={mean:.1f} rms={rms:.0f} "
              f"goertzel60={g60:.1f} goertzel440={g440:.0f} "
              f"repeat_runs={runs} maxrun={maxrun}@{maxat:.3f}s singles={singles} frames~{frames:.0f}")
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
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main(sys.argv))
