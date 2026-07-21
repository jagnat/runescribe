package sketch

import p "../../plot"
import "core:math"
import "core:math/rand"

Vec2 :: p.Vec2
TAU :: math.TAU

RingKind :: enum {
	Petals,
	Lancets,
	Star,
	Lattice,
	Dots,
	Scallops,
	Spokes,
}

Ring :: struct {
	r0, r1: f32,
	count: int,
	off: f32,
}

Band :: struct {
	loops: [][]Vec2,
	clip_pts: []Vec2,
	lo, hi: Vec2,
	color: p.Color,
}

bands: [dynamic]Band
center: Vec2

main :: proc() {
	p.run(800, 800, "laser mandala", draw, loop = false)
}

draw :: proc() {
	bands = make([dynamic]Band, context.temp_allocator)
	center = {p.canvas.width / 2, p.canvas.height / 2}
	strut := p.param("strut", 3.5, 2, 7)
	fine := p.param("fine strut", 2.2, 1.2, 7)
	delicacy := p.param("delicacy", 0.35, 0, 1)
	overlap := p.param("overlap", 0.35, 0, 1)
	inner := p.param("inner", 0, 0, 0.75)
	nrings := p.param_int("rings", 6, 2, 8)
	sym := p.param_int("symmetry", 12, 4, 24)
	fine = min(fine, strut)

	outer := min(center.x, center.y) - 24
	hub := outer * 0.09
	r_in := outer * inner
	annulus := r_in > hub
	start := annulus ? r_in : hub

	add_circle_band(start, strut * (annulus ? 1.3 : 1), annulus ? p.RED : p.BLACK)

	weights := make([]f32, nrings, context.temp_allocator)
	total := f32(0)
	for i in 0 ..< nrings {
		weights[i] = 0.75 + rand.float32() * 0.7
		total += weights[i]
	}
	bounds := make([]f32, nrings + 1, context.temp_allocator)
	bounds[0] = start
	acc := f32(0)
	for i in 0 ..< nrings {
		acc += weights[i]
		bounds[i + 1] = start + (outer - start) * acc / total
	}

	for i in 0 ..< nrings {
		last := i == nrings - 1
		add_circle_band(bounds[i + 1], strut * (last ? 1.3 : 1), last ? p.RED : p.BLACK)
	}

	prev := RingKind.Spokes
	for i in 0 ..< nrings {
		ring: Ring
		ring.r0 = bounds[i]
		ring.r1 = bounds[i + 1]

		span := 0
		if i < nrings - 1 {
			roll := rand.float32()
			if roll < overlap * 0.5 {
				span = 2
				ring.r1 = bounds[i + 2]
			} else if roll < overlap {
				span = 1
				ring.r1 = bounds[i + 1] + (bounds[i + 2] - bounds[i + 1]) * (0.25 + rand.float32() * 0.5)
			}
		}

		mid := (ring.r0 + ring.r1) / 2
		ring.count = sym
		spacing := TAU * mid / f32(sym)
		if spacing > 70 && rand.float32() < 0.65 {
			ring.count = sym * 2
		} else if spacing < 34 && sym % 2 == 0 && rand.float32() < 0.5 {
			ring.count = sym / 2
		}
		ring.off = rand.float32() < 0.5 ? 0 : TAU / f32(ring.count) / 2

		del := span > 0 ? min(delicacy + 0.3, 0.9) : delicacy
		mh := (rand.float32() < del ? fine : strut) / 2

		kind: RingKind
		if i == 0 && !annulus {
			kind = .Petals
		} else {
			kind = pick_kind(prev, ring, mh, span == 1)
		}
		prev = kind

		switch kind {
		case .Petals:
			add_petals(ring, mh)
		case .Lancets:
			add_lancets(ring, mh)
		case .Star:
			add_star(ring, mh)
		case .Lattice:
			add_lattice(ring, mh)
		case .Dots:
			add_dots(ring, mh)
		case .Scallops:
			add_scallops(ring, mh)
		case .Spokes:
			add_spokes(ring, mh)
		}
	}

	render_bands()
}

pick_kind :: proc(prev: RingKind, ring: Ring, half: f32, closed_only: bool) -> RingKind {
	n := int(max(RingKind)) + 1
	for {
		k := RingKind(rand.int_max(n))
		if k == prev {
			continue
		}
		if closed_only {
			#partial switch k {
			case .Lattice, .Scallops, .Spokes:
				continue
			}
		}
		mid := (ring.r0 + ring.r1) / 2
		sl := TAU / f32(ring.count)
		#partial switch k {
		case .Dots:
			cr := (ring.r1 - ring.r0) / 2
			if 2 * mid * math.sin(sl / 2) < (ring.r1 - ring.r0) * 0.85 || cr < half * 3 {
				continue
			}
		case .Lattice, .Star:
			if ring.count < 8 {
				continue
			}
		}
		return k
	}
}

