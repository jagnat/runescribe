package sketch

import p "../../plot"
import "core:math"
import "core:math/rand"
import "core:os"
import "core:strconv"

PANEL :: f32(300)

// Six panels, one per new plot/ tool: marching-squares contours, poisson-disk
// stipples, evenly spaced streamlines, offset curves around a spine, dashes
// and dots along a curve, and a woven knot with crossing gaps.
// `toolkit_demo svg <seed>` exports headless

PanelProc :: #type proc()

main :: proc() {
	if len(os.args) > 1 { // headless SVG export: toolkit_demo svg <seed>
		seed := u64(12345)
		if len(os.args) > 2 {
			if v, ok := strconv.parse_u64(os.args[2]); ok {
				seed = v
			}
		}
		p.canvas.width = 3 * PANEL
		p.canvas.height = 2 * PANEL
		p.canvas.seed = seed
		p.canvas_reset()
		rand.reset(seed)
		draw()
		p.export_svg()
		return
	}
	p.run(int(3 * PANEL), int(2 * PANEL), "toolkit demo", draw, loop = false)
}

draw :: proc() {
	panels := [6]PanelProc{contour_panel, poisson_panel, flow_panel, offset_panel, dash_panel, weave_panel}
	for panel, i in panels {
		p.push_matrix()
		p.translate(f32(i % 3) * PANEL, f32(i / 3) * PANEL)
		p.stroke(p.BLACK)
		p.stroke_weight(1.5)
		panel()
		p.pop_matrix()
	}
}

contour_panel :: proc() {
	field :: proc(q: p.Vec2) -> f32 {
		return p.fbm(q.x * 0.012, q.y * 0.012)
	}
	isos := p.param_int("contour isos", 5, 1, 12)
	for i in 0 ..< isos {
		iso := 0.3 + 0.4 * f32(i) / f32(max(isos - 1, 1))
		for loop in p.contours(field, iso, {20, 20}, {PANEL - 20, PANEL - 20}, 6) {
			p.polyline(loop)
		}
	}
}

poisson_panel :: proc() {
	r := p.param("poisson r", 9, 4, 30)
	for pt in p.poisson_disk({20, 20}, {PANEL - 20, PANEL - 20}, r) {
		p.circle_v(pt, 1 + 2 * p.noise_v(pt * 0.02))
	}
}

flow_panel :: proc() {
	field :: proc(q: p.Vec2) -> p.Vec2 {
		a := p.noise(q.x * 0.008, q.y * 0.008) * math.TAU * 2
		return {math.cos(a), math.sin(a)}
	}
	spacing := p.param("flow spacing", 8, 3, 24)
	for line in p.streamlines(field, {20, 20}, {PANEL - 20, PANEL - 20}, spacing) {
		p.polyline(p.smooth(line, 1))
	}
}

offset_panel :: proc() {
	spine := make([dynamic]p.Vec2, context.temp_allocator)
	for i in 0 ..= 40 {
		t := f32(i) / 40
		x := 30 + t * (PANEL - 60)
		y := PANEL / 2 + 60 * math.sin(t * math.TAU * 1.5) * (1 - t * 0.5)
		append(&spine, p.Vec2{x, y})
	}
	p.polyline(spine[:])
	widths := make([]f32, len(spine), context.temp_allocator)
	rings := p.param_int("offset rings", 4, 1, 8)
	for k in 1 ..= rings {
		for &w, i in widths { // taper: swell in the middle, points at the ends
			t := f32(i) / f32(len(widths) - 1)
			w = f32(k) * 9 * math.sin(t * math.PI)
		}
		p.polyline(p.offset(spine[:], widths))
		for &w in widths {
			w = -w
		}
		p.polyline(p.offset(spine[:], widths))
	}
}

dash_panel :: proc() {
	center := p.Vec2{PANEL / 2, PANEL / 2}
	turns := f32(4)
	curve := make([dynamic]p.Vec2, context.temp_allocator)
	for i in 0 ..= 400 {
		t := f32(i) / 400
		a := t * turns * math.TAU
		r := 15 + t * 115
		append(&curve, center + p.Vec2{r * math.cos(a), r * math.sin(a)})
	}
	p.dashed(curve[:], p.param("dash", 12, 2, 40), 6)
	p.dotted(p.offset(curve[:], -8), 5)
}

weave_panel :: proc() {
	center := p.Vec2{PANEL / 2, PANEL / 2}
	strands := make([dynamic][]p.Vec2, context.temp_allocator)
	// a trefoil-ish self-crossing loop plus a circle woven through it
	knot := make([dynamic]p.Vec2, context.temp_allocator)
	for i in 0 ..= 240 {
		t := f32(i) / 240 * math.TAU
		r := 60 + 45 * math.cos(3 * t)
		append(&knot, center + p.Vec2{r * math.cos(2 * t), r * math.sin(2 * t)})
	}
	ring := make([dynamic]p.Vec2, context.temp_allocator)
	for i in 0 ..= 90 {
		t := f32(i) / 90 * math.TAU
		append(&ring, center + p.Vec2{55 * math.cos(t), 55 * math.sin(t)})
	}
	append(&strands, knot[:], ring[:])
	for piece in p.weave(strands[:], p.param("weave gap", 8, 2, 20)) {
		p.polyline(piece)
	}
}
