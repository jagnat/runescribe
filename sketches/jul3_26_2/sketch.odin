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

	shift_factor: p.Vec2,

	banned_positions: [dynamic]Circle
}

w: Walker

possible_angles :[]f32= {500, }

ITERATIONS :: 1

main :: proc() {
	p.run(800, 800, "template", draw, loop = false)
}

draw :: proc() {
	// w.point = {rand.float32() * canvas.width, rand.float32() * canvas.height}
	rand.reset(u64(time.now()._nsec))
	w = {}
	for i in 0..< ITERATIONS {
		setup_walk(&w)
		walk(&w, 0)
	}
}

MIN_ANGLE :: 30
MAX_ANGLE :: 90
angle_quadrants : []int : {0,1,2,3}

setup_walk :: proc(w: ^Walker) {
	// w.point = {rand.float32() * (canvas.width - 200) + 100, rand.float32() * (canvas.height - 200) + 100}
	w.point = {p.canvas.width / 2, p.canvas.height / 2}
	for circle in w.banned_positions {
		collide_dist := linalg.distance([2]f32{circle.x, circle.y}, w.point)
		if collide_dist < circle.r do return
	}
	w.walk_start_point = w.point
	w.n = int(rand.float32() * 4 + 3)
	w.len = rand.float32() * 20 + 400
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
	w.shrink_factor = 0.978
}

walk :: proc(w: ^Walker, depth: int) -> int {
	p2 := w.point + {math.cos(w.current_angle / 180 * math.PI) * w.len, math.sin(w.current_angle / 180 * math.PI)* w.len}
	//if p2.x > canvas.width || p2.y > canvas.height || p2.x < 0 || p2.y < 0 do return depth

	p1 := w.point
	w.len = w.len * w.shrink_factor
	w.current_angle += w.walk_angle
	w.point = p2

	if w.len >= 4 {
		total_depth := walk(w, depth + 1)
		//if total_depth < 5 do return total_depth
		jitter := w.len * 4
		// p1 += {(rand.float32() - 0.5) * JITTER, (rand.float32() - 0.5) * JITTER}
		p2 += {(rand.float32() - 0.5) * jitter, (rand.float32() - 0.5) * jitter}
		// p.line(p1.x, p1.y, p2.x, p2.y)
		p1 -= w.shift_factor
		p2 -= w.shift_factor
		dotted_line(p1, p2, 4, f32(total_depth - depth) / f32(total_depth) * 3)
		return total_depth
	}
	else {
		d := linalg.distance(w.point, w.walk_start_point)
		cir := Circle{w.point.x, w.point.y, d}
		// for other_c in w.banned_positions {
		// 	collide_dist := linalg.distance([2]f32{cir.x, cir.y}, [2]f32{other_c.x, other_c.y})
		// 	if collide_dist < cir.r + other_c.r do return 0
		// }
		cir.r *= 0.8
		w.shift_factor = w.point - {p.canvas.width / 2, p.canvas.height / 2}

		// append(&w.banned_positions, cir)
		// p.circle(cir.x, cir.y, cir.r)
		return depth
	}
}

dotted_line :: proc(p1, p2: p.Vec2, gap: f32, num_jitter: f32) {
	num_jitter := num_jitter
	d := linalg.distance(p1, p2)
	step := int(d / gap)
	for i in 0..<step {
		t := f32(i) / f32(step)
		x := math.lerp(p1.x, p2.x, t)
		y := math.lerp(p1.y, p2.y, t)
		// if num_jitter < 1 do num_jitter = 1
		fmt.println("NJ:", num_jitter)

		for j in 0..<num_jitter {
			fmt.println("J:", j)
			jitter_rad := rand.float32() * f32(num_jitter) * 2
			jitter_ang := rand.float32() * math.PI * 2
			x += math.cos(jitter_ang) * jitter_rad
			y += math.sin(jitter_ang) * jitter_rad
			p.point(x, y)
		}
	}
}