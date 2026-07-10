package sketch

import p "../../plot"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:os"
import "core:strconv"

Vec2 :: p.Vec2
Vec3 :: [3]f32
Vec3i :: [3]int

COS30 :: 0.86602540378
SIN30 :: 0.5
SCALE :: 24 // pixels per unit cell

XY_GRID_SIZE :: 16
Z_GRID_SIZE :: 16

Voxel :: struct {
	filled: bool,
}

Scene :: struct {
	tiles: [XY_GRID_SIZE][XY_GRID_SIZE][Z_GRID_SIZE]Voxel,
}

// Used for sketching on faces of voxels
Face :: struct {
	origin: Vec3, // the point
	u: Vec3, // dim analagous to +x
	v: Vec3, // dim analagous to +y
}

face_world :: proc(f: Face, s: Vec2) -> Vec3 {
	return f.origin + (s.x * f.u) + (s.y * f.v)
}

face_pt :: proc(f: Face, s: Vec2) -> Vec2 {
	return to_screen(face_world(f, s))
}

FaceDir :: enum { PosX, PosY }

// origin at the tile's face top-left, u right, v down; one sketch unit is one
// cell, so sketch coords outside [0,1] spill onto neighbouring tiles
wall_face :: proc(t: Vec3i, dir: FaceDir) -> Face {
	tx, ty, tz := f32(t.x), f32(t.y), f32(t.z)
	switch dir {
	case .PosX:
		return {origin = {tx + 1, ty, tz + 1}, u = {0, 1, 0}, v = {0, 0, -1}}
	case .PosY:
		return {origin = {tx, ty + 1, tz + 1}, u = {1, 0, 0}, v = {0, 0, -1}}
	}
	return {}
}

// affine sketch->screen collapsed to a 3x3: columns are the screen deltas
// per unit u and v, translation is origin
face_matrix :: proc(f: Face) -> p.Mat {
	o := to_screen(f.origin)
	du := to_screen(f.origin + f.u) - o
	dv := to_screen(f.origin + f.v) - o
	return {
		du.x, dv.x, o.x,
		du.y, dv.y, o.y,
		0, 0, 1,
	}
}

win: Vec2
origin: Vec2
scene: Scene

to_screen :: proc(c: Vec3) -> Vec2 {
	return {origin.x + (c.x - c.y) * COS30 * SCALE,
		origin.y + (c.x + c.y) * SIN30 * SCALE - c.z * SCALE}
}

set_filled :: proc { set_filled_1, set_filled_3 }
set_filled_1 :: proc(c: Vec3i, filled: bool = true) {
	set_filled_3(c.x, c.y, c.z, filled)
}
set_filled_3 :: proc(x, y, z: int, filled: bool = true) {
	scene.tiles[x][y][z].filled = filled
}

is_filled :: proc { is_filled_1, is_filled_3 }
is_filled_1 :: proc(c: Vec3i) -> bool {
	return is_filled_3(c.x, c.y, c.z)
}
is_filled_3 :: proc(x, y, z: int) -> bool {
	if x < 0 || x >= XY_GRID_SIZE || y < 0 || y >= XY_GRID_SIZE || z < 0 || z >= Z_GRID_SIZE do return false
	return scene.tiles[x][y][z].filled
}

fill_voxels :: proc(x0, y0, z0, x1, y1, z1: int, filled := true) {
	for x in x0 ..< x1 {
		for y in y0 ..< y1 {
			for z in z0 ..< z1 {
				set_filled(x, y, z, filled)
			}
		}
	}
}

DrawGroup :: struct {
	group: ^p.Group,
	lo, hi: Vec3,
}

groups: [dynamic]DrawGroup
current_group: DrawGroup

begin_group :: proc() {
	p.begin_group()
	current_group.lo = {max(f32), max(f32), max(f32)}
	current_group.hi = {min(f32), min(f32), min(f32)}
}

end_group :: proc() {
	current_group.group = p.end_group()
	append(&groups, current_group)
}

expand_group :: proc(w: Vec3) {
	current_group.lo = linalg.min(current_group.lo, w)
	current_group.hi = linalg.max(current_group.hi, w)
}

