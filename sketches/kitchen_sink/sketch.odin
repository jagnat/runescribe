package sketch

import p "../../plot"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:strconv"

PANEL :: f32(300)

Contour_Field :: enum {
	Fbm,
	Rings,
	Warp,
}

contour_kind: Contour_Field
noise_z: f32
panel_origin: p.Vec2
wheel_r: f32 = 25
spin: f32
stamps: [32]p.Vec2
stamp_count: int

Panel :: struct {
	name: string,
	body: proc(),
}

panels := [12]Panel{
	{"primitives", primitives_panel},
	{"transforms", transforms_panel},
	{"text + math", text_panel},
	{"noise", noise_panel},
	{"contours", contour_panel},
	{"flow", flow_panel},
	{"poisson + grid", poisson_panel},
	{"clip + occlude", clip_panel},
	{"groups", group_panel},
	{"paths", path_panel},
	{"weave", weave_panel},
	{"input", input_panel},
}

main :: proc() {
	if len(os.args) > 1 && os.args[1] == "svg" {
		seed := u64(12345)
		if len(os.args) > 2 {
			if v, ok := strconv.parse_u64(os.args[2]); ok {
				seed = v
			}
		}
		p.canvas.width = 4 * PANEL
		p.canvas.height = 3 * PANEL
		p.canvas.seed = seed
		p.canvas_reset()
		rand.reset(seed)
		draw()
		p.export_svg()
		return
	}
	p.run(int(4 * PANEL), int(3 * PANEL), "kitchen sink", draw)
}

draw :: proc() {
	labels := p.toggle("labels", true)
	for panel, i in panels {
		p.push_matrix()
		panel_origin = {f32(i % 4) * PANEL, f32(i / 4) * PANEL}
		p.translate(panel_origin.x, panel_origin.y)
		p.stroke(210)
		p.stroke_weight(1)
		p.rect(6, 6, PANEL - 12, PANEL - 12)
		p.stroke(p.BLACK)
		p.stroke_weight(1.5)
		if labels {
			p.text(panel.name, 14, 26, 12)
		}
		panel.body()
		p.pop_matrix()
	}
}

primitives_panel :: proc() {
	p.rect(18, 42, 60, 46)
	p.stroke(p.RED)
	p.circle(122, 65, 25)
	p.stroke(p.BLUE)
	p.ellipse(200, 65, 36, 20)
	p.stroke(p.BLACK)
	p.arc(263, 65, 24, 0, math.TAU * 0.75)

	p.stroke_weight(3)
	p.line(20, 120, 90, 185)
	p.stroke_weight(1.5)
	p.stroke(120)
	p.dotted_line(45, 120, 115, 185, 6)
	p.stroke(p.BLACK)
	it := p.make_line_iterator({140, 120}, {210, 185}, 9)
	for _, pt in p.iterate_line(&it) {
		p.point(pt)
	}
	p.stroke(90, 40, 160)
	p.begin_shape()
	for i in 0 ..< 10 {
		a := f32(i) / 10 * math.TAU - math.TAU / 4
		r: f32 = i % 2 == 0 ? 34 : 14
		p.vertex(255 + r * math.cos(a), 152 + r * math.sin(a))
	}
	p.end_shape(close = true)

	p.stroke(p.ORANGE)
	p.stroke_weight(2.5)
	p.bezier(20, 270, 90, 205, 170, 330, 275, 240)
	p.stroke(p.BLUE)
	p.stroke_weight(1)
	bit := p.make_bezier_iterator({20, 270}, {90, 205}, {170, 330}, {275, 240}, 8)
	for _, pt in p.iterate_bezier(&bit) {
		p.circle(pt, 4)
	}
}

transforms_panel :: proc() {
	p.push_matrix()
	p.translate(30, 46)
	p.shear(0.45, 0)
	p.rect(0, 0, 64, 40)
	p.pop_matrix()

	p.push_matrix()
	p.translate(210, 40)
	p.shear(0, 0.3)
	p.rect(0, 0, 64, 40)
	p.pop_matrix()

	steps := p.param_int("spiral steps", 22, 4, 40)
	p.stroke(p.BROWN)
	p.stroke_weight(1)
	p.push_matrix()
	p.translate(150, 185)
	for _ in 0 ..< steps {
		p.rect(-72, -72, 144, 144)
		p.rotate(0.16)
		p.scale(0.9)
	}
	p.pop_matrix()
}

