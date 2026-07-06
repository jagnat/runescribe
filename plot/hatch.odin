package plot

import "core:math"
import "core:slice"

// Pen-plotter fills: shapes are filled with parallel pen lines, recorded as
// ordinary Line shapes on the current pen. Hatching draws no outline; call
// rect/circle/polyline alongside if you want one. Cross-hatch by hatching
// twice at two angles.

// Fills a polygon with lines spaced `spacing` apart at `angle` radians.
// Even-odd scanline, so concave outlines fill correctly. Points are in the
// current transform's space, like every other primitive
hatch :: proc(points: []Vec2, spacing: f32, angle := f32(0)) {
	if len(points) < 3 || spacing <= 0 {
		return
	}
	co := math.cos(angle)
	si := math.sin(angle)
	// rotate into the frame where hatch lines are horizontal
	local := make([]Vec2, len(points), context.temp_allocator)
	ymin, ymax := max(f32), min(f32)
	for p, i in points {
		q := Vec2{co * p.x + si * p.y, -si * p.x + co * p.y}
		local[i] = q
		ymin = min(ymin, q.y)
		ymax = max(ymax, q.y)
	}
	xs := make([dynamic]f32, context.temp_allocator)
	for y := ymin + spacing / 2; y < ymax; y += spacing {
		clear(&xs)
		for a, i in local {
			b := local[(i + 1) % len(local)]
			if (a.y <= y) == (b.y <= y) { // half-open, so a vertex on the scanline counts once
				continue
			}
			append(&xs, a.x + (b.x - a.x) * (y - a.y) / (b.y - a.y))
		}
		slice.sort(xs[:])
		for i := 0; i + 1 < len(xs); i += 2 {
			line_v({co * xs[i] - si * y, si * xs[i] + co * y}, {co * xs[i + 1] - si * y, si * xs[i + 1] + co * y})
		}
	}
}

hatch_rect :: proc {
	hatch_rect_xy,
	hatch_rect_v,
}

hatch_rect_v :: proc(pos, size: Vec2, spacing: f32, angle := f32(0)) {
	pts := [4]Vec2{pos, pos + {size.x, 0}, pos + size, pos + {0, size.y}}
	hatch(pts[:], spacing, angle)
}

hatch_rect_xy :: proc(x, y, w, h, spacing: f32, angle := f32(0)) {
	hatch_rect_v({x, y}, {w, h}, spacing, angle)
}

hatch_circle :: proc {
	hatch_circle_xy,
	hatch_circle_v,
}

hatch_circle_v :: proc(center: Vec2, r, spacing: f32, angle := f32(0)) {
	n := circle_segments(r * xform_scale())
	pts := make([]Vec2, n, context.temp_allocator)
	for i in 0 ..< n {
		t := f32(i) / f32(n) * math.TAU
		pts[i] = center + {r * math.cos(t), r * math.sin(t)}
	}
	hatch(pts, spacing, angle)
}

hatch_circle_xy :: proc(x, y, r, spacing: f32, angle := f32(0)) {
	hatch_circle_v({x, y}, r, spacing, angle)
}
