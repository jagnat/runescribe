// Isometric floating cityscapes: terraced islands with stairs, arches,
// bridges, towers and roofs, suspended in empty sky. Started from the
// jul5_26_wfc box/occlusion machinery; see TECHNIQUES.md for the ideas.
package sketch

import p "../../plot"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:strconv"

Vec2 :: p.Vec2
Vec3 :: [3]f32

COS30 :: 0.86602540378
SIN30 :: 0.5
SPHERE :: 1.22474487 // screen radius of a unit sphere under this projection
SCALE :: 30.0

ACCENT :: p.Color{186, 72, 46}
HATCH_GRAY :: u8(138)

win: Vec2
origin: Vec2

to_screen :: proc(c: Vec3) -> Vec2 {
	return {origin.x + (c.x - c.y) * COS30 * SCALE,
		origin.y + (c.x + c.y) * SIN30 * SCALE - c.z * SCALE}
}

// Entities: everything solid is compiled into flat draw items at generation
// time (already projected), then depth-sorted and replayed front to back,
// each entity pushing its occluders after its own strokes.

Style :: enum {
	Ink,
	Hatch,
	Accent,
}

Item_Kind :: enum {
	Stroke,
	Dots,
	Occlude,
}

Item :: struct {
	pts: []Vec2,
	closed: bool,
	style: Style,
	kind: Item_Kind,
}

Entity :: struct {
	items: [dynamic]Item,
	lo, hi: Vec3, // world bounds, for depth ordering
}

ent_make :: proc() -> Entity {
	return {make([dynamic]Item, context.temp_allocator), Vec3{max(f32), max(f32), max(f32)}, Vec3{min(f32), min(f32), min(f32)}}
}

expand :: proc(e: ^Entity, w: Vec3) {
	e.lo = linalg.min(e.lo, w)
	e.hi = linalg.max(e.hi, w)
}

// Projects world points and appends one item; the world points also grow the bbox
add3 :: proc(e: ^Entity, pts: []Vec3, kind: Item_Kind, style := Style.Ink, closed := false) {
	scr := make([]Vec2, len(pts), context.temp_allocator)
	for w, i in pts {
		scr[i] = to_screen(w)
		expand(e, w)
	}
	append(&e.items, Item{scr, closed, style, kind})
}

line3 :: proc(e: ^Entity, a, b: Vec3, style := Style.Ink) {
	pts := [2]Vec3{a, b}
	add3(e, pts[:], .Stroke, style)
}

// Screen-space item; caller must have expanded the bbox already. Points are
// copied so stack-local arrays are safe to pass
add2 :: proc(e: ^Entity, pts: []Vec2, kind: Item_Kind, style := Style.Ink, closed := false) {
	append(&e.items, Item{slice.clone(pts, context.temp_allocator), closed, style, kind})
}

set_style :: proc(s: Style) {
	switch s {
	case .Ink:
		p.stroke(p.BLACK)
		p.stroke_weight(1.4)
	case .Hatch:
		p.stroke(HATCH_GRAY)
		p.stroke_weight(0.8)
	case .Accent:
		p.stroke(ACCENT)
		p.stroke_weight(1.2)
	}
}

draw_entity :: proc(e: ^Entity) {
	for it in e.items {
		switch it.kind {
		case .Stroke:
			set_style(it.style)
			p.polyline(it.pts, it.closed)
		case .Dots:
			set_style(it.style)
			for pt in it.pts {
				p.point(pt)
			}
		case .Occlude:
			p.push_occlude(it.pts)
		}
	}
}

// Depth ordering: draw front to back. For separated boxes the axis the view
// vector (1,1,1) crosses decides; otherwise fall back to centroid depth.

screen_bounds :: proc(e: ^Entity) -> (lo, hi: Vec2) {
	lo = Vec2{max(f32), max(f32)}
	hi = Vec2{min(f32), min(f32)}
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

// Whether a must be drawn before b (a nearer). known is false when their
// screen extents do not even overlap, or no separating axis exists
in_front :: proc(a, b: ^Entity) -> (front, known: bool) {
	EPS :: f32(0.01)
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

depth_key :: proc(e: ^Entity) -> f32 {
	c := (e.lo + e.hi) / 2
	return c.x + c.y + c.z
}

// Selection order: repeatedly emit an entity no other remaining entity is in
// front of, breaking ties (and cycles) by centroid depth
order_entities :: proc(ents: []Entity) -> []int {
	n := len(ents)
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
				if front, known := in_front(&ents[j], &ents[i]); known && front {
					blocked = true
					break
				}
			}
			if !blocked && depth_key(&ents[i]) > best_key {
				best = i
				best_key = depth_key(&ents[i])
			}
		}
		if best < 0 { // cycle: fall back to deepest centroid
			for i in 0 ..< n {
				if !used[i] && depth_key(&ents[i]) > best_key {
					best = i
					best_key = depth_key(&ents[i])
				}
			}
		}
		used[best] = true
		out[k] = best
	}
	return out
}

// Terraced islands. Each island is a small grid of cells; lvl counts how many
// stacked terrace levels contain the cell, under how many underside levels
// hang beneath it. Terrace k spans z cum[k-1]..cum[k].

GSIZE :: 19
GOFF :: 9
MAXL :: 5

Poi :: struct {
	pt: Vec2, // world xy on the terrace floor
	cell: [2]int,
}

Island :: struct {
	base: Vec3,
	L, U: int,
	lvl: [GSIZE][GSIZE]i8,
	under: [GSIZE][GSIZE]i8,
	used: [GSIZE][GSIZE]u8, // 0 free, 1 soft (tree/lamp), 2 solid
	cum: [MAXL]f32,
	cumd: [MAXL]f32,
	walk: [MAXL][dynamic][2]int,
	poi: [MAXL][dynamic]Poi,
	salt: f32,
}

in_grid :: proc(x, y: int) -> bool {
	return x >= -GOFF && x < GSIZE - GOFF && y >= -GOFF && y < GSIZE - GOFF
}

lvl_at :: proc(isl: ^Island, x, y: int) -> int {
	if !in_grid(x, y) do return 0
	return int(isl.lvl[x + GOFF][y + GOFF])
}

under_at :: proc(isl: ^Island, x, y: int) -> int {
	if !in_grid(x, y) do return 0
	return int(isl.under[x + GOFF][y + GOFF])
}