ogee :: proc(f: Face, lo := Vec2{0, 0}, hi := Vec2{1, 1}) {
	begin_group()
	expand_group(face_world(f, {lo.x, lo.y}))
	expand_group(face_world(f, {hi.x, lo.y}))
	expand_group(face_world(f, {lo.x, hi.y}))
	expand_group(face_world(f, {hi.x, hi.y}))

	p.push_matrix()
	p.canvas.xform = face_matrix(f)

	x0, y0, x1, y1 := lo.x, lo.y, hi.x, hi.y

	w := x1 - x0
	h := y1 - y0
	xc := x0 + w / 2 // center

	h_arch := w * 0.56
	h_vert := h - h_arch
	h_anchor := w * 0.25
	w_anchor := w * 0.2

	control_dist :f32= w * 0.16
	ang :: (30.0 / 180.0) * math.PI

	comp1_x := math.cos_f32(ang) * control_dist
	comp1_y := math.sin_f32(ang) * control_dist

	ya0 := y1 - h_vert
	ya1 := y0 + h_anchor

	xa0 := x0 + w_anchor
	xa1 := x1 - w_anchor

	p.line(x0, y1, x0, ya0)
	p.line(x1, y1, x1, ya0)

	p.bezier(x0, ya0, x0, ya0 - control_dist,
		xa0 - comp1_x, ya1 + comp1_y, xa0, ya1)
	p.bezier(xa0, ya1, xa0 + comp1_x, ya1 - comp1_y,
		xc, y0 + control_dist, xc, y0)
	p.bezier(x1, ya0, x1, ya0 - control_dist,
		xa1 + comp1_x, ya1 + comp1_y, xa1, ya1)
	p.bezier(xa1, ya1, xa1 - comp1_x, ya1 - comp1_y,
		xc, y0 + control_dist, xc, y0)

	p.pop_matrix()
	end_group()
}

FRAME_BEZIER_STEPS :: 48

append_bezier :: proc(pts: ^[dynamic]Vec2, a, c1, c2, b: Vec2) {
	it := p.make_bezier_iterator(a, c1, c2, b, FRAME_BEZIER_STEPS)
	first := true
	for {
		_, q, ok := p.iterate_bezier(&it)
		if !ok {
			break
		}
		if first {
			first = false
			continue // already the last point of pts
		}
		append(pts, q)
	}
	pts[len(pts) - 1] = b // accumulated t may stop short of 1
}

frame_ogee :: proc() {
	x0, y0: f32 = 100, 10
	x1, y1: f32 = win.x - 100, win.y - 10

	h := y1 - y0
	w := x1 - x0
	xc := x0 + w / 2 // center

	h_arch := w * 0.56
	h_vert := h - h_arch
	h_anchor := w * 0.25
	w_anchor := w * 0.2

	control_dist :f32= w * 0.16
	ang :: (30.0 / 180.0) * math.PI

	comp1_x := math.cos_f32(ang) * control_dist
	comp1_y := math.sin_f32(ang) * control_dist

	ya0 := y1 - h_vert
	ya1 := y0 + h_anchor

	xa0 := x0 + w_anchor
	xa1 := x1 - w_anchor

	left := make([dynamic]Vec2, context.temp_allocator)
	append(&left, Vec2{x0, y1}, Vec2{x0, ya0})
	append_bezier(&left, {x0, ya0}, {x0, ya0 - control_dist},
		{xa0 - comp1_x, ya1 + comp1_y}, {xa0, ya1})
	append_bezier(&left, {xa0, ya1}, {xa0 + comp1_x, ya1 - comp1_y},
		{xc, y0 + control_dist}, {xc, y0})

	right := make([dynamic]Vec2, context.temp_allocator)
	append(&right, Vec2{x1, y1}, Vec2{x1, ya0})
	append_bezier(&right, {x1, ya0}, {x1, ya0 - control_dist},
		{xa1 + comp1_x, ya1 + comp1_y}, {xa1, ya1})
	append_bezier(&right, {xa1, ya1}, {xa1 - comp1_x, ya1 - comp1_y},
		{xc, y0 + control_dist}, {xc, y0})

	// both halves end at the apex, so walk the right one back from below it
	for i := len(right) - 2; i >= 0; i -= 1 {
		append(&left, right[i])
	}

	p.polyline(left[:], closed = true)
	p.push_clip(left[:])
}

line3 :: proc(a, b: Vec3) {
	expand_group(a)
	expand_group(b)
	p.line(to_screen(a), to_screen(b))
}

