#!/usr/bin/env python3
"""Gamma tables of src/video_fx.v.

Rewrites the block between the "BEGIN gamma tables" and "END gamma tables"
markers in the given video_fx.v (default ../src/video_fx.v):

    out = round(255 * (in / 255) ** g)    for g = 1.2, 0.83 and 2.4 / 2.2

Table 0 (no gamma) is the identity.
Run with --check to compare without writing (exit 1 if the file is stale).
"""
import os
import re
import sys

GAMMAS = [1.0, 1.2, 0.83, 2.4 / 2.2]   # video_config[10:9] = 0, 1, 2, 3
BEGIN = "    // BEGIN gamma tables (tools/video_fx_gamma.py)"
END = "    // END gamma tables"


def table(g):
    return [int(255 * (i / 255) ** g + 0.5) for i in range(256)]


def block():
    lines = [BEGIN]
    for n, g in enumerate(GAMMAS):
        lines.append("    // gamma %.4g" % g)
        t = table(g)
        for row in range(0, 256, 8):
            cells = ["rom[%d]=%d;" % (n * 256 + row + k, t[row + k]) for k in range(8)]
            lines.append("    " + " ".join(cells))
    lines.append(END)
    return "\n".join(lines)


def main():
    args = [a for a in sys.argv[1:] if a != "--check"]
    path = args[0] if args else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src", "video_fx.v")
    src = open(path).read()
    pat = re.compile(re.escape(BEGIN) + r".*?" + re.escape(END), re.S)
    if not pat.search(src):
        sys.exit("markers not found in " + path)
    new = pat.sub(lambda m: block(), src)
    if "--check" in sys.argv:
        sys.exit(0 if new == src else 1)
    open(path, "w").write(new)


if __name__ == "__main__":
    main()