// Cell membership for terrace level k / underside level u (0-based)
in_level :: proc(isl: ^Island, x, y, k: int, under: bool) -> bool {
	if under {
		return under_at(isl, x, y) > k
	}
	return lvl_at(isl, x, y) > k
}

gen_island :: proc(isl: ^Island, base: Vec3, r0: f32, nl, nu: int) {
	isl.base = base
	isl.L = nl
	isl.U = nu
	isl.salt = base.x * 7.31 + base.y * 3.17
	for k in 0 ..< MAXL {
		isl.walk[k] = make([dynamic][2]int, context.temp_allocator)
		isl.poi[k] = make([dynamic]Poi, context.temp_allocator)
	}

	r := make([]f32, nl, context.temp_allocator)
	cx := make([]f32, nl, context.temp_allocator)
	cy := make([]f32, nl, context.temp_allocator)
	r[0] = r0
	cx[0] = 0
	cy[0] = 0
	for k in 1 ..< nl {
		r[k] = max(r[k - 1] - (1.0 + rand.float32() * 1.2), 1.3)
		cx[k] = cx[k - 1] + (rand.float32() - 0.5) * 1.6
		cy[k] = cy[k - 1] + (rand.float32() - 0.5) * 1.6
	}
	t := f32(0)
	for k in 0 ..< nl {
		th := k > 0 && rand.float32() < 0.3 ? f32(2) : f32(1)
		t += th
		isl.cum[k] = t
	}
	d := f32(0)
	for u in 0 ..< nu {
		d += 0.7 + f32(u) * 0.35 + rand.float32() * 0.35
		isl.cumd[u] = d
	}

	for gx in 0 ..< GSIZE {
		for gy in 0 ..< GSIZE {
			x := f32(gx - GOFF)
			y := f32(gy - GOFF)
			n := 0
			for k in 0 ..< nl {
				jit := (p.noise(x * 0.33 + isl.salt + f32(k) * 13.7, y * 0.33 - isl.salt) - 0.5) * 2.6
				md := abs(x + 0.5 - cx[k]) + abs(y + 0.5 - cy[k]) + jit
				if md < r[k] && n == k {
					n = k + 1
				}
			}
			isl.lvl[gx][gy] = i8(n)

			m := 0
			if n > 0 {
				ru := r0 - 0.9
				for u in 0 ..< nu {
					jit := (p.noise(x * 0.41 - isl.salt - f32(u) * 9.1, y * 0.41 + isl.salt) - 0.5) * 2.0
					md := abs(x + 0.5 - cx[0]) + abs(y + 0.5 - cy[0]) + jit
					if md < ru && m == u {
						m = u + 1
					}
					ru -= 1.4
				}
			}
			isl.under[gx][gy] = i8(m)
		}
	}

	for gx in 0 ..< GSIZE {
		for gy in 0 ..< GSIZE {
			n := int(isl.lvl[gx][gy])
			if n > 0 && n <= nl {
				append(&isl.walk[n - 1], [2]int{gx - GOFF, gy - GOFF})
			}
		}
	}
}

// Terrace slab entity for one level: contour-traced outlines so flat regions
// stay seamless, plus viewer-facing wall lines, corner verticals, hatching,
// arch niches and occluders.

Seg :: struct {
	a, b: [2]int,
	n: [2]int, // outward normal
	cell: [2]int,
}