poly3 :: proc(pts: []Vec3, closed := false) {
	scr := make([]Vec2, len(pts), context.temp_allocator)
	for w, i in pts {
		scr[i] = to_screen(w)
		expand_group(w)
	}
	p.polyline(scr, closed)
}

occlude3 :: proc(pts: []Vec3) {
	scr := make([]Vec2, len(pts), context.temp_allocator)
	for w, i in pts {
		scr[i] = to_screen(w)
		expand_group(w)
	}
	p.push_occlude(scr)
}

screen_bounds :: proc(e: ^DrawGroup) -> (lo, hi: Vec2) {
	lo = {max(f32), max(f32)}
	hi = {min(f32), min(f32)}
	// test all 8 corners
	for i in 0 ..< 8 {
		c := Vec3{
			i & 1 == 0 ? e.lo.x : e.hi.x,
			i & 2 == 0 ? e.lo.y : e.hi.y,
			i & 4 == 0 ? e.lo.z : e.hi.z,
		}
		s := to_screen(c)
		lo = linalg.min(lo, s)
		hi = linalg.max(hi, s)
	}
	return
}

in_front :: proc(a, b: ^DrawGroup) -> (front, known: bool) {
	EPS :: f32(0.001)
	alo, ahi := screen_bounds(a)
	blo, bhi := screen_bounds(b)
	if ahi.x < blo.x || bhi.x < alo.x || ahi.y < blo.y || bhi.y < alo.y {
		return false, false
	}
	if a.lo.z >= b.hi.z - EPS do return true, true
	if b.lo.z >= a.hi.z - EPS do return false, true
	if a.lo.x >= b.hi.x - EPS do return true, true
	if b.lo.x >= a.hi.x - EPS do return false, true
	if a.lo.y >= b.hi.y - EPS do return true, true
	if b.lo.y >= a.hi.y - EPS do return false, true
	return false, false
}

depth_key :: proc(e: ^DrawGroup) -> f32 {
	c := (e.lo + e.hi) / 2
	return c.x + c.y + c.z
}

order_groups :: proc(es: []DrawGroup) -> []int {
	n := len(es)
	out := make([]int, n, context.temp_allocator)
	used := make([]bool, n, context.temp_allocator)
	for k in 0 ..< n {
		best := -1
		best_key := min(f32)
		for i in 0 ..< n {
			if used[i] do continue
			blocked := false
			for j in 0 ..< n {
				if j == i || used[j] do continue
				if front, known := in_front(&es[j], &es[i]); known && front {
					blocked = true
					break
				}
			}
			if !blocked && depth_key(&es[i]) > best_key {
				best = i
				best_key = depth_key(&es[i])
			}
		}
		if best < 0 { // cycle: fall back to deepest centroid
			for i in 0 ..< n {
				if !used[i] && depth_key(&es[i]) > best_key {
					best = i
					best_key = depth_key(&es[i])
				}
			}
		}
		used[best] = true
		out[k] = best
	}
	return out
}

Segment :: struct {
	a, b: [2]int,
	n: [2]int, // outward normal
	cell: [2]int,
}

Chain :: struct {
	pts: [][2]int,
	closed: bool,
}

chain_segments :: proc(segs: []Segment) -> []Chain {
	chains := make([dynamic]Chain, context.temp_allocator)
	used := make([]bool, len(segs), context.temp_allocator)
	for pass in 0 ..< 2 {
		for si in 0 ..< len(segs) {
			if used[si] do continue
			if pass == 0 {
				pred := false
				for sj in 0 ..< len(segs) {
					if !used[sj] && sj != si && segs[sj].b == segs[si].a {
						pred = true
						break
					}
				}
				if pred do continue
			}
			run := make([dynamic][2]int, context.temp_allocator)
			append(&run, segs[si].a)
			curi := si
			for {
				used[curi] = true
				append(&run, segs[curi].b)
				nxt := -1
				for sj in 0 ..< len(segs) {
					if !used[sj] && segs[sj].a == segs[curi].b {
						nxt = sj
						break
					}
				}
				if nxt < 0 do break
				curi = nxt
			}
			closed := len(run) > 2 && run[0] == run[len(run) - 1]
			if closed {
				pop(&run)
			}
			out := make([dynamic][2]int, context.temp_allocator)
			m := len(run)
			for i in 0 ..< m {
				if closed || (i > 0 && i < m - 1) {
					prev := run[(i + m - 1) % m]
					next := run[(i + 1) % m]
					if run[i] - prev == next - run[i] {
						continue
					}
				}
				append(&out, run[i])
			}
			append(&chains, Chain{out[:], closed})
		}
	}
	return chains[:]
}

