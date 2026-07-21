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

draw :: proc() {
	using p;

	r := p.param("radius", 200, 10, 290)
	
	inner_rad :: 100
	outer_rad :: 300

	N :: 12
	rad_per :: math.TAU / f32(N)

	for i in 0..< 12 {
		ang := f32(i) / 12.0 * math.TAU
		ang_prev := wrap_angle(ang - rad_per)
		ang_next := wrap_angle(ang + rad_per)
		line(ang_to_pt(ang_prev, inner_rad), ang_to_pt(ang, outer_rad))
		line(ang_to_pt(ang_next, inner_rad), ang_to_pt(ang, outer_rad))
	}
}

wrap_angle :: proc(t: f32) -> f32 {
	r := math.mod_f32(t, math.TAU)
	if r < 0 do r += math.TAU
	return r
}

ang_to_pt :: proc(ang: f32, rad: f32) -> p.Vec2 {
	return {math.cos(ang) * rad + p.canvas.width / 2, math.sin(ang) * rad + p.canvas.height / 2}
}