level_entity :: proc(isl: ^Island, k: int, under: bool) -> (Entity, bool) {
	e := ent_make()

	zt, zb: f32
	if under {
		zt = -(k == 0 ? 0 : isl.cumd[k - 1])
		zb = -isl.cumd[k]
	} else {
		zb = k == 0 ? 0 : isl.cum[k - 1]
		zt = isl.cum[k]
	}
	wp :: proc(isl: ^Island, x, y, z: f32) -> Vec3 {
		return isl.base + Vec3{x, y, z}
	}

	segs := make([dynamic]Seg, context.temp_allocator)
	any := false
	for gx in 0 ..< GSIZE {
		for gy in 0 ..< GSIZE {
			x := gx - GOFF
			y := gy - GOFF
			if !in_level(isl, x, y, k, under) do continue
			any = true
			if !in_level(isl, x + 1, y, k, under) {
				append(&segs, Seg{{x + 1, y}, {x + 1, y + 1}, {1, 0}, {x, y}})
			}
			if !in_level(isl, x - 1, y, k, under) {
				append(&segs, Seg{{x, y + 1}, {x, y}, {-1, 0}, {x, y}})
			}
			if !in_level(isl, x, y + 1, k, under) {
				append(&segs, Seg{{x + 1, y + 1}, {x, y + 1}, {0, 1}, {x, y}})
			}
			if !in_level(isl, x, y - 1, k, under) {
				append(&segs, Seg{{x, y}, {x + 1, y}, {0, -1}, {x, y}})
			}
		}
	}
	if !any {
		return e, false
	}

	// Chain segments into closed loops for the top outline and the occluder
	taken := make([]bool, len(segs), context.temp_allocator)
	loops := make([dynamic][][2]int, context.temp_allocator)
	for si in 0 ..< len(segs) {
		if taken[si] do continue
		loop := make([dynamic][2]int, context.temp_allocator)
		cur := si
		for {
			taken[cur] = true
			append(&loop, segs[cur].a)
			nxt := -1
			for sj in 0 ..< len(segs) {
				if !taken[sj] && segs[sj].a == segs[cur].b {
					nxt = sj
					break
				}
			}
			if nxt < 0 do break
			cur = nxt
		}
		// drop collinear midpoints
		out := make([dynamic][2]int, context.temp_allocator)
		m := len(loop)
		for i in 0 ..< m {
			prev := loop[(i + m - 1) % m]
			next := loop[(i + 1) % m]
			if (loop[i].x - prev.x == next.x - loop[i].x) && (loop[i].y - prev.y == next.y - loop[i].y) {
				continue
			}
			append(&out, loop[i])
		}
		append(&loops, out[:])
	}

	// Top outline: terraces draw the full contour; underside levels only the
	// viewer-facing creases (their tops are buried in the mass above)
	if !under {
		for loop in loops {
			pts := make([]Vec3, len(loop), context.temp_allocator)
			for gp, i in loop {
				pts[i] = wp(isl, f32(gp.x), f32(gp.y), zt)
			}
			add3(&e, pts, .Stroke, .Ink, true)
		}
	}

	// Walls: bottom creases, verticals, hatching, arches (viewer-facing only)
	vdone := make(map[[2]int]bool, context.temp_allocator)
	for s in segs {
		facing := s.n == {1, 0} || s.n == {0, 1}
		if !facing do continue

		a3 := wp(isl, f32(s.a.x), f32(s.a.y), zt)
		b3 := wp(isl, f32(s.b.x), f32(s.b.y), zt)
		if under {
			line3(&e, a3, b3) // crease where this shelf meets the level above
		}

		// bottom crease, unless the wall continues flush into the level below
		flush: bool
		if under {
			flush = in_level(isl, s.cell.x, s.cell.y, k + 1, true) && k + 1 < isl.U
		} else {
			nx := s.cell.x + s.n.x
			ny := s.cell.y + s.n.y
			flush = k > 0 && !in_level(isl, nx, ny, k - 1, false)
		}
		if !flush {
			line3(&e, a3 - {0, 0, zt - zb}, b3 - {0, 0, zt - zb})
		}

		// corner verticals, deduped across the two walls that meet there
		cx := s.cell.x
		cy := s.cell.y
		ends: [2][2]int
		diag, str: [2][2]int
		if s.n == {1, 0} {
			ends = {{cx + 1, cy + 1}, {cx + 1, cy}}
			diag = {{cx + 1, cy + 1}, {cx + 1, cy - 1}}
			str = {{cx, cy + 1}, {cx, cy - 1}}
		} else {
			ends = {{cx + 1, cy + 1}, {cx, cy + 1}}
			diag = {{cx + 1, cy + 1}, {cx - 1, cy + 1}}
			str = {{cx + 1, cy}, {cx - 1, cy}}
		}
		for i in 0 ..< 2 {
			if vdone[ends[i]] do continue
			if in_level(isl, diag[i].x, diag[i].y, k, under) do continue // hidden behind that cell
			if in_level(isl, str[i].x, str[i].y, k, under) do continue // wall continues straight
			vdone[ends[i]] = true
			v := wp(isl, f32(ends[i].x), f32(ends[i].y), zb)
			line3(&e, v, v + {0, 0, zt - zb})
		}

		// hatch the left-facing walls for volume
		if s.n == {0, 1} {
			u := f32(0.16)
			for u < 0.95 {
				h0 := wp(isl, f32(s.cell.x) + u, f32(s.cell.y + 1), zb)
				line3(&e, h0, h0 + {0, 0, zt - zb}, .Hatch)
				u += 0.27
			}
		}

		// arch niches in patches along taller right-facing terrace walls
		if !under && s.n == {1, 0} && zt - zb >= 0.99 {
			if p.noise(f32(s.cell.x) * 0.45 + isl.salt + 60, f32(s.cell.y) * 0.45) > 0.52 {
				uv := arch_uv(0.5, 0, 0.52, min(0.72, zt - zb - 0.25), false)
				pts := make([]Vec3, len(uv), context.temp_allocator)
				for q, i in uv {
					pts[i] = wp(isl, f32(s.a.x), f32(s.a.y) + q.x, zb + q.y)
				}
				add3(&e, pts, .Stroke, .Ink, false)
			}
		}
	}

	// Occluders: the top region (all loops keyholed into one even-odd
	// polygon) plus one quad per viewer-facing wall segment
	total := 0
	for loop in loops {
		total += len(loop) + 2
	}
	poly := make([dynamic]Vec2, 0, total, context.temp_allocator)
	for loop, li in loops {
		for gp in loop {
			w := wp(isl, f32(gp.x), f32(gp.y), zt)
			append(&poly, to_screen(w))
			expand(&e, w)
		}
		first := to_screen(wp(isl, f32(loop[0].x), f32(loop[0].y), zt))
		append(&poly, first)
		if li > 0 {
			append(&poly, poly[0])
		}
	}
	add2(&e, poly[:], .Occlude)
	// wall quads keep their full length so adjacent quads tile seamlessly,
	// but are inset vertically so lines other entities draw exactly along the
	// top or bottom edge (a lower terrace's rim) are not eaten
	INSET :: f32(0.035)
	for s in segs {
		if s.n != {1, 0} && s.n != {0, 1} do continue
		quad := [4]Vec3{
			wp(isl, f32(s.a.x), f32(s.a.y), zt - INSET),
			wp(isl, f32(s.b.x), f32(s.b.y), zt - INSET),
			wp(isl, f32(s.b.x), f32(s.b.y), zb + INSET),
			wp(isl, f32(s.a.x), f32(s.a.y), zb + INSET),
		}
		add3(&e, quad[:], .Occlude, .Ink, true)
	}
	return e, true
}

// Buildings: a box with clean single-stroke edges, face details in the two
// visible wall planes, and a roof

Roof :: enum {
	None,
	Pyramid,
	Dome,
	Crenel,
	Gable_X,
	Gable_Y,
}

Building :: struct {
	pos: Vec3,
	size: Vec3,
	roof: Roof,
	door: bool,
	windows: bool,
}

// Closed arch outline in a wall's uv plane (u along the wall, v up); open
// omits the bottom edge for doorways
arch_uv :: proc(cu, v0, w, h: f32, closed: bool) -> []Vec2 {
	r := w / 2
	n := 7
	pts := make([dynamic]Vec2, context.temp_allocator)
	append(&pts, Vec2{cu + r, v0})
	append(&pts, Vec2{cu + r, v0 + h - r})
	for i in 1 ..< n {
		a := f32(i) / f32(n) * math.PI
		append(&pts, Vec2{cu + r * math.cos(a), v0 + h - r + r * math.sin(a)})
	}
	append(&pts, Vec2{cu - r, v0 + h - r})
	append(&pts, Vec2{cu - r, v0})
	if closed {
		append(&pts, Vec2{cu + r, v0})
	}
	return pts[:]
}

// face 0: +X wall, u along +y; face 1: +Y wall, u along +x
face_pt :: proc(b: ^Building, face: int, u, v: f32) -> Vec3 {
	if face == 0 {
		return b.pos + {b.size.x, u, v}
	}
	return b.pos + {u, b.size.y, v}
}

