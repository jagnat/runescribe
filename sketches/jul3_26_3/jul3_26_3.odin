package j3263

import "../../plot"
import "core:math"

main :: proc() {
	plot.run(600, 600, "jul 3, 2026 - pt 3", draw)
}

ang : f32= 0

draw :: proc(c: ^plot.Canvas) {
	plot.circle(c, c.width / 2, c.height / 2, 200)
	plot.hatch(c, {{100,100},{100,500},{500,100}}, 5, ang)
	plot.hatch(c, {{100,100},{100,500},{500,100}}, 20, ang + math.PI / 2)
	ang += 0.0001
}
