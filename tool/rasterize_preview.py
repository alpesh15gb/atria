"""Used only by visual_dump_test: PDF -> raw RGBA + dimensions."""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'build/mobile-review/python-libs'))
import pymupdf

source, output, scale = sys.argv[1:]
doc = pymupdf.open(source)
pix = doc[0].get_pixmap(matrix=pymupdf.Matrix(float(scale), float(scale)), alpha=True)
Path(output).write_bytes(pix.samples)
pix.save(output + '.png')
Path(output + '.json').write_text(json.dumps({'width': pix.width, 'height': pix.height}))
