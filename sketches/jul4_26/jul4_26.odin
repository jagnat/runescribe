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

draw :: proc() {
	// w: f32 = p.canvas.width - 20
	// h: f32 = 200
	// w2 := w / 2
	// h2 := h / 2
	// r := (h2 * h2 + w2 * w2) / h

	// p.circle(p.canvas.width / 2, (p.canvas.height / 2) - r + h2, r)
	// p.circle(p.canvas.width / 2, (p.canvas.height / 2) + r - h2, r)

	// for i in 0..<40 {
	// 	p.circle(280, 300, f32(i * 6))
	// }
	// p.hatch_circle(280, 300, 195, 30, 4 * math.PI / 3)

	// p.pen(2)
	// for i in 0..<40 {
	// 	p.circle(320, 300, f32(i * 6))
	// }
	// p.hatch_circle(320, 300, 195, 30, 2 * math.PI / 3)

	// p.pen(3)
	// p.hatch_circle(300, 320, 195, 10)

	BOUNDS :: 100
	OFFS :: 30

	interval := (p.canvas.width - 2 * OFFS) / BOUNDS
	phase := rand.float32_range(0, 2 * math.PI)
	center :p.Vec2= {p.canvas.width / 2, p.canvas.height / 2}

	for i in 0..<BOUNDS {
		for j in 0..<BOUNDS {
			px := interval * f32(i) + interval / 2 + OFFS
			py := interval * f32(j) + interval / 2 + OFFS
			n := p.fbm(px / 400, py / 800, octaves = 4) * 2 * math.PI + phase

			p1 := p.Vec2{px, py}
			if linalg.distance(p1, center) > (p.canvas.width - 2 * OFFS) / 2 do continue
			p2 := p1 + {math.cos(n) * 10, math.sin(n) * 10}
			if rand.float32() < 0.05 do p.stroke(p.BLUE)
			else if rand.float32() < 0.1 do p.stroke(p.RED)
			else do p.stroke(p.BLACK)
			p.line(p1, p2)

			// p.circle(px, py, n * 20 +5)
		}
	}
}
