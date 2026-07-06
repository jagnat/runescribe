package demo

import "core:math"
import "core:math/rand"
import "../../plot"

main :: proc() {
	plot.run(800, 800, "demo", draw)
}

draw :: proc() {
	cx := plot.canvas.width / 2
	cy := plot.canvas.height / 2

	// Wobbly concentric rings
	for ring in 0 ..< 18 {
		r := 40 + f32(ring) * 13
		phase := rand.float32() * math.TAU
		amp := rand.float32_range(2, 10)
		lobes := f32(rand.int_max(5) + 3)
		steps := 140
		plot.begin_shape()
		for i in 0 ..< steps {
			t := f32(i) / f32(steps) * math.TAU
			rr := r + amp * math.sin(lobes * t + phase)
			plot.vertex(cx + rr * math.cos(t), cy + rr * math.sin(t))
		}
		plot.end_shape(close = true)
	}

	// Ring of tilted squares around the rings
	plot.stroke(plot.RED)
	count := 36
	for i in 0 ..< count {
		angle := f32(i) / f32(count) * math.TAU
		plot.push_matrix()
		plot.translate(cx + 330 * math.cos(angle), cy + 330 * math.sin(angle))
		plot.rotate(angle + rand.float32_range(-0.3, 0.3))
		size := rand.float32_range(14, 26)
		plot.rect(-size / 2, -size / 2, size, size)
		plot.pop_matrix()
	}

	// Corner accents
	plot.stroke(plot.BLUE)
	for corner_x in ([2]f32{60, plot.canvas.width - 60}) {
		for corner_y in ([2]f32{60, plot.canvas.height - 60}) {
			plot.circle(corner_x, corner_y, 12)
			plot.point(corner_x, corner_y)
		}
	}
}
