package sketch

import p "../../plot"
import "core:math"

Vec2 :: p.Vec2
Vec3 :: [3]f32
Vec3i :: [3]int

COS30 :: 0.86602540378
SIN30 :: 0.5
SCALE :: 24 // pixels per unit cell

XY_GRID_SIZE :: 16
Z_GRID_SIZE :: 16
MAX_SUM :: 2 * (XY_GRID_SIZE - 1) + Z_GRID_SIZE - 1

win: Vec2
origin: Vec2
scene: [XY_GRID_SIZE][XY_GRID_SIZE][Z_GRID_SIZE]bool

to_screen :: proc(c: Vec3) -> Vec2 {
	return {origin.x + (c.x - c.y) * COS30 * SCALE,
		origin.y + (c.x + c.y) * SIN30 * SCALE - c.z * SCALE}
}

v3 :: proc(c: Vec3i) -> Vec3 {
	return {f32(c.x), f32(c.y), f32(c.z)}
}

set_filled :: proc { set_filled_1, set_filled_3 }
set_filled_1 :: proc(c: Vec3i, filled: bool = true) {
	set_filled_3(c.x, c.y, c.z, filled)
}
set_filled_3 :: proc(x, y, z: int, filled: bool = true) {
	scene[x][y][z] = filled
}

is_filled :: proc { is_filled_1, is_filled_3 }
is_filled_1 :: proc(c: Vec3i) -> bool {
	return is_filled_3(c.x, c.y, c.z)
}
is_filled_3 :: proc(x, y, z: int) -> bool {
	if x < 0 || x >= XY_GRID_SIZE || y < 0 || y >= XY_GRID_SIZE || z < 0 || z >= Z_GRID_SIZE do return false
	return scene[x][y][z]
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

// A decoration bound to wall cells: painted in each touched cell's depth
// slot, clipped to that cell's face quad
Decal :: struct {
	tile: Vec3i,
	dir: FaceDir,
	lo, hi: Vec2,
	paint: proc(f: Face, lo, hi: Vec2),
}

decals: [dynamic]Decal

ogee :: proc(f: Face, lo, hi: Vec2) {
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

// Along the (1,1,1) view ray the projection is invariant, so x+y+z descending
// is an exact painter's order: a voxel can only occlude strictly smaller sums

// Fully hidden iff a voxel up the view ray projects to the same hexagon
hidden :: proc(c: Vec3i) -> bool {
	for t in 1 ..< max(XY_GRID_SIZE, Z_GRID_SIZE) {
		if is_filled(c + t) do return true
	}
	return false
}

push_hexagon :: proc(c: Vec3i) {
	v := v3(c)
	pts := [6]Vec2{
		to_screen(v + {0, 0, 1}),
		to_screen(v + {1, 0, 1}),
		to_screen(v + {1, 0, 0}),
		to_screen(v + {1, 1, 0}),
		to_screen(v + {0, 1, 0}),
		to_screen(v + {0, 1, 1}),
	}
	p.push_occlude(pts[:])
}

emit_decals :: proc(level: int) {
	for d in decals {
		du := d.dir == .PosX ? Vec3i{0, 1, 0} : Vec3i{1, 0, 0}
		n := d.dir == .PosX ? Vec3i{1, 0, 0} : Vec3i{0, 1, 0}
		for i in int(math.floor(d.lo.x)) ..< int(math.ceil(d.hi.x)) {
			for j in int(math.floor(d.lo.y)) ..< int(math.ceil(d.hi.y)) {
				cell := d.tile + du * i - Vec3i{0, 0, j}
				if cell.x + cell.y + cell.z != level do continue
				if !is_filled(cell) || is_filled(cell + n) do continue
				f := wall_face(cell, d.dir)
				quad := [4]Vec2{face_pt(f, {0, 0}), face_pt(f, {1, 0}), face_pt(f, {1, 1}), face_pt(f, {0, 1})}
				p.push_clip(quad[:])
				d.paint(wall_face(d.tile, d.dir), d.lo, d.hi)
				p.pop_clip()
			}
		}
	}
}

render_voxels :: proc() {
	lines := make([][dynamic][2]Vec2, MAX_SUM + 1, context.temp_allocator)
	cells := make([][dynamic]Vec3i, MAX_SUM + 1, context.temp_allocator)
	for i in 0 ..= MAX_SUM {
		lines[i] = make([dynamic][2]Vec2, context.temp_allocator)
		cells[i] = make([dynamic]Vec3i, context.temp_allocator)
	}

	// Around each lattice edge: D is the viewer-most cell, A the farthest,
	// B/C the sides. Ink iff D empty and the exposed surfaces across the edge
	// differ: a concave crease (B and C) or exactly one of A/B/C (silhouette
	// or convex crease). Flush continuations cancel
	sizes := Vec3i{XY_GRID_SIZE, XY_GRID_SIZE, Z_GRID_SIZE}
	for axis in 0 ..< 3 {
		u, v: Vec3i
		u[(axis + 1) % 3] = 1
		v[(axis + 2) % 3] = 1
		lim := sizes
		lim[axis] -= 1
		for x in 0 ..= lim.x {
			for y in 0 ..= lim.y {
				for z in 0 ..= lim.z {
					q := Vec3i{x, y, z}
					if is_filled(q) do continue
					a := is_filled(q - u - v)
					b := is_filled(q - v)
					c := is_filled(q - u)
					if !((b && c) || int(a) + int(b) + int(c) == 1) do continue
					level := x + y + z - (b || c ? 1 : 2)
					e := q
					e[axis] += 1
					append(&lines[level], [2]Vec2{to_screen(v3(q)), to_screen(v3(e))})
				}
			}
		}
	}

	for x in 0 ..< XY_GRID_SIZE {
		for y in 0 ..< XY_GRID_SIZE {
			for z in 0 ..< Z_GRID_SIZE {
				c := Vec3i{x, y, z}
				if is_filled(c) && !hidden(c) {
					append(&cells[x + y + z], c)
				}
			}
		}
	}

	for s := MAX_SUM; s >= 0; s -= 1 {
		for seg in lines[s] {
			p.line(seg[0], seg[1])
		}
		emit_decals(s)
		for c in cells[s] {
			push_hexagon(c)
		}
	}
}

draw :: proc() {
	win = {p.canvas.width, p.canvas.height}
	origin = {win.x / 2, 3 * win.y / 4}
	scene = {}
	decals = make([dynamic]Decal, context.temp_allocator)
	frame_ogee()

	fill_voxels(0, 0, 0, 5, 1, 4)
	fill_voxels(0, 0, 0, 1, 5, 4)

	//fill_voxels(2, 2, 0, 12, 12, 1) // plaza
	// fill_voxels(7, 4, 0, 9, 6, 1, false) // courtyard hole
	// fill_voxels(2, 2, 1, 6, 6, 2) // terrace, flush with the plaza at x=2 / y=2
	// fill_voxels(9, 9, 1, 11, 11, 6) // tower
	// fill_voxels(12, 4, 0, 13, 8, 3) // wall off the plaza edge
	// fill_voxels(4, 8, 1, 5, 9, 3) // mushroom stem
	// fill_voxels(3, 8, 3, 6, 10, 4) // mushroom cap, overhanging the stem

	append(&decals, Decal{{2, 0, 1}, .PosY, {0.1, -2}, {1.9, 1}, ogee})

	render_voxels()
}

main :: proc() {
	p.canvas.width = 600
	p.canvas.height = 600
	p.canvas_reset()
	draw()
	p.export_svg()
}