face_poly :: proc(e: ^Entity, b: ^Building, face: int, uv: []Vec2, closed: bool, style := Style.Ink) {
	pts := make([]Vec3, len(uv), context.temp_allocator)
	for q, i in uv {
		pts[i] = face_pt(b, face, q.x, q.y)
	}
	add3(e, pts, .Stroke, style, closed)
}

building_entity :: proc(b: ^Building) -> Entity {
	e := ent_make()
	x0 := b.pos.x
	y0 := b.pos.y
	z0 := b.pos.z
	x1 := x0 + b.size.x
	y1 := y0 + b.size.y
	z1 := z0 + b.size.z

	// roof first: its occluder then hides the box's top-face lines beneath it
	switch b.roof {
	case .None:
	case .Pyramid:
		apex := Vec3{(x0 + x1) / 2, (y0 + y1) / 2, z1 + 0.9 * min(b.size.x, b.size.y)}
		line3(&e, apex, {x1, y0, z1})
		line3(&e, apex, {x1, y1, z1})
		line3(&e, apex, {x0, y1, z1})
		occ := [4]Vec3{apex, {x1, y0, z1}, {x1, y1, z1}, {x0, y1, z1}}
		add3(&e, occ[:], .Occlude, .Ink, true)
		// flag
		tip := to_screen(apex)
		top := tip - Vec2{0, 0.5 * SCALE}
		pole := [2]Vec2{tip, top}
		add2(&e, pole[:], .Stroke, .Ink)
		tri := [3]Vec2{top, top + {0.3 * SCALE, 0.08 * SCALE}, top + {0, 0.17 * SCALE}}
		add2(&e, tri[:], .Stroke, .Accent, true)
		expand(&e, apex + {0, 0, 0.8})
	case .Dome:
		r := 0.44 * min(b.size.x, b.size.y)
		c := to_screen({(x0 + x1) / 2, (y0 + y1) / 2, z1})
		rs := r * SPHERE * SCALE
		n := 14
		occ := make([dynamic]Vec2, context.temp_allocator)
		crown := make([]Vec2, n + 1, context.temp_allocator)
		for i in 0 ..= n {
			a := math.PI + f32(i) / f32(n) * math.PI
			crown[i] = c + rs * Vec2{math.cos(a), math.sin(a)}
			append(&occ, crown[i])
		}
		add2(&e, crown, .Stroke, .Ink)
		base := make([]Vec2, n + 1, context.temp_allocator)
		for i in 0 ..= n {
			a := -math.PI / 4 + f32(i) / f32(n) * math.PI
			w := Vec3{(x0 + x1) / 2 + r * math.cos(a), (y0 + y1) / 2 + r * math.sin(a), z1}
			base[n - i] = to_screen(w)
			append(&occ, base[n - i])
		}
		add2(&e, base, .Stroke, .Ink)
		add2(&e, occ[:], .Occlude)
		fin := [2]Vec2{c - {0, rs}, c - {0, rs + 4}}
		add2(&e, fin[:], .Stroke, .Accent)
		expand(&e, {(x0 + x1) / 2, (y0 + y1) / 2, z1 + r * 1.4})
	case .Crenel:
		for face in 0 ..< 2 {
			fw := face == 0 ? b.size.y : b.size.x
			nm := max(int(fw / 0.42), 2)
			for i in 0 ..< nm {
				cu := fw * (f32(i) + 0.5) / f32(nm)
				mr := [4]Vec2{
					{cu - 0.09, b.size.z}, {cu - 0.09, b.size.z + 0.16},
					{cu + 0.09, b.size.z + 0.16}, {cu + 0.09, b.size.z},
				}
				face_poly(&e, b, face, mr[:], false)
			}
		}
		expand(&e, {x1, y1, z1 + 0.2})
	case .Gable_X, .Gable_Y:
		if b.roof == .Gable_X {
			ym := (y0 + y1) / 2
			zr := z1 + 0.8 * b.size.y
			line3(&e, {x1, y0, z1}, {x1, ym, zr})
			line3(&e, {x1, ym, zr}, {x1, y1, z1})
			line3(&e, {x1, ym, zr}, {x0, ym, zr})
			line3(&e, {x0, ym, zr}, {x0, y1, z1})
			occ := [5]Vec3{{x1, y0, z1}, {x1, ym, zr}, {x0, ym, zr}, {x0, y1, z1}, {x1, y1, z1}}
			add3(&e, occ[:], .Occlude, .Ink, true)
		} else {
			xm := (x0 + x1) / 2
			zr := z1 + 0.8 * b.size.x
			line3(&e, {x0, y1, z1}, {xm, y1, zr})
			line3(&e, {xm, y1, zr}, {x1, y1, z1})
			line3(&e, {xm, y1, zr}, {xm, y0, zr})
			line3(&e, {xm, y0, zr}, {x1, y0, z1})
			occ := [5]Vec3{{x0, y1, z1}, {xm, y1, zr}, {xm, y0, zr}, {x1, y0, z1}, {x1, y1, z1}}
			add3(&e, occ[:], .Occlude, .Ink, true)
		}
	}

	hex := [6]Vec3{{x0, y1, z1}, {x0, y0, z1}, {x1, y0, z1}, {x1, y0, z0}, {x1, y1, z0}, {x0, y1, z0}}
	add3(&e, hex[:], .Stroke, .Ink, true)
	j := Vec3{x1, y1, z1}
	line3(&e, j, {x1, y0, z1})
	line3(&e, j, {x0, y1, z1})
	line3(&e, j, {x1, y1, z0})

	// hatch the +Y wall
	u := f32(0.14)
	for u < b.size.x - 0.05 {
		line3(&e, {x0 + u, y1, z0}, {x0 + u, y1, z1}, .Hatch)
		u += 0.27
	}

	if b.door {
		face_poly(&e, b, 0, arch_uv(b.size.y / 2, 0, 0.4, 0.64, false), false)
	}
	if b.windows {
		for face in 0 ..< 2 {
			fw := face == 0 ? b.size.y : b.size.x
			cols := fw > 1.3 ? 2 : 1
			v0 := b.door && face == 0 ? f32(0.95) : f32(0.45)
			for v0 + 0.4 < b.size.z - 0.12 {
				for c in 0 ..< cols {
					cu := fw * (f32(c) + 1) / (f32(cols) + 1)
					face_poly(&e, b, face, arch_uv(cu, v0, 0.24, 0.4, true), true)
				}
				v0 += 0.78
			}
		}
	}

	add3(&e, hex[:], .Occlude, .Ink, true)
	return e
}

