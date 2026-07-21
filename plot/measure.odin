package plot

import "core:math"
import "core:math/linalg"
import "core:slice"

// Arc-length tools: measure, walk, resample, and slice polylines by distance
// along them. Points stay in whatever space they were built in; dashed and
// dotted record through the current transform like polyline does. Pass loops
// with closed = true rather than repeating the first point

// v rotated a quarter turn: {-v.y, v.x}
perp :: proc(v: Vec2) -> Vec2 {
	return {-v.y, v.x}
}

path_length :: proc(points: []Vec2, closed := false) -> f32 {
	if len(points) < 2 {
		return 0
	}
	total := f32(0)
	for i in 0 ..< len(points) - 1 {
		total += linalg.distance(points[i], points[i + 1])
	}
	if closed {
		total += linalg.distance(points[len(points) - 1], points[0])
	}
	return total
}

// Point and unit tangent at distance d along the path. Open paths clamp d to
// [0, length]; closed ones wrap it
path_point :: proc(points: []Vec2, d: f32, closed := false) -> (p: Vec2, tangent: Vec2) {
	if len(points) == 0 {
		return
	}
	total := path_length(points, closed)
	if len(points) == 1 || total <= 0 {
		return points[0], {1, 0}
	}
	d := d
	if closed {
		d = math.mod(d, total)
		if d < 0 {
			d += total
		}
	} else {
		d = clamp(d, 0, total)
	}
	nseg := closed ? len(points) : len(points) - 1
	acc := f32(0)
	for i in 0 ..< nseg {
		a := points[i]
		b := points[(i + 1) % len(points)]
		l := linalg.distance(a, b)
		if l > 0 && (d <= acc + l || i == nseg - 1) {
			return a + (b - a) * ((d - acc) / l), (b - a) / l
		}
		acc += l
	}
	return points[len(points) - 1], {1, 0}
}

// Evenly spaced points along the path. spacing is a target: the actual step
// divides the length exactly so no gap comes up short. Open paths include
// both endpoints; closed ones don't repeat the start
resample :: proc(points: []Vec2, spacing: f32, closed := false, allocator := context.temp_allocator) -> []Vec2 {
	total := path_length(points, closed)
	if len(points) < 2 || spacing <= 0 || total <= 0 {
		return slice.clone(points, allocator)
	}
	n := max(int(math.round(total / spacing)), 1)
	step := total / f32(n)
	count := closed ? n : n + 1
	out := make([]Vec2, count, allocator)
	seg := 0
	nseg := closed ? len(points) : len(points) - 1
	seg_start := f32(0)
	seg_len := linalg.distance(points[0], points[1 % len(points)])
	for i in 0 ..< count {
		d := f32(i) * step
		for seg < nseg - 1 && seg_start + seg_len < d {
			seg_start += seg_len
			seg += 1
			seg_len = linalg.distance(points[seg], points[(seg + 1) % len(points)])
		}
		a := points[seg]
		b := points[(seg + 1) % len(points)]
		t := seg_len > 0 ? clamp((d - seg_start) / seg_len, 0, 1) : 0
		out[i] = a + (b - a) * t
	}
	return out
}

// The piece of the path between arc lengths d0 and d1 (clamped and swapped
// as needed). On closed paths distances run around the loop once from points[0]
subpath :: proc(points: []Vec2, d0, d1: f32, closed := false, allocator := context.temp_allocator) -> []Vec2 {
	if len(points) < 2 {
		return slice.clone(points, allocator)
	}
	total := path_length(points, closed)
	lo := clamp(min(d0, d1), 0, total)
	hi := clamp(max(d0, d1), 0, total)
	out := make([dynamic]Vec2, allocator)
	nseg := closed ? len(points) : len(points) - 1
	acc := f32(0)
	for i in 0 ..< nseg {
		a := points[i]
		b := points[(i + 1) % len(points)]
		l := linalg.distance(a, b)
		if l == 0 {
			continue
		}
		if acc + l > lo && acc < hi {
			t0 := max((lo - acc) / l, 0)
			t1 := min((hi - acc) / l, 1)
			if len(out) == 0 {
				append(&out, a + (b - a) * t0)
			}
			append(&out, a + (b - a) * t1)
		}
		acc += l
		if acc >= hi {
			break
		}
	}
	return out[:]
}

// Dash-gap strokes along the path
dashed :: proc(points: []Vec2, dash, gap: f32, closed := false) {
	total := path_length(points, closed)
	if dash <= 0 || gap <= 0 || total <= 0 {
		polyline(points, closed)
		return
	}
	for d := f32(0); d < total; d += dash + gap {
		polyline(subpath(points, d, min(d + dash, total), closed))
	}
}

// Pen-down dots every gap along the path, like dotted_line but for curves
dotted :: proc(points: []Vec2, gap: f32, closed := false) {
	if gap <= 0 {
		return
	}
	for p in resample(points, gap, closed) {
		point_v(p)
	}
}
