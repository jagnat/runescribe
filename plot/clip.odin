package plot

import "core:slice"

// Record-time clipping. A stroke must survive every active region: a mask
// keeps the parts inside its polygon, an occluder (invert) drops them.
// For hidden-line removal, draw front to back, pushing each shape's silhouette
// as an occluder before drawing what lies behind it. Occluders are normally
// never popped -- the per-frame reset clears them.

Clip :: struct {
	polygon: []Vec2, // canvas space, implicitly closed
	lo, hi: Vec2, // bounds, for early-outs
	invert: bool, // keep outside instead of inside
}

// Sub-spans shorter than this fraction of their segment are dropped
@(private)
CLIP_T_EPS :: f32(1e-5)

// Points are copied. Even-odd rule, so concave and self-intersecting outlines work
push_clip :: proc(points: []Vec2, invert := false) {
	if len(points) < 3 {
		return
	}
	poly := make([]Vec2, len(points), context.temp_allocator)
	lo := Vec2{max(f32), max(f32)}
	hi := Vec2{min(f32), min(f32)}
	for p, i in points {
		q := apply(p)
		poly[i] = q
		lo.x = min(lo.x, q.x)
		lo.y = min(lo.y, q.y)
		hi.x = max(hi.x, q.x)
		hi.y = max(hi.y, q.y)
	}
	c := Clip{poly, lo, hi, invert}
	if canvas.group != nil {
		append(&canvas.group.ops, c)
		return
	}
	append(&canvas.clips, c)
}

pop_clip :: proc() {
	if canvas.group != nil {
		append(&canvas.group.ops, Pop_Clip{})
		return
	}
	pop(&canvas.clips)
}

// Hides subsequent shapes where they fall inside the polygon
push_occlude :: proc(points: []Vec2) {
	push_clip(points, invert = true)
}

push_clip_circle :: proc {
	push_clip_circle_xy,
	push_clip_circle_v,
}

push_clip_circle_v :: proc(center: Vec2, r: f32, invert := false) {
	push_clip(ellipse_points(center, r, r, circle_segments(r * xform_scale())), invert)
}

push_clip_circle_xy :: proc(x, y, r: f32, invert := false) {
	push_clip_circle_v({x, y}, r, invert)
}

push_clip_rect :: proc {
	push_clip_rect_xy,
	push_clip_rect_v,
}

push_clip_rect_v :: proc(pos, size: Vec2, invert := false) {
	pts := [4]Vec2{pos, pos + {size.x, 0}, pos + size, pos + {0, size.y}}
	push_clip(pts[:], invert)
}

push_clip_rect_xy :: proc(x, y, w, h: f32, invert := false) {
	push_clip_rect_v({x, y}, {w, h}, invert)
}

// Even-odd point-in-polygon test
point_in_polygon :: proc(p: Vec2, poly: []Vec2) -> bool {
	inside := false
	for a, i in poly {
		b := poly[(i + 1) % len(poly)]
		if (a.y > p.y) != (b.y > p.y) {
			if p.x < a.x + (b.x - a.x) * (p.y - a.y) / (b.y - a.y) {
				inside = !inside
			}
		}
	}
	return inside
}

// A point this close (canvas px) to a region's edge grazes it and survives.
// Axonometric projections put a lot of geometry exactly on silhouette edges,
// and classifying those point-by-point dashes them unpredictably; keeping them
// only ever re-inks a line that gets drawn anyway. Relies on solids pushing
// every face as an occluder, back faces included, so a truly hidden stroke
// still falls strictly inside one of them
@(private)
CLIP_EDGE_EPS :: f32(0.02)

@(private)
near_boundary :: proc(p: Vec2, clip: Clip) -> bool {
	if p.x < clip.lo.x - CLIP_EDGE_EPS || p.x > clip.hi.x + CLIP_EDGE_EPS ||
		p.y < clip.lo.y - CLIP_EDGE_EPS || p.y > clip.hi.y + CLIP_EDGE_EPS {
		return false
	}
	for a, i in clip.polygon {
		b := clip.polygon[(i + 1) % len(clip.polygon)]
		if dist_point_segment(p, a, b) < CLIP_EDGE_EPS {
			return true
		}
	}
	return false
}

@(private)
point_visible :: proc(p: Vec2) -> bool {
	for clip in canvas.clips {
		inside := p.x >= clip.lo.x && p.x <= clip.hi.x &&
			p.y >= clip.lo.y && p.y <= clip.hi.y &&
			point_in_polygon(p, clip.polygon)
		if inside == clip.invert {
			if near_boundary(p, clip) {
				continue
			}
			return false
		}
	}
	return true
}