text_panel :: proc() {
	p.text("single line font", 20, 56, 18)
	w := p.text_width("single line font", 18)
	p.line(20, 62, 20 + w, 62)
	p.stroke(100)
	p.text("the quick brown fox\njumps over 0123456789", 20, 90, 11)
	p.stroke(p.BLACK)

	p.math_text("E = mc^2", 20, 152, 22)
	mw := p.math_text_width("E = mc^2", 22)
	p.stroke(p.RED)
	p.stroke_weight(1)
	p.rect(14, 129, mw + 12, 32)
	p.stroke(p.BLACK)
	p.stroke_weight(1.5)
	p.math_text("e^{i\\pi} + 1 = 0", 175, 152, 15)
	p.math_text("\\sum_{i=1}^{n} i^3 = {n^2 (n+1)^2} / 4", 20, 210, 15)
	p.math_text("\\alpha\\beta\\gamma\\delta\\epsilon\\zeta\\eta\\theta\\lambda\\mu\\pi\\rho\\sigma\\phi\\psi\\omega", 20, 248, 13)
	p.math_text("\\Gamma\\Delta\\Theta\\Sigma\\Omega \\partial \\infty \\pm \\times \\cdot \\approx \\neq \\leq \\geq \\to", 20, 276, 13)
}

noise_row :: proc(y0: f32, label: string, f: proc(x: f32) -> f32) {
	p.stroke(120)
	p.text(label, 16, y0 + 4, 10)
	p.stroke(p.BLACK)
	pts := make([dynamic]p.Vec2, context.temp_allocator)
	for i in 0 ..= 200 {
		x := f32(i) / 200
		append(&pts, p.Vec2{70 + x * 215, y0 - (f(x) - 0.5) * 40})
	}
	p.polyline(pts[:])
}

ns_noise :: proc(x: f32) -> f32 {
	return p.noise(x * 6)
}

ns_noise3 :: proc(x: f32) -> f32 {
	return p.noise(x * 4, 2.7, noise_z)
}

ns_fbm :: proc(x: f32) -> f32 {
	return p.fbm(x * 4, 1.3)
}

ns_vfbm :: proc(x: f32) -> f32 {
	return p.vfbm({x * 4, 2}) * 0.5 + 0.5
}

ns_warp :: proc(x: f32) -> f32 {
	f, _, _ := p.warp({x * 2, 1.5})
	return f
}

noise_panel :: proc() {
	noise_z = p.param("noise z", 2, 0, 8)
	noise_row(60, "noise", ns_noise)
	noise_row(112, "noise3d", ns_noise3)
	noise_row(164, "fbm", ns_fbm)
	noise_row(216, "vfbm", ns_vfbm)
	noise_row(268, "warp", ns_warp)
}

contour_field :: proc(q: p.Vec2) -> f32 {
	switch contour_kind {
	case .Fbm:
		return p.fbm(q.x * 0.012, q.y * 0.012)
	case .Rings:
		return 0.5 + 0.5 * math.sin(linalg.distance(q, p.Vec2{150, 165}) * 0.055)
	case .Warp:
		f, _, _ := p.warp(q * 0.008)
		return f
	}
	return 0
}

contour_panel :: proc() {
	contour_kind = p.param_enum("contour field", Contour_Field.Fbm)
	isos := p.param_int("contour isos", 6, 1, 12)
	for i in 0 ..< isos {
		iso := 0.28 + 0.44 * f32(i) / f32(max(isos - 1, 1))
		p.stroke(i % 2 == 0 ? p.BLACK : p.GREEN)
		for loop in p.contours(contour_field, iso, {20, 40}, {PANEL - 20, PANEL - 20}, 5) {
			p.polyline(loop)
		}
	}
}

flow_field :: proc(q: p.Vec2) -> p.Vec2 {
	a := p.fbm(q.x * 0.006, q.y * 0.006) * math.TAU * 2.5
	return {math.cos(a), math.sin(a)}
}

flow_panel :: proc() {
	spacing := p.param("flow spacing", 9, 4, 24)
	p.stroke(p.BLUE)
	p.stroke_weight(1.2)
	for sl in p.streamlines(flow_field, {20, 40}, {PANEL - 20, PANEL - 20}, spacing) {
		p.polyline(p.smooth(sl, 2))
	}
}

