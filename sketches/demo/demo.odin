package demo

import "core:math"
import "core:math/rand"
import "../../plot"

main :: proc() {
	plot.run(800, 800, "demo", draw)
}

draw :: proc(c: ^plot.Canvas) {
	cx := c.width / 2
	cy := c.height / 2

	// Wobbly concentric rings
	for ring in 0 ..< 18 {
		r := 40 + f32(ring) * 13
		phase := rand.float32() * math.TAU
		amp := rand.float32_range(2, 10)
		lobes := f32(rand.int_max(5) + 3)
		steps := 140
		plot.begin_shape(c)
		for i in 0 ..< steps {
			t := f32(i) / f32(steps) * math.TAU
			rr := r + amp * math.sin(lobes * t + phase)
			plot.vertex(c, cx + rr * math.cos(t), cy + rr * math.sin(t))
		}
		plot.end_shape(c, close = true)
	}

	// Ring of tilted squares around the rings
	plot.pen(c, 2)
	count := 36
	for i in 0 ..< count {
		angle := f32(i) / f32(count) * math.TAU
		plot.push_matrix(c)
		plot.translate(c, cx + 330 * math.cos(angle), cy + 330 * math.sin(angle))
		plot.rotate(c, angle + rand.float32_range(-0.3, 0.3))
		size := rand.float32_range(14, 26)
		plot.rect(c, -size / 2, -size / 2, size, size)
		plot.pop_matrix(c)
	}

	// Corner accents
	plot.pen(c, 3)
	for corner_x in ([2]f32{60, c.width - 60}) {
		for corner_y in ([2]f32{60, c.height - 60}) {
			plot.circle(c, corner_x, corner_y, 12)
			plot.point(c, corner_x, corner_y)
		}
	}
}