// Stairs ascend away from the viewer (-x for dir 0, -y for dir 1) inside one
// cell footprint, so treads and risers both face the camera

stair_entity :: proc(pos: Vec3, dir: int, dz: f32, nsteps: int) -> Entity {
	e := ent_make()
	n := nsteps
	d := 1.0 / f32(n)
	sz := dz / f32(n)

	// step corner in (run, z), then swizzled into world by dir
	sp :: proc(pos: Vec3, dir: int, run, cross, z: f32) -> Vec3 {
		if dir == 0 {
			return {pos.x + 1 - run, pos.y + cross, pos.z + z}
		}
		return {pos.x + cross, pos.y + 1 - run, pos.z + z}
	}

	zig :: proc(e: ^Entity, pos: Vec3, dir: int, cross: f32, n: int, d, sz: f32) -> []Vec2 {
		pts := make([]Vec2, 2 * n + 1, context.temp_allocator)
		w := sp(pos, dir, 0, cross, 0)
		pts[0] = to_screen(w)
		expand(e, w)
		for i in 0 ..< n {
			w = sp(pos, dir, f32(i) * d, cross, f32(i + 1) * sz)
			pts[2 * i + 1] = to_screen(w)
			expand(e, w)
			w = sp(pos, dir, f32(i + 1) * d, cross, f32(i + 1) * sz)
			pts[2 * i + 2] = to_screen(w)
			expand(e, w)
		}
		return pts
	}

	near := zig(&e, pos, dir, 1, n, d, sz) // rail on the +cross side
	far := zig(&e, pos, dir, 0, n, d, sz)
	add2(&e, near, .Stroke, .Ink)
	add2(&e, far, .Stroke, .Ink)

	for i in 0 ..< n {
		a := sp(pos, dir, f32(i) * d, 0, f32(i + 1) * sz)
		b := sp(pos, dir, f32(i) * d, 1, f32(i + 1) * sz)
		line3(&e, a, b) // tread front edge
		if i < n - 1 { // concave crease; the top one lands on the upper wall
			line3(&e, sp(pos, dir, f32(i + 1) * d, 0, f32(i + 1) * sz), sp(pos, dir, f32(i + 1) * d, 1, f32(i + 1) * sz))
		}
	}

	// occluders: the stepped surface band, then the visible side skirt
	band := make([]Vec2, len(near) + len(far), context.temp_allocator)
	copy(band, near)
	for q, i in far {
		band[len(near) + len(far) - 1 - i] = q
	}
	add2(&e, band, .Occlude)

	skirt_cross := f32(dir == 0 ? 1 : 1) // +y side for dir 0, +x side for dir 1: both are cross=1
	rail := zig(&e, pos, dir, skirt_cross, n, d, sz)
	skirt := make([]Vec2, len(rail) + 1, context.temp_allocator)
	copy(skirt, rail)
	skirt[len(rail)] = to_screen(sp(pos, dir, 1, skirt_cross, 0))
	add2(&e, skirt, .Occlude)
	return e
}

// Bridge: a thin deck slab with railings and hanging arches, Escher aqueduct
// style. a and b are deck-top centreline endpoints at equal z

bridge_entity :: proc(a, b: Vec3, w: f32) -> Entity {
	e := ent_make()
	th := f32(0.16)
	railh := f32(0.3)
	dirv := linalg.normalize(b - a)
	side := Vec3{-dirv.y, dirv.x, 0}
	if side.x + side.y < 0 {
		side = -side
	}
	hw := side * (w / 2)
	length := linalg.distance(a, b)

	line3(&e, a + hw, b + hw)
	line3(&e, a - hw, b - hw)
	line3(&e, a + hw - {0, 0, th}, b + hw - {0, 0, th})
	rail_off := Vec3{0, 0, railh}
	line3(&e, a + hw + rail_off, b + hw + rail_off)
	line3(&e, a - hw + rail_off, b - hw + rail_off)
	nposts := max(int(length / 0.8), 2)
	for i in 0 ..= nposts {
		t := f32(i) / f32(nposts)
		q := a + (b - a) * t
		line3(&e, q + hw, q + hw + rail_off)
		line3(&e, q - hw, q - hw + rail_off)
	}

	// shallow arches hanging beneath the deck, one per ~1.6 units of span
	narch := max(int(length / 1.6), 1)
	sub := length / f32(narch)
	rx := sub / 2 - 0.05
	rz := min(rx, 0.55)
	for i in 0 ..< narch {
		m := a + dirv * (sub * (f32(i) + 0.5)) + hw - {0, 0, th}
		zc := m.z - rz
		pts := make([]Vec3, 13, context.temp_allocator)
		for s in 0 ..= 12 {
			t := f32(s) / 12 * math.PI
			pts[s] = Vec3{m.x, m.y, 0} + dirv * (rx * math.cos(t))
			pts[s].z = zc + rz * math.sin(t)
		}
		add3(&e, pts, .Stroke, .Ink)
		// piers between arches
		p0 := a + dirv * (sub * f32(i)) + hw - {0, 0, th}
		line3(&e, p0, {p0.x, p0.y, zc})
		if i == narch - 1 {
			p1 := a + dirv * (sub * f32(i + 1)) + hw - {0, 0, th}
			line3(&e, p1, {p1.x, p1.y, zc})
		}
	}

	deck := [4]Vec3{a + hw, b + hw, b - hw, a - hw}
	add3(&e, deck[:], .Occlude, .Ink, true)
	front := [4]Vec3{a + hw, b + hw, b + hw - {0, 0, th}, a + hw - {0, 0, th}}
	add3(&e, front[:], .Occlude, .Ink, true)
	return e
}

