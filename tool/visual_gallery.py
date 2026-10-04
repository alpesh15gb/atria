"""Builds a contact sheet for the captures written by tool/visual_dump_test.dart.

    python tool/visual_gallery.py            # 3-wide grid
    python tool/visual_gallery.py 2          # 2-wide grid (bigger thumbnails)

Open build/visual/_gallery.html through a local web server, e.g.

    python -m http.server 8793 --directory build/visual
"""

import glob
import os
import sys

OUT = os.path.join("build", "visual")
cols = int(sys.argv[1]) if len(sys.argv) > 1 else 3
width = int(1440 / cols) - 24

names = sorted(
    os.path.basename(p) for p in glob.glob(os.path.join(OUT, "*.png"))
)
if not names:
    raise SystemExit(f"no PNGs in {OUT} — run the visual dump first")

cells = "\n".join(
    f'<figure id="{n[:-4]}"><a href="{n}" target="_blank">'
    f'<img src="{n}" width="{width}"></a>'
    f'<figcaption>{n[:-4]}</figcaption></figure>'
    for n in names
)

html = f"""<!doctype html>
<meta charset="utf-8">
<title>Atria visual dump ({len(names)})</title>
<style>
  body {{ margin: 0; padding: 12px; background: #e9ecef;
          font: 12px/1.3 Inter, system-ui, sans-serif; color: #222; }}
  .grid {{ display: grid; grid-template-columns: repeat({cols}, 1fr);
           gap: 16px; align-items: start; }}
  figure {{ margin: 0; background: #fff; border: 1px solid #c8ccd2;
            border-radius: 6px; overflow: hidden; }}
  img {{ display: block; width: 100%; height: auto; }}
  figcaption {{ padding: 4px 8px; font-weight: 600; background: #f6f7f9;
                border-top: 1px solid #dfe2e6; }}
</style>
<h1 style="font-size:15px;margin:0 0 10px">{len(names)} captures</h1>
<div class="grid">
{cells}
</div>
"""

with open(os.path.join(OUT, "_gallery.html"), "w", encoding="utf-8") as fh:
    fh.write(html)

print(f"wrote {OUT}/_gallery.html with {len(names)} captures ({cols} wide)")