poisson_panel :: proc() {
	hexa: [6]p.Vec2
	for i in 0 ..< 6 {
		a := f32(i) / 6 * math.TAU + math.TAU / 12
		hexa[i] = p.Vec2{150, 165} + 118 * p.Vec2{math.cos(a), math.sin(a)}
	}
	p.polyline(hexa[:], closed = true)

	r := p.param("poisson r", 13, 6, 30)
	g := p.grid_make(r * 1.5)
	near := make([dynamic]int, context.temp_allocator)
	for pt in p.poisson_disk({30, 45}, {270, 285}, r) {
		if !p.point_in_polygon(pt, hexa[:]) {
			continue
		}
		clear(&near)
		p.grid_query(&g, pt, r * 1.5, &near)
		p.stroke(160)
		p.stroke_weight(0.8)
		for idx in near {
			p.line(pt, g.points[idx])
		}
		p.grid_insert(&g, pt)
		p.stroke(p.MAGENTA)
		p.stroke_weight(1.5)
		p.circle(pt, 1.5 + 3 * p.noise(pt * 0.02))
	}
}

clip_panel :: proc() {
	p.push_clip_circle(82, 112, 52)
	p.stroke(p.ORANGE)
	for x := f32(0); x < 150; x += 6 {
		p.line(x, 50, x + 40, 175)
	}
	p.pop_clip()
	p.stroke(p.BLACK)
	p.circle(82, 112, 52)

	for i in 0 ..< 4 {
		c := p.Vec2{245, 70} + f32(i) * p.Vec2{-25, 28}
		p.circle(c, 30)
		p.line(c - {30, 0}, c + {30, 0})
		p.push_clip_circle(c, 30, invert = true)
	}
	for _ in 0 ..< 4 {
		p.pop_clip()
	}

	p.push_clip_rect(90, 210, 120, 60, invert = true)
	p.stroke(p.GREEN)
	p.stroke_weight(1)
	p.hatch_rect(30, 195, 240, 90, 5, 0.5)
	p.pop_clip()
	p.stroke(p.BLACK)
	p.stroke_weight(1.5)
	p.rect(90, 210, 120, 60)
}

Card :: struct {
	g: ^p.Group,
	depth: f32,
}

group_panel :: proc() {
	n := p.param_int("cards", 6, 2, 10)
	cards := make([dynamic]Card, context.temp_allocator)
	for _ in 0 ..< n {
		pos := p.Vec2{70 + rand.float32() * 160, 80 + rand.float32() * 140}
		w := 50 + rand.float32() * 40
		h := 34 + rand.float32() * 26
		p.begin_group()
		p.push_matrix()
		p.translate(pos.x, pos.y)
		p.rotate((rand.float32() - 0.5) * 1.2)
		corners := [4]p.Vec2{{-w / 2, -h / 2}, {w / 2, -h / 2}, {w / 2, h / 2}, {-w / 2, h / 2}}
		p.rect(-w / 2, -h / 2, w, h)
		p.stroke(p.BROWN)
		p.stroke_weight(1)
		p.hatch_rect(-w / 2, -h / 2, w, h, 6, rand.float32() * math.PI)
		p.stroke(p.BLACK)
		p.stroke_weight(1.5)
		p.push_occlude(corners[:])
		p.pop_matrix()
		append(&cards, Card{p.end_group(), rand.float32()})
	}
	slice.sort_by(cards[:], proc(a, b: Card) -> bool {
		return a.depth < b.depth
	})
	nclips := len(p.canvas.clips)
	for c in cards {
		p.draw_group(c.g)
	}
	for len(p.canvas.clips) > nclips {
		p.pop_clip()
	}
}

