"""Measure the real margins of a rendered screen.

For each horizontal band of a PNG, list the runs of non-page pixels — so
"we are wasting the left and right area" becomes a number: the nav rail sits
at 0..236, the form card starts where the second run starts, and the gap
between them is the wasted margin.

    python tool/ink_extent.py build/visual/wide_sale_edit.png
"""

import sys
from collections import Counter

from PIL import Image


def runs(px, w, y, bg, min_len=3):
    out = []
    start = None
    for x in range(w):
        differs = px[x, y] != bg
        if differs and start is None:
            start = x
        elif not differs and start is not None:
            if x - start >= min_len:
                out.append((start, x - 1))
            start = None
    if start is not None and w - start >= min_len:
        out.append((start, w - 1))
    return out


def report(path, step=None):
    im = Image.open(path).convert("RGB")
    w, h = im.size
    px = im.load()

    # The page background is the colour of the right-hand margin (the cards
    # never reach the window edge, the page does).
    sample = Counter(px[x, y] for y in range(0, h, 3)
                     for x in range(max(0, w - 4), w))
    bg = sample.most_common(1)[0][0]

    print(f"{path}  {w}x{h}  page={bg}")
    step = step or max(1, h // 12)
    for y in range(60, h, step):
        r = runs(px, w, y, bg)
        if not r:
            print(f"  y={y:4d}  (page only)")
            continue
        spans = "  ".join(f"{a}..{b}" for a, b in r[:5])
        if len(r) == 1:
            a, b = r[0]
            print(f"  y={y:4d}  [{spans}]  left-gap {a}  right-gap {w - 1 - b}")
        else:
            # The first run is the nav rail; the gap to the next run is the
            # margin the page is wasting.
            print(f"  y={y:4d}  [{spans}]  gaps "
                  + " ".join(str(r[i + 1][0] - r[i][1] - 1)
                             for i in range(len(r) - 1)))


if __name__ == "__main__":
    for path in sys.argv[1:]:
        report(path)
