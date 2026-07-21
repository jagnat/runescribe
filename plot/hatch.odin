package plot

import "core:math"
import "core:slice"

// Fills, drawn as parallel Line shapes on the current pen. No outline is drawn;
// call rect/circle/polyline alongside if you want one. Cross-hatch by hatching
// twice at two angles.

// Even-odd scanline, so concave outlines fill correctly. angle is in radians.
// gap > 0 breaks each line into dash-length strokes (or dots when dash is 0);
// stagger shifts the dash pattern by that much per line so dashes don't align
// into columns
hatch :: proc(points: []Vec2, spacing: f32, angle := f32(0), dash := f32(0), gap := f32(0), stagger := f32(0)) {
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
	row := 0
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
			hatch_span(xs[i], xs[i + 1], y, co, si, dash, gap, f32(row) * stagger)
		}
		row += 1
	}
}

// One horizontal span in the rotated frame, rotated back to world as it draws
@(private = "file")
hatch_span :: proc(x0, x1, y, co, si, dash, gap, phase: f32) {
	world :: proc(x, y, co, si: f32) -> Vec2 {
		return {co * x - si * y, si * x + co * y}
	}
	if gap <= 0 {
		line_v(world(x0, y, co, si), world(x1, y, co, si))
		return
	}
	if dash <= 0 {
		dotted_line_v(world(x0, y, co, si), world(x1, y, co, si), gap)
		return
	}
	period := dash + gap
	// start one period early so any phase leaves no bare stretch at x0
	for x := x0 - math.mod(phase, period) - period; x < x1; x += period {
		a := max(x, x0)
		b := min(x + dash, x1)
		if b > a {
			line_v(world(a, y, co, si), world(b, y, co, si))
		}
	}
}

hatch_rect :: proc {
	hatch_rect_xy,
	hatch_rect_v,
}

hatch_rect_v :: proc(pos, size: Vec2, spacing: f32, angle := f32(0), dash := f32(0), gap := f32(0), stagger := f32(0)) {
	pts := [4]Vec2{pos, pos + {size.x, 0}, pos + size, pos + {0, size.y}}
	hatch(pts[:], spacing, angle, dash, gap, stagger)
}

hatch_rect_xy :: proc(x, y, w, h, spacing: f32, angle := f32(0), dash := f32(0), gap := f32(0), stagger := f32(0)) {
	hatch_rect_v({x, y}, {w, h}, spacing, angle, dash, gap, stagger)
}

hatch_circle :: proc {
	hatch_circle_xy,
	hatch_circle_v,
}

hatch_circle_v :: proc(center: Vec2, r, spacing: f32, angle := f32(0), dash := f32(0), gap := f32(0), stagger := f32(0)) {
	hatch(ellipse_points(center, r, r, circle_segments(r * xform_scale())), spacing, angle, dash, gap, stagger)
}

hatch_circle_xy :: proc(x, y, r, spacing: f32, angle := f32(0), dash := f32(0), gap := f32(0), stagger := f32(0)) {
	hatch_circle_v({x, y}, r, spacing, angle, dash, gap, stagger)
}
