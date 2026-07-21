package plot

import "core:math/linalg"
import "core:slice"

// Crossing gaps: where strands cross, the under strand gets a gap-wide
// window cut out so the other appears to pass over. weave alternates
// over/under along each strand's own length (self-crossings included) for
// the woven look; gapped puts one polyline under everything in others.
// Strands are open polylines -- pass loops with the first point repeated
// (closure is detected: the seam is not a crossing, and gaps wrap past it).
// Returned pieces are drawn open, e.g. with polyline()

weave :: proc(strands: [][]Vec2, gap: f32, allocator := context.temp_allocator) -> [][]Vec2 {
	cums := make([][]f32, len(strands), context.temp_allocator)
	closed := make([]bool, len(strands), context.temp_allocator)
	for s, i in strands {
		cums[i] = weave_cum(s)
		closed[i] = weave_closed(s)
	}
	crossings := make([dynamic]Weave_Cross, context.temp_allocator)
	for a, i in strands {
		weave_find(a, a, cums[i], cums[i], i, i, closed[i], closed[i], &crossings)
		for j in i + 1 ..< len(strands) {
			weave_find(a, strands[j], cums[i], cums[j], i, j, closed[i], closed[j], &crossings)
		}
	}

	// rank each strand's crossings by arc length; odd ranks go under
	Inc :: struct {
		cross, side: int,
		s: f32,
	}
	under := make([][2]bool, len(crossings), context.temp_allocator)
	incs := make([dynamic]Inc, context.temp_allocator)
	for k in 0 ..< len(strands) {
		clear(&incs)
		for c, ci in crossings {
			if c.strand[0] == k {
				append(&incs, Inc{ci, 0, c.s[0]})
			}
			if c.strand[1] == k {
				append(&incs, Inc{ci, 1, c.s[1]})
			}
		}
		slice.sort_by(incs[:], proc(x, y: Inc) -> bool {
			return x.s < y.s
		})
		for inc, rank in incs {
			under[inc.cross][inc.side] = rank % 2 == 1
		}
	}

	// each strand alternates, but its phase is free: flip whole strands so
	// parities disagree where strands cross each other (always satisfiable
	// for planar curves; leftover conflicts fall to the tie-break below)
	flip := make([]bool, len(strands), context.temp_allocator)
	seen := make([]bool, len(strands), context.temp_allocator)
	queue := make([dynamic]int, context.temp_allocator)
	for root in 0 ..< len(strands) {
		if seen[root] {
			continue
		}
		seen[root] = true
		append(&queue, root)
		for len(queue) > 0 {
			k := pop(&queue)
			for c, ci in crossings {
				o := -1
				if c.strand[0] == k && c.strand[1] != k {
					o = c.strand[1]
				} else if c.strand[1] == k && c.strand[0] != k {
					o = c.strand[0]
				}
				if o < 0 || seen[o] {
					continue
				}
				seen[o] = true
				flip[o] = flip[k] != (under[ci][0] == under[ci][1])
				append(&queue, o)
			}
		}
	}
	for &u, ci in under {
		if flip[crossings[ci].strand[0]] {
			u[0] = !u[0]
		}
		if flip[crossings[ci].strand[1]] {
			u[1] = !u[1]
		}
	}

	cuts := make([][dynamic][2]f32, len(strands), context.temp_allocator)
	for &c in cuts {
		c = make([dynamic][2]f32, context.temp_allocator)
	}
	for c, ci in crossings {
		u0 := under[ci][0]
		// parities can agree at a crossing; earlier strands stay on top, and a
		// self-crossing dives under on the return visit
		if u0 == under[ci][1] {
			u0 = c.strand[0] == c.strand[1] && c.s[0] >= c.s[1]
		}
		side := u0 ? 0 : 1
		s := c.s[side]
		append(&cuts[c.strand[side]], [2]f32{s - gap / 2, s + gap / 2})
	}

	out := make([dynamic][]Vec2, allocator)
	for strand, k in strands {
		weave_cut(strand, cuts[k][:], closed[k], &out, allocator)
	}
	return out[:]
}

// points cut at every crossing with the other strands, which stay whole
gapped :: proc(points: []Vec2, others: [][]Vec2, gap: f32, allocator := context.temp_allocator) -> [][]Vec2 {
	cum := weave_cum(points)
	closed := weave_closed(points)
	crossings := make([dynamic]Weave_Cross, context.temp_allocator)
	for o in others {
		weave_find(points, o, cum, weave_cum(o), 0, 1, closed, weave_closed(o), &crossings)
	}
	cuts := make([dynamic][2]f32, context.temp_allocator)
	for c in crossings {
		append(&cuts, [2]f32{c.s[0] - gap / 2, c.s[0] + gap / 2})
	}
	out := make([dynamic][]Vec2, allocator)
	weave_cut(points, cuts[:], closed, &out, allocator)
	return out[:]
}

