package plot

import "core:math"
import "core:slice"

// Marching squares: iso-lines of a scalar field sampled over [lo, hi] on a
// cell-sized grid, chained into polylines in local space. Closed loops come
// back with the first point repeated; open contours start and end on the
// region boundary. Features smaller than cell are missed. Draw each result
// with polyline()

Field :: proc(p: Vec2) -> f32

// Grid geometry shared by the contour helpers. Edge ids encode grid point
// (i, j) as 2 * (j * (nx + 1) + i), +1 when the edge runs vertically
@(private)
Ms_Grid :: struct {
	vals: []f32,
	lo, step: Vec2,
	nx: int,
}

contours :: proc(field: Field, iso: f32, lo, hi: Vec2, cell: f32, allocator := context.temp_allocator) -> [][]Vec2 {
	nx := max(int(math.ceil((hi.x - lo.x) / cell)), 1)
	ny := max(int(math.ceil((hi.y - lo.y) / cell)), 1)
	step := (hi - lo) / {f32(nx), f32(ny)}

	vals := make([]f32, (nx + 1) * (ny + 1), context.temp_allocator)
	for j in 0 ..= ny {
		for i in 0 ..= nx {
			v := field(lo + step * {f32(i), f32(j)}) - iso
			if v == 0 { // nudge off the iso so every crossing is unambiguous
				v = 1e-6
			}
			vals[j * (nx + 1) + i] = v
		}
	}
	g := Ms_Grid{vals, lo, step, nx}

	segs := make([dynamic][2]int, context.temp_allocator)
	for j in 0 ..< ny {
		for i in 0 ..< nx {
			a := vals[j * (nx + 1) + i]
			b := vals[j * (nx + 1) + i + 1]
			c := vals[(j + 1) * (nx + 1) + i + 1]
			d := vals[(j + 1) * (nx + 1) + i]
			code := int(a > 0) | int(b > 0) << 1 | int(c > 0) << 2 | int(d > 0) << 3
			if code == 0 || code == 15 {
				continue
			}
			bottom := 2 * (j * (nx + 1) + i)
			top := 2 * ((j + 1) * (nx + 1) + i)
			left := 2 * (j * (nx + 1) + i) + 1
			right := 2 * (j * (nx + 1) + i + 1) + 1
			switch code {
			case 1, 14:
				append(&segs, [2]int{left, bottom})
			case 2, 13:
				append(&segs, [2]int{bottom, right})
			case 3, 12:
				append(&segs, [2]int{left, right})
			case 4, 11:
				append(&segs, [2]int{right, top})
			case 6, 9:
				append(&segs, [2]int{bottom, top})
			case 7, 8:
				append(&segs, [2]int{left, top})
			case 5, 10: // saddle: the cell center decides which corners connect
				if (code == 5) == (a + b + c + d > 0) {
					append(&segs, [2]int{bottom, right}, [2]int{left, top})
				} else {
					append(&segs, [2]int{left, bottom}, [2]int{right, top})
				}
			}
		}
	}

	// Each edge touches at most two segments; chain them into polylines
	incs := make(map[int]Ms_Inc, context.temp_allocator)
	for s, si in segs {
		for e in s {
			inc := incs[e]
			if inc.n < 2 {
				inc.seg[inc.n] = si
				inc.n += 1
				incs[e] = inc
			}
		}
	}

	used := make([]bool, len(segs), context.temp_allocator)
	out := make([dynamic][]Vec2, allocator)
	chain := make([dynamic]Vec2, context.temp_allocator)
	back := make([dynamic]Vec2, context.temp_allocator)
	for s, si in segs {
		if used[si] {
			continue
		}
		used[si] = true
		clear(&back)
		ms_extend(g, s[0], segs[:], incs, used, &back)
		clear(&chain)
		#reverse for p in back {
			append(&chain, p)
		}
		append(&chain, ms_edge_point(g, s[0]), ms_edge_point(g, s[1]))
		ms_extend(g, s[1], segs[:], incs, used, &chain)
		append(&out, slice.clone(chain[:], allocator))
	}
	return out[:]
}

@(private)
Ms_Inc :: struct {
	n: int,
	seg: [2]int,
}

// Walks from edge e across unused segments, appending each far endpoint. A
// loop ends back on the walk's own start edge, repeating its point
@(private)
ms_extend :: proc(g: Ms_Grid, e: int, segs: [][2]int, incs: map[int]Ms_Inc, used: []bool, out: ^[dynamic]Vec2) {
	e := e
	for {
		inc := incs[e]
		si := -1
		for k in 0 ..< inc.n {
			if !used[inc.seg[k]] {
				si = inc.seg[k]
				break
			}
		}
		if si < 0 {
			return
		}
		used[si] = true
		e = segs[si][0] == e ? segs[si][1] : segs[si][0]
		append(out, ms_edge_point(g, e))
	}
}

@(private)
ms_edge_point :: proc(g: Ms_Grid, id: int) -> Vec2 {
	i := (id >> 1) % (g.nx + 1)
	j := (id >> 1) / (g.nx + 1)
	bi := id & 1 == 0 ? i + 1 : i
	bj := id & 1 == 0 ? j : j + 1
	a := g.vals[j * (g.nx + 1) + i]
	b := g.vals[bj * (g.nx + 1) + bi]
	p0 := g.lo + g.step * {f32(i), f32(j)}
	p1 := g.lo + g.step * {f32(bi), f32(bj)}
	return p0 + (p1 - p0) * (a / (a - b))
}
