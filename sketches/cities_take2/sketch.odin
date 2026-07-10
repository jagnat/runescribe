#+feature using-stmt
package sketch

import p "../../plot"
import "core:math"
import "core:fmt"
import "core:math/rand"
import "core:math/linalg"

Vec2 :: p.Vec2

win: Vec2

// seeds for the random city generator
// factors that can be changed:
// roofs
// window types, counts
// building cluster sizes
// building layers
// 

RoofType :: enum {
	Flat,
	Shed,
	Gable,
}
RoofTypeSet :: bit_set[RoofType]

gen: Gen

Gen :: struct {
	seed: u64,
	roofs: RoofTypeSet,
	roof_min_h: f32,
}

draw :: proc() {
	win = {p.canvas.width, p.canvas.height}
	using p;

	seed_gen_0()

	frame_ogee()
	generate_building({300, 300})
}

seed_gen_0 :: proc() {
	gen.roofs = {.Flat, }
	gen.roof_min_h = 10
}

init_gen :: proc() {
	gen.seed = p.canvas.seed

	// roof data
	roof_style := rand.int32_range(0, 4)
	gen.roofs = {.Flat}
	switch roof_style {
	case 0: break // flat
	case 1: gen.roofs = {.Shed}
	case 2: gen.roofs = {.Gable}
	case 3: gen.roofs = {.Shed, .Flat}
	}
	gen.roof_min_h = rand.float32_range(5, 40)
}

pick_roof :: proc(s: bit_set[RoofType]) -> (RoofType, bool) {
	n := card(s)
	if n == 0 {
		return {}, false
	}
	k := rand.int_max(n)
	for e in RoofType {
		if e in s {
			if k == 0 {
				return e, true
			}
			k -= 1
		}
	}
	unreachable()
}

generate_building :: proc(center: Vec2) {
	width := rand.float32_range(100, 200)
	height := rand.float32_range(100, 200)

	bounds := Vec2{width, height}
	half_bounds := bounds / 2
	top_l := center - half_bounds
	bot_r := center + half_bounds

	p.line(top_l, {top_l.x, bot_r.y})
	p.line({top_l.x, bot_r.y}, bot_r)
	p.line(bot_r, {bot_r.x, top_l.y})

	roof_type, success := pick_roof(gen.roofs)
	assert(success)

	roof_h := gen.roof_min_h + rand.float32_range(0, 40)
	slope := roof_h / width
	extra_w :f32= 10
	extra_h := slope * extra_w

	switch roof_type {
	case .Flat:
		p.line(top_l - {extra_w, 0}, {bot_r.x, top_l.y} + {extra_w, 0})
	case .Shed:
		left := rand.float32() > 0.5
		if left {
			p.line (top_l, top_l + {0, -roof_h})
			p.line (top_l + {0, -roof_h} - {extra_w, extra_h}, {bot_r.x, top_l.y} + {extra_w, extra_h})
		} else {
			p.line ({bot_r.x, top_l.y}, {bot_r.x, top_l.y} + {0, -roof_h})
			p.line ({bot_r.x, top_l.y} + {0, -roof_h} + {extra_w, -extra_h}, top_l - {extra_w, -extra_h})
		}
	case .Gable:
	}
}

FRAME_BEZIER_STEPS :: 48

append_bezier :: proc(pts: ^[dynamic]Vec2, a, c1, c2, b: Vec2) {
	it := p.make_bezier_iterator(a, c1, c2, b, FRAME_BEZIER_STEPS)
	first := true
	for {
		_, q, ok := p.iterate_bezier(&it)
		if !ok {
			break
		}
		if first {
			first = false
			continue // already the last point of pts
		}
		append(pts, q)
	}
	pts[len(pts) - 1] = b // accumulated t may stop short of 1
}

frame_ogee :: proc() {
	x0, y0: f32 = 100, 10
	x1, y1: f32 = win.x - 100, win.y - 10

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

	left := make([dynamic]Vec2, context.temp_allocator)
	append(&left, Vec2{x0, y1}, Vec2{x0, ya0})
	append_bezier(&left, {x0, ya0}, {x0, ya0 - control_dist},
		{xa0 - comp1_x, ya1 + comp1_y}, {xa0, ya1})
	append_bezier(&left, {xa0, ya1}, {xa0 + comp1_x, ya1 - comp1_y},
		{xc, y0 + control_dist}, {xc, y0})

	right := make([dynamic]Vec2, context.temp_allocator)
	append(&right, Vec2{x1, y1}, Vec2{x1, ya0})
	append_bezier(&right, {x1, ya0}, {x1, ya0 - control_dist},
		{xa1 + comp1_x, ya1 + comp1_y}, {xa1, ya1})
	append_bezier(&right, {xa1, ya1}, {xa1 - comp1_x, ya1 - comp1_y},
		{xc, y0 + control_dist}, {xc, y0})

	// both halves end at the apex, so walk the right one back from below it
	for i := len(right) - 2; i >= 0; i -= 1 {
		append(&left, right[i])
	}

	p.polyline(left[:], closed = true)
	p.push_clip(left[:])
}

main :: proc() {
	p.run(600, 600, "sketch", draw, loop = false)
}

