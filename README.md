# plot_odin

Processing-style sketching in Odin for pen plotting. Sketches draw through a small
immediate-mode canvas API, raylib shows a live preview, and a keypress exports the
frame as a minimal SVG ready for the hpgl_plot pipeline (`svg2hpgl.py` -> HP 7440A).

## Quickstart

```sh
odin run sketches/demo -out:build/demo
```

In the preview window:

- `S` — export the current frame to `svg/plot_<timestamp>.svg`
- `R` — reroll the random seed (sketches are deterministic per seed)
- `Tab` — toggle the tweak panel (seed readout plus any declared params)
- `Esc` — quit

New sketch: copy `sketches/template/`, rename the package, edit `draw`.

## API

The canvas is a package global, `plot.canvas` — read `width`, `height`, `frame`, `seed`
from it. Drawing procs take plain coordinates: `plot.line(x1, y1, x2, y2)`. Most take
either loose floats or `Vec2`.

**Shapes.** `line`, `point`, `circle`, `ellipse`, `arc`, `rect`, `bezier`, `polyline`,
`dotted_line`. Free-form: `begin_shape` / `vertex` / `end_shape(close = ...)`.
`point` records a zero-length line, which the plotter puts down as a dot.

**Style.** `stroke(gray)`, `stroke(r, g, b)`, or `stroke(Color)` sets the ink colour;
`stroke_weight(w)` sets the width. Shapes are grouped for export by distinct
(colour, weight) pair — see *Pens* below.

**Transforms.** `push_matrix`, `pop_matrix`, `translate`, `rotate`, `scale`, `shear`.
`apply(p)` bakes the current transform into a point yourself.

**Clipping and occlusion.** `push_clip(points)` keeps only the parts of subsequent
strokes inside a polygon; `push_occlude(points)` drops them instead. `pop_clip` undoes
the innermost. Convenience: `push_clip_circle`, `push_clip_rect`. For hidden-line
removal, draw front to back and push each shape's silhouette as an occluder before
drawing what lies behind it.

**Groups.** `begin_group` / `end_group` capture shapes and clip pushes instead of
executing them; `draw_group(g)` replays them, its occluders going live for everything
replayed after. That lets a sketch generate geometry in any order and replay it depth
sorted. No nesting; replay each group at most once per frame.

**Hatching.** `hatch(points, spacing, angle)` fills a polygon with parallel lines on
the current pen (no outline — draw one yourself if you want it). Cross-hatch by
hatching twice at two angles. Also `hatch_rect`, `hatch_circle`.

**Noise.** `noise` (1d/2d/3d, OpenSimplex, `[0, 1)`) and `fbm` for octaved noise, both
seeded from the canvas seed so `R` rerolls the field along with `rand`. `vnoise` /
`vfbm` / `vfbm2` are the signed value-noise family, and `warp` is iq's domain warp.

**Paths.** `smooth(points, iterations)` is Chaikin corner cutting;
`simplify(points, tolerance)` is Ramer-Douglas-Peucker. Both return a fresh slice on
the temp allocator.

**Iterators.** `make_line_iterator` / `iterate_line` and `make_bezier_iterator` /
`iterate_bezier` walk a curve without recording it, for when you want the points.

**Tweak panel.** Declare parameters inline in `draw`: `param(name, initial, lo, hi)`
(f32), `param_int`, `toggle`. The first call registers a control, every call returns
its live value. `Tab` shows the panel — drag a row to scrub it, arrow keys nudge the
hovered row — and any change re-runs `draw`, even with `loop = false`. The panel is
preview-only overlay; it never appears in exports.

**Input.** `mouse()`, `mouse_down()`, `mouse_pressed()`, `wheel()`, `key_down(.SPACE)`,
`key_pressed(...)`. Interactive sketches should run with `loop = true` so `draw` sees
fresh input each frame. Mouse queries report false while the tweak panel has the
pointer, so panel drags don't leak into the sketch.

## Determinism and memory

Each frame the canvas is cleared, the random seed is reset, and `draw` re-records every
shape — so a sketch holds still until you press `R`. The same recorded shapes feed both
the preview and the SVG export, so the exported file is exactly the previewed frame.

All per-frame recording lives on `context.temp_allocator`, freed at the top of the next
frame. Nothing you record survives a frame.

## Pens

Transforms are baked into coordinates when a shape is recorded, and curves are
flattened to polylines, so exports stay within the element subset `svg2hpgl.py`
understands: `line`, `circle`, `polyline`, `polygon` with strokes only.

Sketches set a colour and weight, not a pen. Each distinct (colour, weight) style
exports as its own `<g stroke="#rrggbb" stroke-width="...">` in one shared SVG.
`svg2hpgl.py` maps styles to the 8-pen carousel — interactively, via `--pens`/`--map`,
or from a saved `<input>.pens.json` sidecar — and runs vpype's `linemerge`/`linesort`
first if it's installed. Keeping every style in one SVG means the converter's
fit-to-paper transform sees the whole drawing, so per-pen passes stay registered.