polar :: proc(a, r: f32) -> Vec2 {
	return center + r * Vec2{math.cos(a), math.sin(a)}
}

place :: proc(pts: []Vec2, a: f32) {
	co := math.cos(a)
	si := math.sin(a)
	for &q in pts {
		q = center + Vec2{co * q.x - si * q.y, si * q.x + co * q.y}
	}
}

circle_pts :: proc(c: Vec2, r: f32) -> []Vec2 {
	n := p.circle_segments(r)
	pts := make([]Vec2, n, context.temp_allocator)
	for i in 0 ..< n {
		t := f32(i) / f32(n) * TAU
		pts[i] = c + r * Vec2{math.cos(t), math.sin(t)}
	}
	return pts
}

bez :: proc(pts: ^[dynamic]Vec2, a, c1, c2, b: Vec2, steps := 16) {
	for i in 1 ..= steps {
		t := f32(i) / f32(steps)
		u := 1 - t
		append(pts, u * u * u * a + 3 * u * u * t * c1 + 3 * u * t * t * c2 + t * t * t * b)
	}
}

rounded :: proc(pts: []Vec2, closed := true) -> []Vec2 {
	return p.smooth(p.resample(pts, 7, closed), 2, closed)
}

add_band :: proc(pts: []Vec2, half: f32, closed := false, color := p.BLACK) {
	loops: [][]Vec2
	clip: []Vec2
	if closed {
		a := p.offset(pts, half, true)
		b := p.offset(pts, -half, true)
		loops = make([][]Vec2, 2, context.temp_allocator)
		loops[0] = a
		loops[1] = b
		cp := make([dynamic]Vec2, 0, len(a) + len(b) + 2, context.temp_allocator)
		append(&cp, ..a)
		append(&cp, a[0])
		append(&cp, ..b)
		append(&cp, b[0])
		clip = cp[:]
	} else {
		a := p.offset(pts, half, false)
		b := p.offset(pts, -half, false)
		cp := make([dynamic]Vec2, 0, len(a) + len(b), context.temp_allocator)
		append(&cp, ..a)
		#reverse for q in b {
			append(&cp, q)
		}
		loops = make([][]Vec2, 1, context.temp_allocator)
		loops[0] = cp[:]
		clip = cp[:]
	}
	lo := Vec2{max(f32), max(f32)}
	hi := Vec2{min(f32), min(f32)}
	for q in clip {
		lo.x = min(lo.x, q.x)
		lo.y = min(lo.y, q.y)
		hi.x = max(hi.x, q.x)
		hi.y = max(hi.y, q.y)
	}
	append(&bands, Band{loops, clip, lo, hi, color})
}

add_circle_band :: proc(r, half: f32, color := p.BLACK) {
	add_band(circle_pts(center, r), half, true, color)
}

add_petals :: proc(ring: Ring, half: f32) {
	sl := TAU / f32(ring.count)
	L := ring.r1 - ring.r0
	mid := (ring.r0 + ring.r1) / 2
	w := mid * sl * (0.26 + rand.float32() * 0.14)
	base := ring.r0 - half * 0.6
	tip := ring.r1 + half * 0.6
	c1x := ring.r0 + L * (0.2 + rand.float32() * 0.25)
	c2x := ring.r1 - L * (0.15 + rand.float32() * 0.2)
	w2 := w * (0.4 + rand.float32() * 0.35)
	vein := rand.float32() < 0.55 && w > half * 5
	for i in 0 ..< ring.count {
		a := ring.off + f32(i) * sl
		pts := make([dynamic]Vec2, context.temp_allocator)
		append(&pts, Vec2{base, 0})
		bez(&pts, {base, 0}, {c1x, w}, {c2x, w2}, {tip, 0})
		bez(&pts, {tip, 0}, {c2x, -w2}, {c1x, -w}, {base, 0})
		pop(&pts)
		sm := rounded(pts[:])
		place(sm, a)
		add_band(sm, half, true)
		if vein {
			vp := [2]Vec2{{ring.r0, 0}, {ring.r1, 0}}
			place(vp[:], a)
			add_band(vp[:], max(half * 0.8, 0.7))
		}
	}
}