emit_chains :: proc(segs: []Segment, z: f32) {
	for ch in chain_segments(segs) {
		pts := make([]Vec3, len(ch.pts), context.temp_allocator)
		for gp, i in ch.pts {
			pts[i] = {f32(gp.x), f32(gp.y), z}
		}
		poly3(pts, ch.closed)
	}
}

INSET :: f32(0.035)

voxel_group :: proc(k: int, labels: ^[XY_GRID_SIZE][XY_GRID_SIZE]int, id: int) {
	segs := make([dynamic]Segment, context.temp_allocator)
	for x in 0 ..< XY_GRID_SIZE {
		for y in 0 ..< XY_GRID_SIZE {
			if labels[x][y] != id do continue
			// CCW winding
			if !is_filled(x + 1, y, k) do append(&segs, Segment{{x + 1, y}, {x + 1, y + 1}, {1, 0}, {x, y}})
			if !is_filled(x - 1, y, k) do append(&segs, Segment{{x, y + 1}, {x, y}, {-1, 0}, {x, y}})
			if !is_filled(x, y + 1, k) do append(&segs, Segment{{x + 1, y + 1}, {x, y + 1}, {0, 1}, {x, y}})
			if !is_filled(x, y - 1, k) do append(&segs, Segment{{x, y}, {x + 1, y}, {0, -1}, {x, y}})
		}
	}
	if len(segs) == 0 do return

	begin_group()
	zb := f32(k)
	zt := f32(k + 1)

	top := make([dynamic]Segment, context.temp_allocator)
	bot := make([dynamic]Segment, context.temp_allocator)
	for s in segs {
		facing := s.n == {1, 0} || s.n == {0, 1}
		nc := s.cell + s.n
		cu := is_filled(s.cell.x, s.cell.y, k + 1)
		nu := is_filled(nc.x, nc.y, k + 1)
		// for top edges, skip where the wall continues flush into the level above
		if !(cu && !nu) && (!cu || facing) {
			append(&top, s)
		}
		// for bottom crease, only consider viewer-facing
		// and skip where flush with below
		if facing {
			cd := is_filled(s.cell.x, s.cell.y, k - 1)
			nd := is_filled(nc.x, nc.y, k - 1)
			if !(cd && !nd) {
				append(&bot, s)
			}
		}
	}
	emit_chains(top[:], zt)

	// handle loop holes 
	cross_section :: proc(loops: []Chain, z: f32) {
		poly := make([dynamic]Vec2, context.temp_allocator)
		for ch, li in loops {
			start := len(poly)
			for gp in ch.pts {
				w := Vec3{f32(gp.x), f32(gp.y), z}
				append(&poly, to_screen(w))
				expand_group(w)
			}
			append(&poly, poly[start])
			if li > 0 {
				append(&poly, poly[0])
			}
		}
		p.push_occlude(poly[:])
	}
	loops := chain_segments(segs[:])
	cross_section(loops, zt)

	emit_chains(bot[:], zb)

	// corner verticals: visible iff the near (+x+y) cell is empty and the
	// other three cells around the corner form a corner, not a straight wall
	vdone := make(map[[2]int]bool, context.temp_allocator)
	for s in segs {
		pts := [2][2]int{s.a, s.b}
		for pt in pts {
			if vdone[pt] do continue
			vdone[pt] = true
			if is_filled(pt.x, pt.y, k) do continue // hidden behind the near cell
			mm := is_filled(pt.x - 1, pt.y - 1, k)
			pm := is_filled(pt.x, pt.y - 1, k)
			mp := is_filled(pt.x - 1, pt.y, k)
			if !mm && !pm && !mp do continue
			if mm && (pm != mp) do continue // wall runs straight through
			v := Vec3{f32(pt.x), f32(pt.y), zb}
			line3(v, v + {0, 0, 1})
		}
	}

	for s in segs {
		nc := s.cell + s.n
		ti := INSET
		if is_filled(s.cell.x, s.cell.y, k + 1) && !is_filled(nc.x, nc.y, k + 1) do ti = -INSET
		bi := INSET
		if is_filled(s.cell.x, s.cell.y, k - 1) && !is_filled(nc.x, nc.y, k - 1) do bi = -INSET
		d := s.b - s.a // unit grid step along the wall
		ea := f32(0)
		ca := s.cell - d
		if is_filled(ca.x, ca.y, k) && !is_filled(ca.x + s.n.x, ca.y + s.n.y, k) do ea = INSET
		eb := f32(0)
		cb := s.cell + d
		if is_filled(cb.x, cb.y, k) && !is_filled(cb.x + s.n.x, cb.y + s.n.y, k) do eb = INSET
		qa := Vec2{f32(s.a.x) - f32(d.x) * ea, f32(s.a.y) - f32(d.y) * ea}
		qb := Vec2{f32(s.b.x) + f32(d.x) * eb, f32(s.b.y) + f32(d.y) * eb}
		quad := [4]Vec3{
			{qa.x, qa.y, zt - ti},
			{qb.x, qb.y, zt - ti},
			{qb.x, qb.y, zb + bi},
			{qa.x, qa.y, zb + bi},
		}

		scr: [4]Vec2
		for w, i in quad {
			scr[i] = to_screen(w)
		}
		p.push_occlude(scr[:])
	}
	cross_section(loops, zb)
	end_group()
}

