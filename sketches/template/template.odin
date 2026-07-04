package template

import "../../plot"

main :: proc() {
	plot.run(800, 800, "template", draw)
}

// Re-records the whole frame each call. Use core:math/rand freely -- the seed
// is reset every frame, so the sketch holds still until you press R.
draw :: proc(c: ^plot.Canvas) {
	plot.circle(c, c.width / 2, c.height / 2, 200)
}
