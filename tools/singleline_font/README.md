# singleline_font

Derives the plot library's single-line font (`plot/font_maple.odin`) from
MapleMono-Thin.ttf: skeletonize each glyph, merge skeleton branches into long
strokes by tangent continuity, then fit a handful of smooth cubic Beziers per
stroke. Straight stems stay exact lines; isolated blobs (tittles, periods)
become pen-down dots.

```
python3 -m venv venv && venv/bin/pip install -r requirements.txt
venv/bin/python make_font.py         # -> font.json + proof.png (visual check)
venv/bin/python emit_odin.py         # -> ../../plot/font_maple.odin
venv/bin/python emit_otf.py          # -> ../../RunescribeSingleLine.otf (installable)
```

`make_font.py 'abc'` extracts only those glyphs, for quick iteration against
proof.png. Tunables are the constants at the top of make_font.py.