tree_entity :: proc(pos: Vec3) -> Entity {
	e := ent_make()
	top := pos + {0, 0, 0.5}
	line3(&e, pos, top)
	c := to_screen(pos + {0, 0, 0.95})
	r := (0.4 + rand.float32() * 0.15) * SCALE
	nb := 10
	blob := make([]Vec2, nb, context.temp_allocator)
	for i in 0 ..< nb {
		a := f32(i) / f32(nb) * math.TAU
		rr := r * (0.82 + 0.36 * p.noise(pos.x * 0.4 + math.cos(a) * 0.9, pos.y * 0.4 + math.sin(a) * 0.9))
		blob[i] = c + rr * Vec2{math.cos(a), math.sin(a) * 0.9}
	}
	blob = p.smooth(blob, 2, true)
	add2(&e, blob, .Stroke, .Ink, true)
	add2(&e, blob, .Occlude)
	// a small inner tuft
	tuft := make([]Vec2, 7, context.temp_allocator)
	for i in 0 ..< 7 {
		a := 2.6 + f32(i) / 6 * 2.4
		tuft[i] = c + {r * 0.15, r * 0.2} + r * 0.45 * Vec2{math.cos(a), math.sin(a)}
	}
	add2(&e, tuft, .Stroke, .Ink)
	expand(&e, pos + {0.7, 0.7, 1.6})
	expand(&e, pos - {0.7, 0.7, 0})
	return e
}

lamp_entity :: proc(pos: Vec3) -> Entity {
	e := ent_make()
	top := pos + {0, 0, 0.72}
	line3(&e, pos, top)
	c := to_screen(top) - Vec2{0, 3.4}
	n := 8
	head := make([]Vec2, n, context.temp_allocator)
	for i in 0 ..< n {
		a := f32(i) / f32(n) * math.TAU
		head[i] = c + 3.2 * Vec2{math.cos(a), math.sin(a)}
	}
	add2(&e, head, .Stroke, .Accent, true)
	expand(&e, pos + {0.15, 0.15, 0.95})
	return e
}

path_entity :: proc(dots: []Vec2, lo, hi: Vec3) -> Entity {
	e := ent_make()
	expand(&e, lo)
	expand(&e, hi)
	add2(&e, dots, .Dots, .Accent)
	return e
}

// Decorations recorded outside the entity pass

lens_cloud :: proc(c: Vec2, rx, ry: f32, salt: f32) {
	n := 22
	pts := make([]Vec2, n, context.temp_allocator)
	for i in 0 ..< n {
		a := f32(i) / f32(n) * math.TAU
		wob := 0.86 + 0.28 * p.noise(salt + math.cos(a) * 1.1, salt * 0.7 + math.sin(a) * 1.1)
		pts[i] = c + {rx * math.cos(a) * wob, ry * math.sin(a) * wob}
	}
	sm := p.smooth(pts, 2, true)
	p.polyline(sm, true)
	p.push_occlude(sm)
}

bird :: proc(c: Vec2, w: f32) {
	p.arc(c.x - w / 2, c.y + w * 0.32, w * 0.62, math.PI * 1.2, math.PI * 1.8)
	p.arc(c.x + w / 2, c.y + w * 0.32, w * 0.62, math.PI * 1.2, math.PI * 1.8)
}

// Generation

islands: [3]Island

decorate_island :: proc(isl: ^Island, ents: ^[dynamic]Entity, nhouse, ntower, ntree, nlamp, nstair: int) {
	mark :: proc(isl: ^Island, c: [2]int, v: u8) {
		isl.used[c.x + GOFF][c.y + GOFF] = v
	}
	free_cell :: proc(isl: ^Island, c: [2]int) -> bool {
		return isl.used[c.x + GOFF][c.y + GOFF] == 0
	}

	// stairs first, so they claim cells with the right adjacency
	placed := 0
	cands := make([dynamic][3]int, context.temp_allocator) // cell + dir
	for k in 0 ..< isl.L - 1 {
		for c in isl.walk[k] {
			if lvl_at(isl, c.x - 1, c.y) == k + 2 {
				append(&cands, [3]int{c.x, c.y, 0})
			}
			if lvl_at(isl, c.x, c.y - 1) == k + 2 {
				append(&cands, [3]int{c.x, c.y, 1})
			}
		}
	}
	rand.shuffle(cands[:])
	for cand in cands {
		if placed >= nstair do break
		c := [2]int{cand.x, cand.y}
		if !free_cell(isl, c) do continue
		k := lvl_at(isl, c.x, c.y) - 1
		dz := isl.cum[k + 1] - isl.cum[k]
		pos := isl.base + Vec3{f32(c.x), f32(c.y), isl.cum[k]}
		append(ents, stair_entity(pos, cand.z, dz, int(dz * 4)))
		mark(isl, c, 2)
		// path endpoints at bottom and top
		front := cand.z == 0 ? [2]int{c.x + 1, c.y} : [2]int{c.x, c.y + 1}
		if lvl_at(isl, front.x, front.y) == k + 1 {
			append(&isl.poi[k], Poi{{f32(front.x) + 0.5, f32(front.y) + 0.5}, front})
		}
		top := cand.z == 0 ? [2]int{c.x - 1, c.y} : [2]int{c.x, c.y - 1}
		append(&isl.poi[k + 1], Poi{{f32(top.x) + 0.5, f32(top.y) + 0.5}, top})
		placed += 1
	}

	place :: proc(isl: ^Island, klo, khi: int) -> ([2]int, int, bool) {
		for _ in 0 ..< 40 {
			k := klo + int(rand.int31_max(i32(khi - klo + 1)))
			if k >= isl.L || len(isl.walk[k]) == 0 do continue
			c := rand.choice(isl.walk[k][:])
			if isl.used[c.x + GOFF][c.y + GOFF] == 0 {
				return c, k, true
			}
		}
		return {}, 0, false
	}

	for _ in 0 ..< ntower {
		c, k, ok := place(isl, max(isl.L - 2, 0), isl.L - 1)
		if !ok do continue
		mark(isl, c, 2)
		roofs := [3]Roof{.Pyramid, .Dome, .Crenel}
		b := Building{
			pos = isl.base + Vec3{f32(c.x) + 0.1, f32(c.y) + 0.1, isl.cum[k]},
			size = {0.8, 0.8, 1.8 + rand.float32() * 1.7},
			roof = rand.choice(roofs[:]),
			door = true,
			windows = true,
		}
		append(ents, building_entity(&b))
		append(&isl.poi[k], Poi{{f32(c.x) + 1.4, f32(c.y) + 0.5}, {c.x + 1, c.y}})
	}

	for _ in 0 ..< nhouse {
		c, k, ok := place(isl, 0, max(isl.L - 2, 0))
		if !ok do continue
		mark(isl, c, 2)
		wide := rand.float32() < 0.4 && lvl_at(isl, c.x, c.y + 1) == k + 1 && free_cell(isl, {c.x, c.y + 1})
		size := Vec3{0.84, 0.84, 0.9 + rand.float32() * 0.5}
		if wide {
			mark(isl, {c.x, c.y + 1}, 2)
			size.y = 1.84
		}
		b := Building{
			pos = isl.base + Vec3{f32(c.x) + 0.08, f32(c.y) + 0.08, isl.cum[k]},
			size = size,
			roof = wide ? .Gable_Y : (rand.float32() < 0.5 ? .Gable_X : .Gable_Y),
			door = true,
			windows = rand.float32() < 0.75,
		}
		append(ents, building_entity(&b))
		append(&isl.poi[k], Poi{{f32(c.x) + 1.4, f32(c.y) + 0.5}, {c.x + 1, c.y}})
	}

	for _ in 0 ..< ntree {
		c, k, ok := place(isl, 0, isl.L - 1)
		if !ok do continue
		mark(isl, c, 1)
		append(ents, tree_entity(isl.base + Vec3{f32(c.x) + 0.5, f32(c.y) + 0.5, isl.cum[k]}))
	}

	for _ in 0 ..< nlamp {
		c, k, ok := place(isl, 0, isl.L - 1)
		if !ok do continue
		mark(isl, c, 1)
		append(ents, lamp_entity(isl.base + Vec3{f32(c.x) + 0.3, f32(c.y) + 0.3, isl.cum[k]}))
	}
}

