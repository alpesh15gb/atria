"""Cross-screen summary of build/visual/audit.txt.

    python tool/audit_summary.py            # inventory + chrome table
    python tool/audit_summary.py contrasts  # only the contrast failures
    python tool/audit_summary.py <screen>   # dump one screen's section
    python tool/audit_summary.py screens    # per-screen distinctness ranking
"""

import re
import sys
from collections import Counter, defaultdict

PATH = "build/visual/audit.txt"
lines = open(PATH, encoding="utf-8").read().splitlines()

mode = sys.argv[1] if len(sys.argv) > 1 else "all"

screen = None
section = None
inventory = defaultdict(Counter)
where = defaultdict(lambda: defaultdict(list))
chrome = defaultdict(dict)
contrast = []
screens = []

style_re = re.compile(r"^\s*(\d+)x\s+(.*)$")


def flush_screen():
    pass


for line in lines:
    if line.startswith("## "):
        m = re.match(r"## (\S+)\s+\((\S+)\)\s+(\S+)", line)
        if m:
            screen = m.group(1)
            screens.append((screen, m.group(2), m.group(3)))
        section = None
        continue
    if line.startswith("-- "):
        section = line[3:].split("  (")[0].strip()
        continue
    if line.startswith("-- CONTRAST BELOW AA"):
        section = "CONTRAST BELOW AA"
        continue
    if section == "CHROME GEOMETRY" and line.startswith("  "):
        if ":" in line:
            label, _, value = line.strip().partition(":")
            chrome[screen][label.strip()] = value.strip()
        continue
    if section == "CONTRAST BELOW AA":
        if line.strip():
            contrast.append((screen, line.strip()))
        continue
    m = style_re.match(line)
    if m and section:
        inventory[section][m.group(2).strip()] += int(m.group(1))
        if len(where[section][m.group(2).strip()]) < 6:
            where[section][m.group(2).strip()].append(screen)

if mode == "contrasts":
    for s, c in contrast:
        print(f"{s:20} {c}")
    raise SystemExit(0)

if mode in ("all", "inventory"):
    print(f"{len(screens)} screens audited\n")
    for section in ("TEXT STYLES", "ICON STYLES", "TEXT COLOURS", "RADII",
                    "GAPS (Row/Column.spacing)"):
        counts = inventory.get(section)
        if not counts:
            continue
        print(f"=== {section}: {len(counts)} distinct")
        for key, n in counts.most_common():
            seen = ", ".join(dict.fromkeys(where[section][key]))[:90]
            print(f"  {n:6}  {key:38}  {seen}")
        print()

if mode in ("all", "pad"):
    counts = inventory.get("PADDINGS")
    if counts:
        print(f"=== PADDINGS: {len(counts)} distinct")
        for key, n in counts.most_common(30):
            print(f"  {n:6}  {key:38}")
        print()
    counts = inventory.get("SIZEDBOX SIZES")
    if counts:
        print(f"=== SIZEDBOX SIZES: {len(counts)} distinct")
        for key, n in counts.most_common(25):
            print(f"  {n:6}  {key:38}")
        print()

if mode in ("all", "chrome"):
    print("=== CHROME GEOMETRY (left,top WxH)")
    labels = ["topbar", "page-header", "primary-action", "results-bar",
              "filter-bar", "line-grid", "totals-block", "editor-form"]
    print(f"  {'screen':22} " + " ".join(f"{l[:13]:>16}" for l in labels))
    for s, _, _ in screens:
        row = []
        for l in labels:
            v = chrome[s].get(l, "-")
            row.append(f"{v[:16]:>16}")
        print(f"  {s:22} " + " ".join(row))

if mode == "screens":
    # Per-screen "distinctness" scoreboard. A screen that reuses the app's
    # shared type/icon/space scale shows the same small set of values as every
    # other screen; one-off values inflate its row and show up here first.
    sections = ["TEXT STYLES", "ICON STYLES", "TEXT COLOURS", "RADII",
                "PADDINGS", "SIZEDBOX SIZES"]
    per = defaultdict(lambda: defaultdict(set))
    cur = None
    sec = None
    for line in lines:
        if line.startswith("## "):
            cur = line[3:].split()[0]
            sec = None
            continue
        if line.startswith("-- "):
            sec = line[3:].split("  (")[0].strip()
            continue
        m = style_re.match(line)
        if m and cur and sec in sections:
            per[cur][sec].add(m.group(2).strip())
    print(f"{len(screens)} screens, distinct values per section")
    print(f"  {'screen':22}" + "".join(f"{s[:11]:>13}" for s in sections)
          + f"{'TOTAL':>8}")
    ranked = sorted(
        per.items(), key=lambda kv: -sum(len(v) for v in kv[1].values()))
    for name, secs in ranked:
        total = sum(len(v) for v in secs.values())
        print(f"  {name:22}" + "".join(f"{len(secs[s]):>13}" for s in sections)
              + f"{total:>8}")
    raise SystemExit(0)

if mode not in ("all", "inventory", "pad", "chrome", "contrasts", "screens"):
    for s, _, _ in screens:
        if s == mode:
            dump = False
            for line in lines:
                if line.startswith(f"## {s} "):
                    dump = True
                elif line.startswith("## ") and dump:
                    dump = False
                if dump:
                    print(line)
            break
    else:
        print("screens:", ", ".join(s for s, _, _ in screens))
