#+feature using-stmt
package sketch

import p "../../plot"
import "core:math"
import "core:math/rand"

Vec2 :: p.Vec2
TAU :: math.TAU

RingKind :: enum {
	Petals,
	Diamonds,
	Triangles,
	Circles,
	Slits,
	Arcs,
}

Ring :: struct {
	kind: RingKind,
	r0, r1: f32,
	count: int,
	offset: f32,
	fill: f32,
}

main :: proc() {
	p.run(700, 700, "mandala", draw, loop = false)
}

draw :: proc() {
	c := Vec2{p.canvas.width / 2, p.canvas.height / 2}
	p.stroke(0)
	p.stroke_weight(1)

	outer := min(c.x, c.y) - 30
	sym := p.param_int("symmetry", 12, 4, 24)
	nrings := p.param_int("rings", 5, 2, 8)
	fill := p.param("fill", 0.34, 0.15, 0.48)
	boundary := p.toggle("boundary", true)

	if boundary {
		p.circle(c, outer)
		p.circle(c, outer * 0.965)
	}
	p.circle(c, outer * 0.06)

	r_start := outer * 0.11
	span := outer - r_start
	band := span / f32(nrings)

	prev := RingKind.Slits
	for i in 0 ..< nrings {
		b0 := r_start + band * f32(i)
		b1 := b0 + band

		kind := i == 0 ? RingKind.Petals : pick_kind(prev)
		prev = kind

		mult := 1
		if rand.float32() < 0.3 {
			mult = 2
		}
		count := sym * mult

		ring := Ring {
			kind = kind,
			r0 = b0 + band * 0.14,
			r1 = b1 - band * 0.14,
			count = count,
			offset = i % 2 == 0 ? 0 : (TAU / f32(count)) * 0.5,
			fill = fill,
		}
		draw_ring(c, ring)
	}
}

pick_kind :: proc(prev: RingKind) -> RingKind {
	n := int(max(RingKind)) + 1
	for {
		k := RingKind(rand.int_max(n))
		if k != prev {
			return k
		}
	}
}

draw_ring :: proc(c: Vec2, ring: Ring) {
	switch ring.kind {
	case .Petals:
		draw_petals(c, ring)
	case .Diamonds:
		draw_polys(c, ring, false)
	case .Triangles:
		draw_polys(c, ring, true)
	case .Circles:
		draw_circles(c, ring)
	case .Slits:
		draw_slits(c, ring)
	case .Arcs:
		draw_arcs(c, ring)
	}
}

draw_petals :: proc(c: Vec2, ring: Ring) {
	slice := TAU / f32(ring.count)
	mid := (ring.r0 + ring.r1) * 0.5
	w := mid * slice * ring.fill
	L := ring.r1 - ring.r0
	for i in 0 ..< ring.count {
		a := ring.offset + f32(i) * slice
		p.push_matrix()
		p.translate(c.x, c.y)
		p.rotate(a)
		pts := make([dynamic]Vec2, context.temp_allocator)
		append(&pts, Vec2{ring.r0, 0})
		bez(&pts, {ring.r0, 0}, {ring.r0 + L * 0.3, w}, {ring.r1 - L * 0.2, w * 0.55}, {ring.r1, 0})
		bez(&pts, {ring.r1, 0}, {ring.r1 - L * 0.2, -w * 0.55}, {ring.r0 + L * 0.3, -w}, {ring.r0, 0})
		p.polyline(pts[:], true)
		p.pop_matrix()
	}
}

draw_polys :: proc(c: Vec2, ring: Ring, triangle: bool) {
	slice := TAU / f32(ring.count)
	mid := (ring.r0 + ring.r1) * 0.5
	w := mid * slice * ring.fill
	for i in 0 ..< ring.count {
		a := ring.offset + f32(i) * slice
		p.push_matrix()
		p.translate(c.x, c.y)
		p.rotate(a)
		if triangle {
			pts := [3]Vec2{{ring.r0, -w}, {ring.r1, 0}, {ring.r0, w}}
			p.polyline(pts[:], true)
		} else {
			pts := [4]Vec2{{ring.r0, 0}, {mid, w}, {ring.r1, 0}, {mid, -w}}
			p.polyline(pts[:], true)
		}
		p.pop_matrix()
	}
}

draw_circles :: proc(c: Vec2, ring: Ring) {
	slice := TAU / f32(ring.count)
	mid := (ring.r0 + ring.r1) * 0.5
	cr := min((ring.r1 - ring.r0) * 0.5, mid * slice * 0.45)
	for i in 0 ..< ring.count {
		a := ring.offset + f32(i) * slice
		d := Vec2{math.cos(a), math.sin(a)}
		p.circle(c + d * mid, cr)
	}
}

draw_slits :: proc(c: Vec2, ring: Ring) {
	slice := TAU / f32(ring.count)
	for i in 0 ..< ring.count {
		a := ring.offset + f32(i) * slice
		d := Vec2{math.cos(a), math.sin(a)}
		p.line(c + d * ring.r0, c + d * ring.r1)
	}
}

draw_arcs :: proc(c: Vec2, ring: Ring) {
	slice := TAU / f32(ring.count)
	gap := slice * 0.16
	for i in 0 ..< ring.count {
		a0 := ring.offset + f32(i) * slice + gap
		a1 := ring.offset + f32(i + 1) * slice - gap
		p.arc(c, ring.r0, a0, a1)
		p.arc(c, ring.r1, a0, a1)
	}
}

bez :: proc(pts: ^[dynamic]Vec2, a, c1, c2, b: Vec2) {
	it := p.make_bezier_iterator(a, c1, c2, b, 20)
	first := true
	for {
		_, q, ok := p.iterate_bezier(&it)
		if !ok {
			break
		}
		if first {
			first = false
			continue
		}
		append(pts, q)
	}
}
