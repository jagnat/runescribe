package plot

import "core:math/linalg"
import "core:math/rand"
import "core:slice"

// Evenly spaced streamlines (Jobard-Lefer) through a direction field over
// [lo, hi]: lines seed spacing apart and stop within spacing / 2 of any
// earlier line, so the field fills without bunching. The field needs
// direction only; magnitude is ignored, and a zero vector ends the line.
// Returns local-space polylines -- draw with polyline(), or feed each
// through smooth/resample first

Vector_Field :: proc(p: Vec2) -> Vec2

streamlines :: proc(field: Vector_Field, lo, hi: Vec2, spacing: f32, step := f32(0), max_steps := 4096, allocator := context.temp_allocator) -> [][]Vec2 {
	step := step > 0 ? step : spacing / 4
	grid := grid_make(spacing, context.temp_allocator)
	out := make([dynamic][]Vec2, allocator)
	seeds := make([dynamic]Vec2, context.temp_allocator)
	append(&seeds, (lo + hi) / 2)
	for _ in 0 ..< 16 { // fallbacks in case early seeds land in dead zones
		append(&seeds, lo + (hi - lo) * {rand.float32(), rand.float32()})
	}

	line := make([dynamic]Vec2, context.temp_allocator)
	half := make([dynamic]Vec2, context.temp_allocator)

	for cursor := 0; cursor < len(seeds); cursor += 1 {
		seed := seeds[cursor]
		if seed.x < lo.x || seed.x > hi.x || seed.y < lo.y || seed.y > hi.y {
			continue
		}
		if grid_has_within(&grid, seed, spacing) {
			continue
		}

		clear(&line)
		clear(&half)
		trace_stream(field, &grid, seed, -1, step, spacing / 2, lo, hi, max_steps, &half)
		#reverse for p in half {
			append(&line, p)
		}
		append(&line, seed)
		clear(&half)
		trace_stream(field, &grid, seed, 1, step, spacing / 2, lo, hi, max_steps, &half)
		append(&line, ..half[:])
		if path_length(line[:]) < spacing {
			continue
		}

		for p in line {
			grid_insert(&grid, p)
		}
		append(&out, slice.clone(line[:], allocator))

		// candidate seeds one spacing to each side of the new line
		rs := resample(line[:], spacing)
		for i in 0 ..< len(rs) - 1 {
			side := perp(linalg.normalize0(rs[i + 1] - rs[i])) * spacing
			mid := (rs[i] + rs[i + 1]) / 2
			append(&seeds, mid + side, mid - side)
		}
	}
	return out[:]
}

// Midpoint (RK2) integration; the grid holds only finished lines, so a line
// never collides with itself -- max_steps caps closed orbits instead
@(private)
trace_stream :: proc(field: Vector_Field, grid: ^Grid, start: Vec2, sign, step, d_test: f32, lo, hi: Vec2, max_steps: int, out: ^[dynamic]Vec2) {
	p := start
	for _ in 0 ..< max_steps {
		k1 := linalg.normalize0(field(p)) * sign
		if k1 == (Vec2{}) {
			return
		}
		k2 := linalg.normalize0(field(p + k1 * (step / 2))) * sign
		if k2 == (Vec2{}) {
			k2 = k1
		}
		q := p + k2 * step
		if q.x < lo.x || q.x > hi.x || q.y < lo.y || q.y > hi.y {
			return
		}
		if grid_has_within(grid, q, d_test) {
			return
		}
		append(out, q)
		p = q
	}
}
