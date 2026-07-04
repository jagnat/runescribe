package plot

import "core:math/linalg"
import "core:slice"

// Pure polyline utilities: take points, return a fresh slice (never aliasing
// the input) on the given allocator. The default matches the per-frame
// lifetime of recorded shapes; scratch work stays on the temp allocator.
// Draw results with polyline(c, pts)

// Chaikin corner cutting: each iteration replaces every segment with points
// at 1/4 and 3/4, doubling density and rounding corners. Open polylines keep
// their endpoints; closed ones wrap
smooth :: proc(points: []Vec2, iterations := 1, closed := false, allocator := context.temp_allocator) -> []Vec2 {
	pts := points
	for _ in 0 ..< iterations {
		n := len(pts)
		if n < 3 {
			break
		}
		out := make([dynamic]Vec2, 0, 2 * n + 2, context.temp_allocator)
		if closed {
			for a, i in pts {
				b := pts[(i + 1) % n]
				append(&out, a * 0.75 + b * 0.25, a * 0.25 + b * 0.75)
			}
		} else {
			append(&out, pts[0])
			for i in 0 ..< n - 1 {
				a := pts[i]
				b := pts[i + 1]
				append(&out, a * 0.75 + b * 0.25, a * 0.25 + b * 0.75)
			}
			append(&out, pts[n - 1])
		}
		pts = out[:]
	}
	return slice.clone(pts, allocator)
}

// Ramer-Douglas-Peucker: drops points that deviate less than tolerance from
// the line between their kept neighbors. Fewer points means smaller SVGs and
// faster plots
simplify :: proc(points: []Vec2, tolerance: f32, allocator := context.temp_allocator) -> []Vec2 {
	if len(points) < 3 {
		return slice.clone(points, allocator)
	}
	keep := make([]bool, len(points), context.temp_allocator)
	keep[0] = true
	keep[len(points) - 1] = true
	rdp_mark(points, 0, len(points) - 1, tolerance, keep)
	out := make([dynamic]Vec2, 0, len(points), allocator)
	for p, i in points {
		if keep[i] {
			append(&out, p)
		}
	}
	return out[:]
}

@(private)
rdp_mark :: proc(points: []Vec2, lo, hi: int, tolerance: f32, keep: []bool) {
	if hi <= lo + 1 {
		return
	}
	best_d := f32(-1)
	best_i := lo
	for i in lo + 1 ..< hi {
		d := dist_point_segment(points[i], points[lo], points[hi])
		if d > best_d {
			best_d = d
			best_i = i
		}
	}
	if best_d > tolerance {
		keep[best_i] = true
		rdp_mark(points, lo, best_i, tolerance, keep)
		rdp_mark(points, best_i, hi, tolerance, keep)
	}
}

@(private)
dist_point_segment :: proc(p, a, b: Vec2) -> f32 {
	ab := b - a
	len2 := linalg.dot(ab, ab)
	if len2 == 0 {
		return linalg.distance(p, a)
	}
	t := clamp(linalg.dot(p - a, ab) / len2, 0, 1)
	return linalg.distance(p, a + ab * t)
}