// Dotted walking paths between points of interest on one terrace
make_paths :: proc(isl: ^Island, ents: ^[dynamic]Entity) {
	for k in 0 ..< isl.L {
		if len(isl.poi[k]) < 2 do continue
		a := isl.poi[k][0]
		b := isl.poi[k][1]
		if a.cell == b.cell do continue

		route_ok :: proc(isl: ^Island, k: int, a, b: [2]int, corner: [2]int) -> bool {
			check :: proc(isl: ^Island, k: int, from, to, xa, xb: [2]int) -> bool {
				d := [2]int{0, 0}
				if to.x != from.x do d.x = to.x > from.x ? 1 : -1
				if to.y != from.y do d.y = to.y > from.y ? 1 : -1
				c := from
				for {
					if lvl_at(isl, c.x, c.y) != k + 1 do return false
					if isl.used[c.x + GOFF][c.y + GOFF] == 2 && c != xa && c != xb do return false
					if c == to do return true
					c += d
				}
			}
			return check(isl, k, a, corner, a, b) && check(isl, k, corner, b, a, b)
		}

		corner := [2]int{b.cell.x, a.cell.y}
		ok := route_ok(isl, k, a.cell, b.cell, corner)
		if !ok {
			corner = {a.cell.x, b.cell.y}
			ok = route_ok(isl, k, a.cell, b.cell, corner)
		}
		if !ok do continue

		cw := Vec2{f32(corner.x) + 0.5, f32(corner.y) + 0.5}
		raw := make([dynamic]Vec2, context.temp_allocator)
		leg :: proc(raw: ^[dynamic]Vec2, from, to: Vec2) {
			steps := max(int(linalg.distance(from, to) / 0.55), 1)
			for i in 0 ..< steps {
				t := f32(i) / f32(steps)
				q := from + (to - from) * t
				q.x += (p.noise(q.x * 0.8 + 31, q.y * 0.8) - 0.5) * 0.3
				q.y += (p.noise(q.x * 0.8, q.y * 0.8 + 57) - 0.5) * 0.3
				append(raw, q)
			}
		}
		leg(&raw, a.pt, cw)
		leg(&raw, cw, b.pt)
		append(&raw, b.pt)
		sm := p.smooth(raw[:], 1)

		z := isl.cum[k]
		dots := make([dynamic]Vec2, context.temp_allocator)
		carry := f32(0)
		GAP :: f32(6.5)
		for i in 0 ..< len(sm) - 1 {
			s0 := to_screen({sm[i].x + isl.base.x, sm[i].y + isl.base.y, z + isl.base.z})
			s1 := to_screen({sm[i + 1].x + isl.base.x, sm[i + 1].y + isl.base.y, z + isl.base.z})
			seg := linalg.distance(s0, s1)
			t := carry
			for t < seg {
				append(&dots, s0 + (s1 - s0) * (t / seg))
				t += GAP
			}
			carry = t - seg
		}
		lo := isl.base + Vec3{min(a.pt.x, b.pt.x) - 0.5, min(a.pt.y, b.pt.y) - 0.5, z + 0.02}
		hi := isl.base + Vec3{max(a.pt.x, b.pt.x) + 0.5, max(a.pt.y, b.pt.y) + 0.5, z + 0.04}
		append(ents, path_entity(dots[:], lo, hi))
	}
}