path_panel :: proc() {
	raw := make([dynamic]p.Vec2, context.temp_allocator)
	for i in 0 ..= 90 {
		t := f32(i) / 90
		append(&raw, p.Vec2{20 + t * 260, 80 + p.vfbm({t * 5, 4.2}, 3) * 46})
	}
	p.stroke(190)
	p.stroke_weight(2.5)
	p.polyline(raw[:])
	simp := p.simplify(raw[:], 3)
	p.stroke(p.BLACK)
	p.stroke_weight(1)
	p.polyline(simp)
	total := p.path_length(raw[:])
	for d := f32(0); d <= total; d += 24 {
		pt, tan := p.path_point(raw[:], d)
		nrm := p.perp(tan) * 7
		p.line(pt - nrm, pt + nrm)
	}
	p.stroke(p.RED)
	p.stroke_weight(2.5)
	p.polyline(p.subpath(raw[:], total * 0.4, total * 0.6))
	p.stroke(p.BLUE)
	p.stroke_weight(1.5)
	for pt in p.resample(raw[:], 20) {
		p.circle(pt, 2.5)
	}
	p.stroke(p.BLACK)
	p.text(fmt.tprintf("len %d, simplify %d -> %d pts", int(total), len(raw), len(simp)), 20, 150, 10)

	spine := make([dynamic]p.Vec2, context.temp_allocator)
	for i in 0 ..= 60 {
		t := f32(i) / 60
		append(&spine, p.Vec2{30 + t * 240, 220 + 30 * math.sin(t * math.TAU * 1.25)})
	}
	p.polyline(spine[:])
	widths := make([]f32, len(spine), context.temp_allocator)
	for &w, i in widths {
		w = 14 * math.sin(f32(i) / f32(len(widths) - 1) * math.PI)
	}
	p.stroke(p.PURPLE)
	p.polyline(p.offset(spine[:], widths))
	for &w in widths {
		w = -w
	}
	p.polyline(p.offset(spine[:], widths))
	p.stroke(p.GREEN)
	p.dashed(p.offset(spine[:], 24), 10, 5)
	p.stroke(p.BLACK)
	p.dotted(p.offset(spine[:], -24), 6)
}

weave_panel :: proc() {
	center := p.Vec2{150, 168}
	knot := make([dynamic]p.Vec2, context.temp_allocator)
	for i in 0 ..= 240 {
		t := f32(i) / 240 * math.TAU
		r := 58 + 42 * math.cos(3 * t)
		append(&knot, center + p.Vec2{r * math.cos(2 * t), r * math.sin(2 * t)})
	}
	ring := make([dynamic]p.Vec2, context.temp_allocator)
	for i in 0 ..= 90 {
		t := f32(i) / 90 * math.TAU
		append(&ring, center + p.Vec2{52 * math.cos(t), 52 * math.sin(t)})
	}
	strands := [2][]p.Vec2{knot[:], ring[:]}
	gap := p.param("weave gap", 7, 2, 16)
	p.stroke_weight(1.8)
	for piece in p.weave(strands[:], gap) {
		p.polyline(piece)
	}
	p.stroke(p.RED)
	p.stroke_weight(1.2)
	ys := [2]f32{120, 216}
	for y in ys {
		under := [2]p.Vec2{{22, y}, {278, y}}
		for piece in p.gapped(under[:], strands[:], gap) {
			p.polyline(piece)
		}
	}
}

input_panel :: proc() {
	p.text("click stamps, C clears, scroll, hold space", 14, 288, 9)
	wheel_r = clamp(wheel_r + p.wheel() * 3, 6, 70)
	if p.key_down(.SPACE) {
		spin += 0.1
	}
	if p.key_pressed(.C) {
		stamp_count = 0
	}
	m := p.mouse() - panel_origin
	if p.mouse_pressed() && m.x >= 8 && m.x < PANEL - 8 && m.y >= 34 && m.y < PANEL - 26 {
		stamps[stamp_count % len(stamps)] = m
		stamp_count += 1
	}
	p.push_clip_rect(8, 34, PANEL - 16, PANEL - 60)
	p.stroke(p.GREEN)
	for s in stamps[:min(stamp_count, len(stamps))] {
		p.circle(s, 4)
		p.point(s)
	}
	p.stroke(170)
	p.stroke_weight(1)
	p.line(m.x, 0, m.x, PANEL)
	p.line(0, m.y, PANEL, m.y)
	p.stroke(p.BLACK)
	p.stroke_weight(1.5)
	p.circle(m, wheel_r)
	if p.mouse_down() {
		p.stroke(p.ORANGE)
		p.hatch_circle(m, wheel_r, 4)
	}
	p.push_matrix()
	p.translate(150, 165)
	p.rotate(spin)
	p.stroke(p.PURPLE)
	p.rect(-24, -24, 48, 48)
	p.rect(-17, -17, 34, 34)
	p.pop_matrix()
	p.pop_clip()
}