@(private)
Weave_Cross :: struct {
	strand: [2]int,
	s: [2]f32, // arc length along each strand
}

@(private)
weave_cum :: proc(pts: []Vec2) -> []f32 {
	cum := make([]f32, len(pts), context.temp_allocator)
	for i in 1 ..< len(pts) {
		cum[i] = cum[i - 1] + linalg.distance(pts[i - 1], pts[i])
	}
	return cum
}

@(private)
weave_closed :: proc(pts: []Vec2) -> bool {
	return len(pts) > 3 && linalg.distance(pts[0], pts[len(pts) - 1]) < 1e-3
}

// Each crossing counts once: half-open [0, 1) per segment, so a crossing on
// a shared vertex belongs to the segments starting there. Touches at an open
// strand's endpoints don't count. Self-search (ai == bi) skips adjacent
// segments, including the seam pair of a closed loop
@(private)
weave_find :: proc(a, b: []Vec2, cum_a, cum_b: []f32, ai, bi: int, closed_a, closed_b: bool, out: ^[dynamic]Weave_Cross) {
	for i in 0 ..< len(a) - 1 {
		ra := a[i + 1] - a[i]
		j0 := ai == bi ? i + 2 : 0
		j1 := len(b) - 1
		if ai == bi && closed_a && i == 0 {
			j1 -= 1
		}
		for j := j0; j < j1; j += 1 {
			rb := b[j + 1] - b[j]
			denom := ra.x * rb.y - ra.y * rb.x
			if abs(denom) < 1e-12 {
				continue
			}
			ap := b[j] - a[i]
			t := (ap.x * rb.y - ap.y * rb.x) / denom
			u := (ap.x * ra.y - ap.y * ra.x) / denom
			if t < 0 || t >= 1 || u < 0 || u >= 1 {
				continue
			}
			if (t == 0 && i == 0 && !closed_a) || (u == 0 && j == 0 && !closed_b) {
				continue
			}
			append(out, Weave_Cross{
				{ai, bi},
				{cum_a[i] + t * (cum_a[i + 1] - cum_a[i]), cum_b[j] + u * (cum_b[j + 1] - cum_b[j])},
			})
		}
	}
}

// Emits the spans of pts that survive between the cut windows. On closed
// strands windows wrap past the seam, and the two pieces meeting there are
// stitched into one so the pen crosses the seam in a single stroke
@(private)
weave_cut :: proc(pts: []Vec2, cuts: [][2]f32, closed: bool, out: ^[dynamic][]Vec2, allocator := context.temp_allocator) {
	if len(cuts) == 0 {
		append(out, slice.clone(pts, allocator))
		return
	}
	total := path_length(pts)
	windows := make([dynamic][2]f32, 0, len(cuts) + 1, context.temp_allocator)
	for c in cuts {
		switch {
		case closed && c[0] < 0:
			append(&windows, [2]f32{0, c[1]}, [2]f32{total + c[0], total})
		case closed && c[1] > total:
			append(&windows, [2]f32{c[0], total}, [2]f32{0, c[1] - total})
		case:
			append(&windows, c)
		}
	}
	slice.sort_by(windows[:], proc(x, y: [2]f32) -> bool {
		return x[0] < y[0]
	})
	first := len(out)
	pos := f32(0)
	for c in windows {
		if c[0] - pos > 1e-3 {
			piece := subpath(pts, pos, c[0], false, allocator)
			if len(piece) >= 2 {
				append(out, piece)
			}
		}
		pos = max(pos, c[1])
	}
	if total - pos > 1e-3 {
		piece := subpath(pts, pos, total, false, allocator)
		if len(piece) >= 2 {
			append(out, piece)
		}
	}
	if closed && len(out) - first >= 2 {
		head := out[first]
		tail := out[len(out) - 1]
		if linalg.distance(head[0], pts[0]) < 1e-3 && linalg.distance(tail[len(tail) - 1], pts[len(pts) - 1]) < 1e-3 {
			joined := make([]Vec2, len(tail) + len(head) - 1, allocator)
			copy(joined, tail)
			copy(joined[len(tail):], head[1:])
			out[first] = joined
			pop(out)
		}
	}
}
