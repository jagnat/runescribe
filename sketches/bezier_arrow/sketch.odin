#+feature using-stmt
package sketch

import p "../../plot"
import "core:math"
import "core:math/linalg"
import "core:math/rand"

FLAT :: 16
CELL :: f32(40)
SEP :: f32(8)
MAX_ARROWS :: 1500
CHILDREN :: 4
ATTEMPTS :: 25

Arrow :: struct {
	pts: [FLAT + 1]p.Vec2,
}

Spot :: struct {
	mid: p.Vec2,
	perp: f32,
}

Grid :: struct {
	cols, rows: int,
	cells: [][dynamic]int,
	stamp: []int,
	tick: int,
}

main :: proc() {
	p.run(800, 800, "bezier_arrow", draw, loop = false)
}

draw :: proc() {
	beziers := make([dynamic]Arrow, context.temp_allocator)
	spots := make([dynamic]Spot, context.temp_allocator)
	grid := grid_make(p.canvas.width, p.canvas.height)

	for !try_place(&beziers, &spots, &grid, {p.canvas.width / 2, p.canvas.height / 2}, rand.float32_range(0, math.TAU)) {
	}

	head := 0
	for head < len(spots) && len(beziers) < MAX_ARROWS {
		spot := spots[head]
		head += 1

		made := 0
		for _ in 0 ..< ATTEMPTS {
			if made >= CHILDREN {
				break
			}
			side := f32(-1) if rand.float32() < 0.5 else 1
			gap := rand.float32_range(8, 15)
			tip := spot.mid + dir(spot.perp) * side * gap
			base := spot.perp if side > 0 else spot.perp + math.PI
			ang := rand.float32_range(base - 0.2, base + 0.2)
			if try_place(&beziers, &spots, &grid, tip, ang) {
				made += 1
			}
		}
	}
}

// tip is where the arrowhead lands; origin_angle points from tip back along the tail
try_place :: proc(beziers: ^[dynamic]Arrow, spots: ^[dynamic]Spot, grid: ^Grid, tip: p.Vec2, origin_angle: f32) -> bool {
	l := rand.float32_range(30, 70)
	tail := tip + dir(origin_angle) * l

	turn := f32(-1) if rand.float32() < 0.5 else 1
	control_angle := origin_angle + (math.PI / 2) * turn
	cd := rand.float32_range(0, l * 0.5)
	bulge := dir(control_angle) * cd
	cp1 := tail + (tip - tail) * (1.0 / 3.0) + bulge
	cp2 := tail + (tip - tail) * (2.0 / 3.0) + bulge

	pts := flatten(tail, cp1, cp2, tip)

	for pt in pts {
		if pt.x < 0 || pt.y < 0 || pt.x > p.canvas.width || pt.y > p.canvas.height {
			return false
		}
	}

	if grid_collides(grid, beziers[:], pts[:]) {
		return false
	}

	idx := len(beziers)
	append(beziers, Arrow{pts})
	grid_register(grid, idx, pts[:])

	p.stroke(0)
	p.stroke_weight(1)
	p.bezier(tail.x, tail.y, cp1.x, cp1.y, cp2.x, cp2.y, tip.x, tip.y)

	heading := tip - cp2
	head_angle := math.atan2(heading.y, heading.x)
	p.line(tip.x, tip.y, tip.x + math.cos(head_angle + 2.7) * 10, tip.y + math.sin(head_angle + 2.7) * 10)
	p.line(tip.x, tip.y, tip.x + math.cos(head_angle - 2.7) * 10, tip.y + math.sin(head_angle - 2.7) * 10)

	// pts[FLAT/2] is the t=0.5 point; control_angle is the outward normal there
	append(spots, Spot{pts[FLAT / 2], control_angle})
	return true
}

dir :: proc(a: f32) -> p.Vec2 {
	return {math.cos(a), math.sin(a)}
}

flatten :: proc(a, c1, c2, b: p.Vec2) -> [FLAT + 1]p.Vec2 {
	pts: [FLAT + 1]p.Vec2
	for i in 0 ..= FLAT {
		t := f32(i) / f32(FLAT)
		u := 1 - t
		pts[i] = u * u * u * a + 3 * u * u * t * c1 + 3 * u * t * t * c2 + t * t * t * b
	}
	return pts
}

grid_make :: proc(w, h: f32) -> Grid {
	cols := int(math.ceil(w / CELL))
	rows := int(math.ceil(h / CELL))
	cells := make([][dynamic]int, cols * rows, context.temp_allocator)
	for &c in cells {
		c = make([dynamic]int, context.temp_allocator)
	}
	return {cols, rows, cells, make([]int, MAX_ARROWS, context.temp_allocator), 0}
}

cell_of :: proc(g: ^Grid, pt: p.Vec2) -> (int, int) {
	cx := clamp(int(pt.x / CELL), 0, g.cols - 1)
	cy := clamp(int(pt.y / CELL), 0, g.rows - 1)
	return cx, cy
}

grid_register :: proc(g: ^Grid, idx: int, pts: []p.Vec2) {
	prev := -1
	for pt in pts {
		cx, cy := cell_of(g, pt)
		ci := cy * g.cols + cx
		if ci != prev {
			append(&g.cells[ci], idx)
			prev = ci
		}
	}
}

grid_collides :: proc(g: ^Grid, beziers: []Arrow, pts: []p.Vec2) -> bool {
	g.tick += 1
	for pt in pts {
		cx, cy := cell_of(g, pt)
		for dy in -1 ..= 1 {
			for dx in -1 ..= 1 {
				nx := cx + dx
				ny := cy + dy
				if nx < 0 || ny < 0 || nx >= g.cols || ny >= g.rows {
					continue
				}
				for idx in g.cells[ny * g.cols + nx] {
					if g.stamp[idx] == g.tick {
						continue
					}
					g.stamp[idx] = g.tick
					if arrows_collide(beziers[idx].pts[:], pts) {
						return true
					}
				}
			}
		}
	}
	return false
}

arrows_collide :: proc(a, b: []p.Vec2) -> bool {
	sep2 := SEP * SEP
	for i in 0 ..< len(a) - 1 {
		for j in 0 ..< len(b) - 1 {
			if seg_seg_dist2(a[i], a[i + 1], b[j], b[j + 1]) < sep2 {
				return true
			}
		}
	}
	return false
}

// Squared distance between segments p1-q1 and p2-q2 (Ericson, closest points)
seg_seg_dist2 :: proc(p1, q1, p2, q2: p.Vec2) -> f32 {
	d1 := q1 - p1
	d2 := q2 - p2
	r := p1 - p2
	a := linalg.dot(d1, d1)
	e := linalg.dot(d2, d2)
	f := linalg.dot(d2, r)

	s, t: f32
	if a <= 1e-8 && e <= 1e-8 {
		return linalg.dot(r, r)
	}
	if a <= 1e-8 {
		t = clamp(f / e, 0, 1)
	} else {
		c := linalg.dot(d1, r)
		if e <= 1e-8 {
			s = clamp(-c / a, 0, 1)
		} else {
			b := linalg.dot(d1, d2)
			denom := a * e - b * b
			if denom != 0 {
				s = clamp((b * f - c * e) / denom, 0, 1)
			}
			t = (b * s + f) / e
			if t < 0 {
				t = 0
				s = clamp(-c / a, 0, 1)
			} else if t > 1 {
				t = 1
				s = clamp((b - c) / a, 0, 1)
			}
		}
	}
	c1 := p1 + d1 * s
	c2 := p2 + d2 * t
	diff := c1 - c2
	return linalg.dot(diff, diff)
}
