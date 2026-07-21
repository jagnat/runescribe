package plot

import "core:math"
import "core:math/linalg"
import "core:math/rand"

// Point scattering and neighbor queries: Bridson poisson-disk sampling for
// even random coverage, and a spatial hash grid for growth sims and
// stippling. poisson_disk draws from rand, so R rerolls layouts

// Random points over [lo, hi), no two closer than r. k is the attempts per
// active point before it retires
poisson_disk :: proc(lo, hi: Vec2, r: f32, k := 30, allocator := context.temp_allocator) -> []Vec2 {
	size := hi - lo
	if size.x <= 0 || size.y <= 0 || r <= 0 {
		return nil
	}
	cell := r / math.SQRT_TWO
	gw := max(int(math.ceil(size.x / cell)), 1)
	gh := max(int(math.ceil(size.y / cell)), 1)
	cells := make([]int, gw * gh, context.temp_allocator) // point index + 1, 0 empty
	pts := make([dynamic]Vec2, allocator)
	active := make([dynamic]int, context.temp_allocator)

	p0 := lo + size * {rand.float32(), rand.float32()}
	append(&pts, p0)
	append(&active, 0)
	cells[cell_of(p0, lo, cell, gw, gh)] = 1

	for len(active) > 0 {
		ai := rand.int_max(len(active))
		p := pts[active[ai]]
		found := false
		try: for _ in 0 ..< k {
			ang := rand.float32() * math.TAU
			d := r * math.sqrt(1 + 3 * rand.float32()) // uniform over the [r, 2r) annulus
			q := p + {d * math.cos(ang), d * math.sin(ang)}
			if q.x < lo.x || q.y < lo.y || q.x >= hi.x || q.y >= hi.y {
				continue
			}
			gx := int((q.x - lo.x) / cell)
			gy := int((q.y - lo.y) / cell)
			for yy in max(gy - 2, 0) ..= min(gy + 2, gh - 1) {
				for xx in max(gx - 2, 0) ..= min(gx + 2, gw - 1) {
					if idx := cells[yy * gw + xx]; idx > 0 && linalg.distance(pts[idx - 1], q) < r {
						continue try
					}
				}
			}
			cells[gy * gw + gx] = len(pts) + 1
			append(&active, len(pts))
			append(&pts, q)
			found = true
			break
		}
		if !found {
			unordered_remove(&active, ai)
		}
	}
	return pts[:]
}

@(private)
cell_of :: proc(p, lo: Vec2, cell: f32, gw, gh: int) -> int {
	gx := clamp(int((p.x - lo.x) / cell), 0, gw - 1)
	gy := clamp(int((p.y - lo.y) / cell), 0, gh - 1)
	return gy * gw + gx
}

// Spatial hash over unbounded space. Pick cell near your typical query
// radius; queries visit every bucket the radius overlaps
Grid :: struct {
	cell: f32,
	points: [dynamic]Vec2,
	cells: map[[2]i32][dynamic]int,
}

grid_make :: proc(cell: f32, allocator := context.temp_allocator) -> Grid {
	return {cell, make([dynamic]Vec2, allocator), make(map[[2]i32][dynamic]int, allocator)}
}

grid_insert :: proc(g: ^Grid, p: Vec2) -> int {
	idx := len(g.points)
	append(&g.points, p)
	key := grid_key(g, p)
	bucket, ok := g.cells[key]
	if !ok {
		bucket = make([dynamic]int, g.points.allocator)
	}
	append(&bucket, idx)
	g.cells[key] = bucket
	return idx
}

// Appends the indices of every point within r of p
grid_query :: proc(g: ^Grid, p: Vec2, r: f32, out: ^[dynamic]int) {
	klo, khi := grid_key_range(g, p, r)
	for ky in klo.y ..= khi.y {
		for kx in klo.x ..= khi.x {
			bucket, ok := g.cells[[2]i32{kx, ky}]
			if !ok {
				continue
			}
			for idx in bucket {
				if linalg.distance(g.points[idx], p) <= r {
					append(out, idx)
				}
			}
		}
	}
}

grid_has_within :: proc(g: ^Grid, p: Vec2, r: f32) -> bool {
	klo, khi := grid_key_range(g, p, r)
	for ky in klo.y ..= khi.y {
		for kx in klo.x ..= khi.x {
			bucket, ok := g.cells[[2]i32{kx, ky}]
			if !ok {
				continue
			}
			for idx in bucket {
				if linalg.distance(g.points[idx], p) <= r {
					return true
				}
			}
		}
	}
	return false
}

@(private)
grid_key :: proc(g: ^Grid, p: Vec2) -> [2]i32 {
	return {i32(math.floor(p.x / g.cell)), i32(math.floor(p.y / g.cell))}
}

@(private)
grid_key_range :: proc(g: ^Grid, p: Vec2, r: f32) -> (lo, hi: [2]i32) {
	return grid_key(g, p - r), grid_key(g, p + r)
}
