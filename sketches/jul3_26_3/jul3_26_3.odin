package j3263

import p "../../plot"
import "core:math"
import "core:fmt"

main :: proc() {
	p.run(600, 600, "jul 3, 2026 - pt 3", draw)
}

ang : f32= 0
phase : f32 = 0
bezier_ctrl: f32 = 100

draw :: proc() {
	cen := p.Vec2{p.canvas.width / 2, p.canvas.height / 2}
	// p.circle(cen.x, cen.y, 200)
	// points: [40]p.Vec2 = {}
	// p.hatch_circle(cen.x, cen.y, 200, 6, ang)
	// p.hatch_circle(cen.x, cen.y, 200, 6, ang + phase)

	N :: 12
	for i in 0..<N {
		x := math.cos(f32(i) / N * 2 * math.PI) * 300 + p.canvas.width / 2
		y := math.sin(f32(i) / N * 2 * math.PI) * 300 + p.canvas.height / 2
		iter := p.make_line_iterator({p.canvas.width / 2, p.canvas.height / 2},
			{x, y}, 20)
		for t, point in p.iterate_line(&iter) {
			p.circle(point, (1 -t) * 20)
		}
	}
	for i in 0..<N {
		x := math.cos(f32(i) / N * 2 * math.PI) * 300 + p.canvas.width / 2
		y := math.sin(f32(i) / N * 2 * math.PI) * 300 + p.canvas.height / 2
		iter := p.make_line_iterator({p.canvas.width / 2, p.canvas.height / 2},
			{x, y}, 20)
		for t, point in p.iterate_line(&iter) {
			p.circle(point, (1 -t) * 20)
		}
	}

	p.bezier(
		{0, 0},
		{0, 0 + bezier_ctrl},
		{p.canvas.width, p.canvas.height - bezier_ctrl},
		{p.canvas.width, p.canvas.height},)
	bezier_ctrl += 1
	if bezier_ctrl > p.canvas.height * 2 do bezier_ctrl = 100
}