draw :: proc() {
	win = {p.canvas.width, p.canvas.height}
	origin = {win.x / 2, win.y * 0.52}

	ents := make([dynamic]Entity, context.temp_allocator)

	// main island
	main_isl := &islands[0]
	main_isl^ = {}
	gen_island(main_isl, {0, 0, 0}, 5.6, 4, 3)
	for k in 0 ..< main_isl.L {
		if e, ok := level_entity(main_isl, k, false); ok {
			append(&ents, e)
		}
	}
	for u in 0 ..< main_isl.U {
		if e, ok := level_entity(main_isl, u, true); ok {
			append(&ents, e)
		}
	}
	decorate_island(main_isl, &ents, 4, 2, 3, 2, 3)

	// satellite islet, bridged back to the main mass at a matching terrace
	side := rand.float32() < 0.5 ? f32(1) : f32(-1)
	kb := 1
	ex := [2]int{-99, 0}
	best := min(f32)
	for c in main_isl.walk[kb] {
		v := side * f32(c.x - c.y)
		if v > best {
			best = v
			ex = c
		}
	}
	if ex.x != -99 {
		sat := &islands[1]
		sat^ = {}
		g := 3.0 + rand.float32() * 0.6
		zoff_guess := main_isl.cum[kb]
		sbase := Vec3{f32(ex.x) + side * g, f32(ex.y) - side * g, 0}
		gen_island(sat, sbase, 2.0, 2, 2)
		sat.base.z = zoff_guess - sat.cum[sat.L - 1]
		for k in 0 ..< sat.L {
			if e, ok := level_entity(sat, k, false); ok {
				append(&ents, e)
			}
		}
		for u in 0 ..< sat.U {
			if e, ok := level_entity(sat, u, true); ok {
				append(&ents, e)
			}
		}
		decorate_island(sat, &ents, 1, 1, 1, 1, 1)

		// bridge from the main edge cell to the nearest satellite top cell
		if len(sat.walk[sat.L - 1]) > 0 {
			a := Vec3{f32(ex.x) + 0.5, f32(ex.y) + 0.5, main_isl.cum[kb]}
			bc := sat.walk[sat.L - 1][0]
			bd := max(f32)
			for c in sat.walk[sat.L - 1] {
				w := sat.base + Vec3{f32(c.x) + 0.5, f32(c.y) + 0.5, 0}
				dist := linalg.distance(Vec2{w.x, w.y}, Vec2{a.x, a.y})
				if dist < bd {
					bd = dist
					bc = c
				}
			}
			b := sat.base + Vec3{f32(bc.x) + 0.5, f32(bc.y) + 0.5, sat.cum[sat.L - 1] - sat.base.z + sat.base.z}
			b.z = main_isl.cum[kb]
			dirv := linalg.normalize0(Vec3{b.x - a.x, b.y - a.y, 0})
			append(&ents, bridge_entity(a + dirv * 0.4, b - dirv * 0.4, 0.5))
			append(&main_isl.poi[kb], Poi{{a.x, a.y}, ex})

			// a stair descending off the satellite into nothing
			fc := sat.walk[sat.L - 1][0]
			bfront := min(f32)
			for c in sat.walk[sat.L - 1] {
				if f32(c.x + c.y) > bfront {
					bfront = f32(c.x + c.y)
					fc = c
				}
			}
			sdz := f32(1.5)
			spos := sat.base + Vec3{f32(fc.x + 1), f32(fc.y), sat.cum[sat.L - 1] - sdz}
			append(&ents, stair_entity(spos, 0, sdz, 6))
		}
	}

	// a tiny drifting islet with a single dome, opposite side, lower
	if rand.float32() < 0.65 {
		tiny := &islands[2]
		tiny^ = {}
		g2 := 4.0 + rand.float32() * 0.8
		tbase := Vec3{-side * g2, side * g2, -1.5 - rand.float32() * 1.5}
		gen_island(tiny, tbase, 1.3, 1, 1)
		for k in 0 ..< tiny.L {
			if e, ok := level_entity(tiny, k, false); ok {
				append(&ents, e)
			}
		}
		for u in 0 ..< tiny.U {
			if e, ok := level_entity(tiny, u, true); ok {
				append(&ents, e)
			}
		}
		if len(tiny.walk[0]) > 0 {
			c := rand.choice(tiny.walk[0][:])
			b := Building{
				pos = tiny.base + Vec3{f32(c.x) + 0.1, f32(c.y) + 0.1, tiny.cum[0]},
				size = {0.8, 0.8, 0.9},
				roof = .Dome,
				door = true,
				windows = false,
			}
			append(&ents, building_entity(&b))
		}
	}

	make_paths(main_isl, &ents)

	// one small cloud in front of everything, cutting into the city
	if rand.float32() < 0.7 {
		set_style(.Ink)
		p.stroke_weight(1.1)
		cx := origin.x - side * win.x * 0.3
		cy := origin.y - main_isl.cum[1] * SCALE - rand.float32() * 60
		lens_cloud({cx, cy}, 45 + rand.float32() * 20, 14, 4.2)
	}

	// solids, front to back
	order := order_entities(ents[:])
	for i in order {
		draw_entity(&ents[i])
	}

	// sky, clipped behind everything already drawn
	set_style(.Ink)
	p.stroke_weight(1.1)
	for i in 0 ..< 3 {
		cx := origin.x + (f32(i) - 1) * win.x * 0.31 + (p.noise(f32(i) * 7.7 + 2, 0.5) - 0.5) * 90
		cy := origin.y - (0.5 + p.noise(f32(i) * 3.3, 9.1) * 6.0) * SCALE
		lens_cloud({cx, cy}, 55 + p.noise(f32(i) * 5.1, 3.3) * 45, 11 + f32(i) * 2.5, f32(i) * 3.7)
	}
	set_style(.Ink)
	p.stroke_weight(1.0)
	for i in 0 ..< 5 {
		bx := origin.x + (p.noise(f32(i) * 11.3, 60) - 0.5) * win.x * 0.8
		by := win.y * 0.12 + p.noise(f32(i) * 4.9, 70) * win.y * 0.22
		bird({bx, by}, 9 + p.noise(f32(i) * 2.1, 80) * 5)
	}

	set_style(.Accent)
	p.stroke_weight(1.1)
	moon := Vec2{origin.x + side * win.x * 0.27, win.y * 0.14}
	p.circle(moon, 34)
	p.arc(moon.x - 8, moon.y - 6, 25, 1.1, 2.6)
	p.circle(moon.x + 9, moon.y + 10, 4)
	p.circle(moon.x - 4, moon.y + 16, 2.5)

	// the orbit: a great ring the city hangs from, mostly hidden behind it
	ring_c := Vec2{origin.x, origin.y - SCALE}
	p.circle(ring_c, min(win.x, win.y) / 2 - 26)
	p.arc(ring_c.x, ring_c.y, min(win.x, win.y) / 2 - 34, 5.7, 6.9)
}

main :: proc() {
	if len(os.args) > 1 { // headless SVG export: sketch svg <seed>
		seed := u64(12345)
		if len(os.args) > 2 {
			if v, ok := strconv.parse_u64(os.args[2]); ok {
				seed = v
			}
		}
		p.canvas.width = 780
		p.canvas.height = 940
		p.canvas.seed = seed
		p.canvas_reset()
		rand.reset(seed)
		draw()
		p.export_svg()
		return
	}
	p.run(780, 940, "cityscape", draw, loop = false)
}
