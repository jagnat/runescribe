package template

import p "../../plot"
import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:math/linalg"
import "core:slice"
import "core:time"

Circle :: struct {
	x, y, r: f32,
}

Walker :: struct {
	point: p.Vec2,
	current_angle: f32,
	len: f32,

	walk_start_point: p.Vec2,

	n: int,
	angles: []f32,
	walk_angle: f32,
	shrink_factor: f32,

	banned_positions: [dynamic]Circle
}

w: Walker

possible_angles :[]f32= {500, }

ITERATIONS :: 10000

main :: proc() {
	p.run(800, 800, "template", draw, loop = false)
}

draw :: proc(c: ^p.Canvas) {
	// w.point = {rand.float32() * c.width, rand.float32() * c.height}
	rand.reset(u64(time.now()._nsec))
	w = {}
	for i in 0..< ITERATIONS {
		setup_walk(c, &w)
		walk(c, &w, 0)
	}
}

MIN_ANGLE :: 45
MAX_ANGLE :: 90
angle_quadrants : []int : {0,1,2,3}

setup_walk :: proc(c: ^p.Canvas, w: ^Walker) {
	w.point = {rand.float32() * (c.width - 200) + 100, rand.float32() * (c.height - 200) + 100}
	for circle in w.banned_positions {
		collide_dist := linalg.distance([2]f32{circle.x, circle.y}, w.point)
		if collide_dist < circle.r do return
	}
	w.walk_start_point = w.point
	w.n = int(rand.float32() * 4 + 3)
	w.len = rand.float32() * 100 + 50
	//w.walk_angle = f32(int(rand.float32() * 6 + 1) * 60)
	// w.walk_angle = rand.choice(possible_angles)
	w.walk_angle = rand.float32() * (MAX_ANGLE - MIN_ANGLE) + MIN_ANGLE
	q := rand.choice(angle_quadrants)
	switch q {
		case 0: break
		case 1: w.walk_angle += MAX_ANGLE - MIN_ANGLE
		case 2: w.walk_angle += 180
		case 3: w.walk_angle += MAX_ANGLE - MIN_ANGLE + 180
	}

	w.current_angle = rand.float32() * 360
	w.shrink_factor = rand.float32() * 0.3 + 0.6
}

walk :: proc(c: ^p.Canvas, w: ^Walker, depth: int) -> int {
	p2 := w.point + {math.cos(w.current_angle / 180 * math.PI) * w.len, math.sin(w.current_angle / 180 * math.PI)* w.len}
	if p2.x > c.width || p2.y > c.height || p2.x < 0 || p2.y < 0 do return depth

	p1 := w.point
	w.len = w.len * w.shrink_factor
	w.current_angle += w.walk_angle
	w.point = p2

	if w.len >= 4 {
		total_depth := walk(c, w, depth + 1)
		if total_depth < 5 do return total_depth
		jitter := w.len * 4
		// p1 += {(rand.float32() - 0.5) * JITTER, (rand.float32() - 0.5) * JITTER}
		p2 += {(rand.float32() - 0.5) * jitter, (rand.float32() - 0.5) * jitter}
		p.line(c, p1.x, p1.y, p2.x, p2.y)
		// dotted_line(c, p1, p2, 4)
		return total_depth
	}
	else {
		d := linalg.distance(w.point, w.walk_start_point)
		cir := Circle{w.point.x, w.point.y, d}
		for other_c in w.banned_positions {
			collide_dist := linalg.distance([2]f32{cir.x, cir.y}, [2]f32{other_c.x, other_c.y})
			if collide_dist < cir.r + other_c.r do return 0
		}
		cir.r *= 0.8
		banned_len := len(w.banned_positions)
		if banned_len > 0 {
			// p.pen(c, 8)
			start := w.walk_start_point
			end := w.banned_positions[banned_len - 1]
			dotted_line(c, start, {end.x, end.y}, 10)
			// p.line(c, start.x, start.y, end.x, end.y)
			// p.pen(c, 0)
		}
		append(&w.banned_positions, cir)
		// p.circle(c, cir.x, cir.y, cir.r)
		return depth
	}
}

dotted_line :: proc(c: ^p.Canvas, p1, p2: p.Vec2, gap: f32, ) {
	d := linalg.distance(p1, p2)
	step := int(d / gap)
	for i in 0..<step {
		t := f32(i) / f32(step)
		x := math.lerp(p1.x, p2.x, t)
		y := math.lerp(p1.y, p2.y, t)
		p.point(c, x, y)
	}
}