package j3263

import p "../../plot"
import "core:math"
import "core:fmt"

main :: proc() {
	p.run(600, 600, "jul 3, 2026 - pt 3", draw, loop = false)
}

ang : f32= 0
phase : f32 = 0
bezier_ctrl: f32 = 100

old_thing :: proc(c: ^p.Canvas) {
	THING :: 100
	y0 :f32= -THING
	y1 :f32= c.height + THING
	r :f32= (y1 - y0 + THING) / 2
	yd := math.abs(y1 - y0) / 2
	theta := math.acos(f32(yd) / f32(r))
	pi :: math.PI

	fmt.println("yd:", yd, "theta:", (theta / pi) * 180, "r:", r)

	p.circle(c, c.width / 2, y0, r)
	p.circle(c, c.width / 2, y1, r)
	p.point(c, c.width / 2, y0)
	p.point(c, c.width / 2, y1)

	p.pen(c, 2)
	p.stroke_weight(c, 3)
	p.arc(c, c.width / 2, y0, r, pi / 2 - theta, pi / 2 + theta)
	p.arc(c, c.width / 2, y1, r, 3 * pi / 2 - theta, 3 * pi / 2 + theta)
}

draw :: proc(c: ^p.Canvas) {
	// w: f32 = c.width - 20
	// h: f32 = 200
	// w2 := w / 2
	// h2 := h / 2
	// r := (h2 * h2 + w2 * w2) / h

	// p.circle(c, c.width / 2, (c.height / 2) - r + h2, r)
	// p.circle(c, c.width / 2, (c.height / 2) + r - h2, r)

	for i in 0..<40 {
		p.circle(c, 290, 300, f32(i * 5))
	}

	p.pen(c, 2)
	for i in 0..<40 {
		p.circle(c, 310, 300, f32(i * 5))
	}
}
