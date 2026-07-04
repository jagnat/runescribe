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
- `Esc` — quit

New sketch: copy `sketches/template/`, rename the package, edit `draw`.

## API

All procs take the canvas first: `plot.line(c, x1, y1, x2, y2)`.

- Shapes: `line`, `point`, `circle`, `ellipse`, `rect`, `bezier`
- Free-form: `begin_shape` / `vertex` / `end_shape(close = ...)`
- Transforms: `push_matrix`, `pop_matrix`, `translate`, `rotate`, `scale`
- `pen(c, n)` — select carousel pen 1-8 for subsequent shapes (color-coded in the preview)
- `stroke_weight` — preview line width, recorded per shape and written as SVG stroke-width

Transforms are baked into coordinates when a shape is recorded, and curves are
flattened to polylines, so exports stay within the element subset `svg2hpgl.py`
understands: `line`, `circle`, `polyline`, `polygon` with strokes only.

Each pen's shapes export as their own `<g data-pen="n" stroke="...">` group in
one shared SVG, so per-pen plotting keeps registration (the converter's fit is
computed from the whole drawing). svg2hpgl.py currently plots everything with
its single configured pen; filtering by `data-pen` is a converter-side change.
