package j3263

import p "../../plot"
import "core:math"
import "core:fmt"
import "core:math/rand"
import "core:math/linalg"

main :: proc() {
	p.run(600, 600, "jul 3, 2026 - pt 3", draw, loop = false)
}

ang : f32= 0
phase : f32 = 0
bezier_ctrl: f32 = 100

old_thing :: proc() {
	THING :: 100
	y0 :f32= -THING
	y1 :f32= p.canvas.height + THING
	r :f32= (y1 - y0 + THING) / 2
	yd := math.abs(y1 - y0) / 2
	theta := math.acos(f32(yd) / f32(r))
	pi :: math.PI

	fmt.println("yd:", yd, "theta:", (theta / pi) * 180, "r:", r)

	p.circle(p.canvas.width / 2, y0, r)
	p.circle(p.canvas.width / 2, y1, r)
	p.point(p.canvas.width / 2, y0)
	p.point(p.canvas.width / 2, y1)

	p.stroke(p.RED)
	p.stroke_weight(3)
	p.arc(p.canvas.width / 2, y0, r, pi / 2 - theta, pi / 2 + theta)
	p.arc(p.canvas.width / 2, y1, r, 3 * pi / 2 - theta, 3 * pi / 2 + theta)
}

OFFS :: 30
SCALE :: 1.0 / 300

SEP :: 1 // px between neighbouring streamlines
STEP :: 1.5 // px per integration step
MAX_STEPS :: 1200
SEED_STEP :: 4.5
DASH :: 12.0 // px per on/off cycle at half duty
EPS :: 0.75 // px, finite difference for grad f
TWIST :: 0.0 // 0 follows contours, PI/2 runs straight down the gradient
SELF_SKIP :: 6 // steps of its own trail a line may brush past before that counts as overlap
GRAD_MIN :: 1e-5 // below this the contour direction is noise, not structure

// Cell size SEP, holding the last streamline through it; a 3x3 lookup keeps distinct lines apart
Grid :: struct {
	cells: []Cell,
	cols, rows: int,
}

// seq is the marking line's step index, signed by trace direction
Cell :: struct {
	id: i32,
	seq: i32,
}

// A line clears its own trail only near the step it is on, so closed contours stop after one lap
grid_free :: proc(g: ^Grid, pt: p.Vec2, id, seq: i32) -> bool {
	cx := int(pt.x / SEP)
	cy := int(pt.y / SEP)
	for dy in -1..=1 {
		for dx in -1..=1 {
			x := cx + dx
			y := cy + dy
			if x < 0 || y < 0 || x >= g.cols || y >= g.rows do continue
			o := g.cells[y * g.cols + x]
			if o.id == -1 do continue
			if o.id != id do return false
			if abs(seq - o.seq) > SELF_SKIP do return false
		}
	}
	return true
}

grid_mark_cell :: proc(g: ^Grid, pt: p.Vec2, id, seq: i32) {
	cx := clamp(int(pt.x / SEP), 0, g.cols - 1)
	cy := clamp(int(pt.y / SEP), 0, g.rows - 1)
	g.cells[cy * g.cols + cx] = {id, seq}
}

// Walks the segment so a STEP longer than a cell can't leave gaps for other lines to slip through
grid_mark :: proc(g: ^Grid, a, b: p.Vec2, id, seq: i32) {
	n := max(1, int(linalg.distance(a, b) / (SEP * 0.5)))
	for i in 0..=n {
		grid_mark_cell(g, linalg.lerp(a, b, f32(i) / f32(n)), id, seq)
	}
}

Sample :: struct {
	pos: p.Vec2,
	f: f32, // shades the dashes
}

// f shades the dashes; h is the smoother mid-stage field whose contours the lines follow
sample :: proc(q: p.Vec2) -> (f, h: f32) {
	warped, _, n := p.warp(q)
	return warped, linalg.dot(n, n)
}

// Perpendicular to grad h, so a streamline follows a contour of the warped field
field :: proc(pt: p.Vec2, center: p.Vec2) -> (f: f32, dir: p.Vec2) {
	q := (pt - center) * SCALE
	h: f32
	f, h = sample(q)
	_, hx := sample(q + {EPS * SCALE, 0})
	_, hy := sample(q + {0, EPS * SCALE})
	grad := p.Vec2{hx - h, hy - h}
	if linalg.length(grad) < GRAD_MIN do return f, {}
	a := math.atan2(grad.y, grad.x) + math.PI / 2 + TWIST
	return f, {math.cos(a), math.sin(a)}
}

// Walks the field from seed until it leaves the disc, runs out of steps, or meets another streamline
trace :: proc(g: ^Grid, seed: p.Vec2, id: i32, sign: f32, center: p.Vec2, radius: f32) -> []Sample {
	pts := make([dynamic]Sample, 0, MAX_STEPS, context.temp_allocator)
	pt := seed
	for i in 0..<MAX_STEPS {
		seq := i32(i) * i32(sign)
		if linalg.distance(pt, center) > radius do break
		if !grid_free(g, pt, id, seq) do break
		f, dir := field(pt, center)
		if dir == {} do break
		append(&pts, Sample{pt, f})
		next := pt + dir * (STEP * sign)
		grid_mark(g, pt, next, id, seq)
		pt = next
	}
	return pts[:]
}

// Breaks the line into dashes whose length grows with f, so one pen shades the field
dashes :: proc(pts: []Sample) {
	run := make([dynamic]p.Vec2, 0, len(pts), context.temp_allocator)
	s := f32(0)
	for pt, i in pts {
		if i > 0 do s += linalg.distance(pt.pos, pts[i - 1].pos)
		duty := clamp((pt.f - 0.35) / 0.3, 0, 1)
		if duty > 0.5 + 0.5 * math.sin(s * 2 * math.PI / DASH) {
			append(&run, pt.pos)
			continue
		}
		if len(run) > 1 do p.polyline(run[:])
		clear(&run)
	}
	if len(run) > 1 do p.polyline(run[:])
}

draw :: proc() {
	center := p.Vec2{p.canvas.width / 2, p.canvas.height / 2}
	radius := (p.canvas.width - 2 * OFFS) / 2
	p.stroke(p.BLACK)

	g := Grid{
		cols = int(p.canvas.width / SEP) + 1,
		rows = int(p.canvas.height / SEP) + 1,
	}
	g.cells = make([]Cell, g.cols * g.rows, context.temp_allocator)
	for &c in g.cells do c = {-1, 0}

	id := i32(0)
	for y := f32(OFFS); y < p.canvas.height - OFFS; y += SEED_STEP {
		for x := f32(OFFS); x < p.canvas.width - OFFS; x += SEED_STEP {
			seed := p.Vec2{x, y} + {rand.float32_range(-2, 2), rand.float32_range(-2, 2)}
			if linalg.distance(seed, center) > radius do continue
			if !grid_free(&g, seed, -2, 0) do continue // -2 matches no owner

			fwd := trace(&g, seed, id, 1, center, radius)
			bwd := trace(&g, seed, id, -1, center, radius)
			id += 1
			if len(fwd) + len(bwd) < 8 do continue

			pts := make([dynamic]Sample, 0, len(fwd) + len(bwd), context.temp_allocator)
			shared := 1 if len(fwd) > 0 else 0 // both halves record the seed
			if len(bwd) > shared {
				#reverse for pt in bwd[shared:] do append(&pts, pt)
			}
			append(&pts, ..fwd)

			dashes(pts[:])
		}
	}
}
