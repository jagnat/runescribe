#+feature using-stmt
package sketch

import p "../../plot"
import "core:math"
import "core:fmt"
import "core:math/rand"
import "core:math/linalg"

main :: proc() {
	p.run(600, 600, "sketch", draw, loop = false)
}

ogee :: proc() {
	using p;
	x0, y0: f32 = 50, 50 
	x1, y1: f32 = 550, 550

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

	line(x0, y1, x0, ya0)
	line(x1, y1, x1, ya0)

	bezier(x0, ya0, x0, ya0 - control_dist,
		xa0 - comp1_x, ya1 + comp1_y, xa0, ya1)
	bezier(xa0, ya1, xa0 + comp1_x, ya1 - comp1_y,
		xc, y0 + control_dist, xc, y0)
	bezier(x1, ya0, x1, ya0 - control_dist,
		xa1 + comp1_x, ya1 + comp1_y, xa1, ya1)
	bezier(xa1, ya1, xa1 - comp1_x, ya1 - comp1_y,
		xc, y0 + control_dist, xc, y0)
}

draw :: proc() {
	using p;
	ogee()
}