// Splits a-b at every clip-edge crossing and keeps the sub-spans whose
// midpoints survive; adjacent survivors are merged. ts and spans are caller scratch
@(private)
segment_spans :: proc(a, b: Vec2, ts: ^[dynamic]f32, spans: ^[dynamic][2]f32) {
	clear(ts)
	append(ts, 0, 1)
	r := b - a
	slo := Vec2{min(a.x, b.x), min(a.y, b.y)}
	shi := Vec2{max(a.x, b.x), max(a.y, b.y)}
	for clip in canvas.clips {
		if slo.x > clip.hi.x || shi.x < clip.lo.x || slo.y > clip.hi.y || shi.y < clip.lo.y {
			continue
		}
		poly := clip.polygon
		for p, i in poly {
			q := poly[(i + 1) % len(poly)]
			s := q - p
			denom := r.x * s.y - r.y * s.x
			if abs(denom) < 1e-12 { // parallel: midpoint classification decides
				continue
			}
			ap := p - a
			t := (ap.x * s.y - ap.y * s.x) / denom
			u := (ap.x * r.y - ap.y * r.x) / denom
			if t > 0 && t < 1 && u >= 0 && u <= 1 {
				append(ts, t)
			}
		}
	}
	slice.sort(ts[:])
	clear(spans)
	for i in 0 ..< len(ts) - 1 {
		t0 := ts[i]
		t1 := ts[i + 1]
		if t1 - t0 < CLIP_T_EPS {
			continue
		}
		if !point_visible(a + r * ((t0 + t1) / 2)) {
			continue
		}
		if n := len(spans); n > 0 && t0 - spans[n - 1][1] < CLIP_T_EPS {
			spans[n - 1][1] = t1
		} else {
			append(spans, [2]f32{t0, t1})
		}
	}
}

// Records the surviving pieces, or returns false when the geometry is fully
// visible so record keeps the original (a circle stays a circle)
@(private)
record_clipped :: proc(g: Geom) -> bool {
	ts := make([dynamic]f32, context.temp_allocator)
	spans := make([dynamic][2]f32, context.temp_allocator)
	switch s in g {
	case Line:
		if s.a == s.b { // pen-down dot: all or nothing
			return !point_visible(s.a)
		}
		segment_spans(s.a, s.b, &ts, &spans)
		if len(spans) == 1 && spans[0][0] == 0 && spans[0][1] == 1 {
			return false
		}
		d := s.b - s.a
		for sp in spans {
			append(&canvas.shapes, Shape{Line{s.a + d * sp[0], s.a + d * sp[1]}, canvas.color, canvas.weight})
		}
		return true
	case Circle:
		pts := ellipse_points(s.center, s.r, s.r, circle_segments(s.r))
		return record_polyline_clipped(pts, true, &ts, &spans)
	case Polyline:
		return record_polyline_clipped(s.points, s.closed, &ts, &spans)
	}
	return false
}

@(private)
record_polyline_clipped :: proc(pts: []Vec2, closed: bool, ts: ^[dynamic]f32, spans: ^[dynamic][2]f32) -> bool {
	if len(pts) < 2 {
		return false
	}
	nseg := len(pts) - 1
	if closed {
		nseg += 1
	}
	pieces := make([dynamic][]Vec2, context.temp_allocator)
	cur := make([dynamic]Vec2, context.temp_allocator)
	clipped_any := false
	prev_full_end := false
	starts_at_zero := false

	for si in 0 ..< nseg {
		a := pts[si]
		b := pts[(si + 1) % len(pts)]
		segment_spans(a, b, ts, spans)
		if !(len(spans) == 1 && spans[0][0] == 0 && spans[0][1] == 1) {
			clipped_any = true
		}
		for sp, j in spans {
			p0 := a + (b - a) * sp[0]
			p1 := a + (b - a) * sp[1]
			if j == 0 && sp[0] < CLIP_T_EPS && prev_full_end && len(cur) > 0 {
				append(&cur, p1) // continues the previous segment's piece
			} else {
				if len(cur) >= 2 {
					append(&pieces, slice.clone(cur[:], context.temp_allocator))
				}
				clear(&cur)
				append(&cur, p0, p1)
				if si == 0 && j == 0 && sp[0] < CLIP_T_EPS {
					starts_at_zero = true
				}
			}
		}
		prev_full_end = len(spans) > 0 && spans[len(spans) - 1][1] > 1 - CLIP_T_EPS
	}
	if !clipped_any {
		return false
	}
	if len(cur) >= 2 {
		append(&pieces, slice.clone(cur[:], context.temp_allocator))
	}

	// a clipped closed loop has no real seam at pts[0]: if the last piece runs
	// into the first, join them so the pen does not lift there
	if closed && len(pieces) >= 2 && starts_at_zero && prev_full_end {
		last := pop(&pieces)
		merged := make([]Vec2, len(last) + len(pieces[0]) - 1, context.temp_allocator)
		copy(merged, last)
		copy(merged[len(last):], pieces[0][1:])
		pieces[0] = merged
	}

	for piece in pieces {
		if len(piece) == 2 {
			append(&canvas.shapes, Shape{Line{piece[0], piece[1]}, canvas.color, canvas.weight})
		} else {
			append(&canvas.shapes, Shape{Polyline{piece, false}, canvas.color, canvas.weight})
		}
	}
	return true
}
