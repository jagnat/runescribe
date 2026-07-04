# CLAUDE.md

## Project Overview

plot_odin is a Processing-style sketching framework in Odin: sketches record shapes through a small immediate-mode canvas API, raylib previews the result live, and a keypress exports the frame as a minimal SVG for pen plotting via the companion hpgl_plot pipeline.

## Build / Run

- `odin run sketches/<name> -out:build/<name>` — build and run a sketch
- `odin check sketches/<name>` — typecheck a sketch (and the `plot` package it imports)
- In the preview window: `S` exports `svg/plot_<timestamp>.svg`, `R` rerolls the random seed

## Architecture

- `plot/` — the framework package: canvas, transforms, shape recording, and raylib preview in `plot.odin`; SVG export in `svg.odin`. Imports only core and `vendor:raylib`.
- `sketches/<name>/` — one package per sketch. Each imports `plot` by relative path, defines a `draw` proc, and calls `plot.run` from `main`. Copy `sketches/template/` to start a new one.

Each frame the canvas is cleared, the sketch's `draw` re-records every shape, and the same recorded shapes feed both the raylib preview and the SVG export — the exported SVG is exactly the previewed frame. The random seed is reset before each `draw`, so sketches are deterministic until reseeded.

## SVG constraints (pen plotting)

Exports are consumed by hpgl_plot's `svg2hpgl.py`, which only understands bare `line`, `polyline`, `polygon`, `rect`, `circle`, `ellipse`, and `path` elements, strokes only. Keep exports to those elements: flat structure (one `<g>` per pen, tagged `data-pen="n"`), no `transform` attributes, no `style`/CSS, no text, no fills, no gradients or clip paths. Transforms are baked into coordinates at record time (`apply`); curves are flattened to polylines at record time. Never emit geometry the plotter pipeline would have to interpret.

The plotter is an 8-pen carousel. All pens share one SVG (one `<g>` group per pen) rather than one file per pen, so the converter's fit-to-paper transform sees the whole drawing and per-pen passes stay registered.

## Memory & lifetimes

- All per-frame recording (shapes, polyline points, transform stack) lives on `context.temp_allocator`; the run loop calls `free_all` at the top of each frame. Nothing recorded survives a frame — export happens in the same frame as recording.
- Be explicit about ownership: who allocates, who frees, and how long each thing lives.
- Route allocations through the project's designated allocator(s). Don't silently fall back to a
  default/global allocator.
- Prefer arena/temp/scratch allocators with a clear scope; pair acquisition with `defer`-style
  cleanup. Avoid hidden allocations.
- Think about data layout and ownership like a systems programmer, and write idiomatically for the
  language — not a transliteration of C, Go, or another language.

## Working Principles

**Think before coding.** State your assumptions up front. When a request is ambiguous, surface
the interpretations instead of silently picking one. If something is genuinely unclear, ask — don't
guess and don't hide confusion.

**Discuss before coding.** "Take a look", "outline", "what do you think" mean analysis, not edits.
Don't start changing files until asked to implement.

**Simplicity first.** Write the minimum code that solves the problem. No speculative abstractions,
no unrequested features, no error handling for scenarios that can't happen. If the solution could
be half the length, it should be.

**Surgical changes.** Touch only what the task requires. Don't reformat or refactor unrelated
working code. Match the surrounding style. Only remove code your changes orphaned — leave
pre-existing dead code, and commented-out code, alone unless asked (it's often intentional).

**Don't commit unless asked.** No commits, pushes, or PRs without an explicit request.

## Style

- Indentation: tabs.
- No space-padded vertical alignment anywhere — one space between tokens, even if surrounding code
  does otherwise.
- Expand multi-statement blocks across lines. Readability beats line count; never collapse to
  `{ a; b }` to save a line.
- Match the conventions of the surrounding code.

## Comments

- Don't narrate what the next line obviously does. No "Create X" before creating X.
- Don't restate identifiers. A field named `uniformBuffer` doesn't need `// Uniform buffer`.
- Keep only non-obvious information: `// 1MB instance buffer`, `// physical pixels`.
- Section headers stay plain: `// Renderer lifecycle`. No boxes or separator lines.
- `// TODO:` for genuinely incomplete work — not hedges like "if needed".
- Minimal punctuation. No trailing periods unless the comment is multiple sentences.
- ASCII only in code. No non-ASCII symbols (no √, ², ×, →) — write `sqrt`, `^2`, `x`, `->`.
