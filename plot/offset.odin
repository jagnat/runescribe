package plot

import "core:math/linalg"
import "core:slice"

// Offset (parallel) curves: each point moves d along the local perp of the
// path, so positive and negative d give the two sides. Miter joins, clamped
// to 4x the offset at sharp corners. Self-intersections are not removed --
// offsets wider than the local radius of curvature will fold

offset :: proc {
	offset_const,
	offset_per_point,
}

offset_const :: proc(points: []Vec2, d: f32, closed := false, allocator := context.temp_allocator) -> []Vec2 {
	ds := make([]f32, len(points), context.temp_allocator)
	slice.fill(ds, d)
	return offset_per_point(points, ds, closed, allocator)
}

// d[i] is the offset at points[i]; taper it for spines that swell and thin
offset_per_point :: proc(points: []Vec2, d: []f32, closed := false, allocator := context.temp_allocator) -> []Vec2 {
	n := len(points)
	if n < 2 {
		return slice.clone(points, allocator)
	}
	out := make([]Vec2, n, allocator)
	for i in 0 ..< n {
		dir_in, dir_out: Vec2
		if closed || i > 0 {
			dir_in = linalg.normalize0(points[i] - points[(i - 1 + n) % n])
		}
		if closed || i < n - 1 {
			dir_out = linalg.normalize0(points[(i + 1) % n] - points[i])
		}
		if dir_in == (Vec2{}) {
			dir_in = dir_out
		}
		if dir_out == (Vec2{}) {
			dir_out = dir_in
		}
		n_in := perp(dir_in)
		m := linalg.normalize0(n_in + perp(dir_out))
		if m == (Vec2{}) { // 180-degree turn
			m = n_in
		}
		den := linalg.dot(m, n_in) // cos of half the turn; miter length is d / den
		out[i] = points[i] + m * (d[i] * (den > 0.25 ? 1 / den : 4))
	}
	return out
}