add_lancets :: proc(ring: Ring, half: f32) {
	sl := TAU / f32(ring.count)
	L := ring.r1 - ring.r0
	w := ring.r0 * math.sin(sl / 2) * (0.62 + rand.float32() * 0.2)
	w = min(w, L * 0.6)
	base := ring.r0 - half * 0.5
	tip := ring.r1 + half * 0.6
	sh := 0.35 + rand.float32() * 0.3
	for i in 0 ..< ring.count {
		a := ring.off + f32(i) * sl
		pts := make([dynamic]Vec2, context.temp_allocator)
		append(&pts, Vec2{base, -w})
		append(&pts, Vec2{base, w})
		bez(&pts, {base, w}, {base + L * sh, w * 1.02}, {tip - L * 0.32, w * 0.32}, {tip, 0})
		bez(&pts, {tip, 0}, {tip - L * 0.32, -w * 0.32}, {base + L * sh, -w * 1.02}, {base, -w})
		pop(&pts)
		sm := rounded(pts[:])
		place(sm, a)
		add_band(sm, half, true)
	}
}

add_star :: proc(ring: Ring, half: f32) {
	sl := TAU / f32(ring.count)
	rt := ring.r1 + half * 0.6
	rv := ring.r0 - half * 0.6
	nphase := rand.float32() < 0.35 ? 2 : 1
	for ph in 0 ..< nphase {
		phase := f32(ph) * sl / 2
		pts := make([]Vec2, ring.count * 2, context.temp_allocator)
		for i in 0 ..< ring.count {
			a := ring.off + phase + f32(i) * sl
			pts[i * 2] = polar(a, rt)
			pts[i * 2 + 1] = polar(a + sl / 2, rv)
		}
		add_band(rounded(pts), half, true)
	}
}

add_lattice :: proc(ring: Ring, half: f32) {
	sl := TAU / f32(ring.count)
	k := f32(1)
	if ring.count >= 12 && rand.float32() < 0.5 {
		k = 2
	}
	for i in 0 ..< ring.count {
		a := ring.off + f32(i) * sl
		s1 := [2]Vec2{polar(a, ring.r1), polar(a + sl * k, ring.r0)}
		s2 := [2]Vec2{polar(a, ring.r1), polar(a - sl * k, ring.r0)}
		add_band(s1[:], half)
		add_band(s2[:], half)
	}
}

add_dots :: proc(ring: Ring, half: f32) {
	sl := TAU / f32(ring.count)
	mid := (ring.r0 + ring.r1) / 2
	cr := (ring.r1 - ring.r0) / 2
	for i in 0 ..< ring.count {
		add_band(circle_pts(polar(ring.off + f32(i) * sl, mid), cr), half, true)
	}
}

add_scallops :: proc(ring: Ring, half: f32) {
	sl := TAU / f32(ring.count)
	flip := rand.float32() < 0.35
	rb := flip ? ring.r1 : ring.r0
	target := flip ? ring.r0 - half * 0.6 : ring.r1 + half * 0.6
	rc := (8 * target - 2 * rb * math.cos(sl / 2)) / (6 * math.cos(sl * 0.17))
	for i in 0 ..< ring.count {
		a0 := ring.off + f32(i) * sl
		pts := make([dynamic]Vec2, context.temp_allocator)
		append(&pts, polar(a0, rb))
		bez(&pts, polar(a0, rb), polar(a0 + sl * 0.33, rc), polar(a0 + sl * 0.67, rc), polar(a0 + sl, rb), 24)
		add_band(pts[:], half)
	}
}

add_spokes :: proc(ring: Ring, half: f32) {
	sl := TAU / f32(ring.count)
	tilt := (rand.float32() * 1.6 - 0.8) * sl
	curved := rand.float32() < 0.6
	for i in 0 ..< ring.count {
		a := ring.off + f32(i) * sl
		if curved {
			pts := make([dynamic]Vec2, context.temp_allocator)
			append(&pts, polar(a, ring.r0))
			bez(&pts, polar(a, ring.r0), polar(a + tilt * 0.15, ring.r0 + (ring.r1 - ring.r0) * 0.4), polar(a + tilt * 0.6, ring.r0 + (ring.r1 - ring.r0) * 0.75), polar(a + tilt, ring.r1), 20)
			add_band(pts[:], half)
		} else {
			s := [2]Vec2{polar(a, ring.r0), polar(a + tilt, ring.r1)}
			add_band(s[:], half)
		}
	}
}

render_bands :: proc() {
	p.stroke_weight(1.2)
	for band, i in bands {
		pushed := 0
		for other, j in bands {
			if i == j || band.lo.x > other.hi.x || band.hi.x < other.lo.x || band.lo.y > other.hi.y || band.hi.y < other.lo.y {
				continue
			}
			p.push_occlude(other.clip_pts)
			pushed += 1
		}
		p.stroke(band.color)
		for l in band.loops {
			p.polyline(l, true)
		}
		for _ in 0 ..< pushed {
			p.pop_clip()
		}
	}
}