mesh_voxels :: proc() {
	dirs := [4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
	for k in 0 ..< Z_GRID_SIZE {
		labels: [XY_GRID_SIZE][XY_GRID_SIZE]int
		next := 1
		for x in 0 ..< XY_GRID_SIZE {
			for y in 0 ..< XY_GRID_SIZE {
				if !is_filled(x, y, k) || labels[x][y] != 0 do continue
				stack := make([dynamic][2]int, context.temp_allocator)
				append(&stack, [2]int{x, y})
				labels[x][y] = next
				for len(stack) > 0 {
					c := pop(&stack)
					for d in dirs {
						nb := c + d
						if is_filled(nb.x, nb.y, k) && labels[nb.x][nb.y] == 0 {
							labels[nb.x][nb.y] = next
							append(&stack, nb)
						}
					}
				}
				next += 1
			}
		}
		for id in 1 ..< next {
			voxel_group(k, &labels, id)
		}
	}
}

draw :: proc() {
	win = {p.canvas.width, p.canvas.height}
	origin = {win.x / 2, 3 * win.y / 4}
	// origin = {win.x / 2, win.y / 4}
	scene = {}
	groups = make([dynamic]DrawGroup, context.temp_allocator)
	frame_ogee()

	// fill_voxels(0, 0, 0, 1, 12, 12)
	// fill_voxels(0, 0, 0, 12, 1, 12)

	fill_voxels(0,0,0,4,1,4)

	//fill_voxels(2, 2, 0, 12, 12, 1) // plaza
	// fill_voxels(12,0,0,13,1,1)
	//fill_voxels(1, 1, 1, 2, 2, 2)
	// fill_voxels(7, 4, 0, 9, 6, 1, false) // courtyard hole
	// fill_voxels(2, 2, 1, 6, 6, 2) // terrace, flush with the plaza at x=2 / y=2
	// fill_voxels(9, 9, 1, 11, 11, 6) // tower
	// fill_voxels(12, 4, 0, 13, 8, 3) // wall off the plaza edge
	// fill_voxels(4, 8, 1, 5, 9, 3) // mushroom stem
	// fill_voxels(3, 8, 3, 6, 10, 4) // mushroom cap, overhanging the stem

	mesh_voxels()

	// ogee(wall_face({1, 1, 1}, .PosY), {0.1, -2}, {1.9, 1})
	//ogee(wall_face({2, 1, 1}, .PosY), {0.1, -2}, {1.9, 1})
	ogee(wall_face({2, 1, 1}, .PosY), {0.1, -1}, {0.9, 1})
	//ogee(wall_face({4, 1, 1}, .PosY), {0.1, -1}, {0.9, 1})

	order := order_groups(groups[:])
	for i in order {
		p.draw_group(groups[i].group)
	}
}

main :: proc() {
	p.run(600, 600, "calvinos cities", draw, loop = false)
}
