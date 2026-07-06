package plot

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:slice"
import "core:time"
import rl "vendor:raylib"

Vec2 :: [2]f32
Mat :: matrix[3, 3]f32

// Max deviation of flattened curves from the true curve, in canvas px
FLATTEN_TOLERANCE :: f32(0.25)
MIN_CIRCLE_SEGMENTS :: 12
MAX_CIRCLE_SEGMENTS :: 2048
DEFAULT_WEIGHT :: f32(1.5)
DEFAULT_COLOR :: Color{0, 0, 0}

Color :: [3]u8 // RGB

BLACK :: Color{0, 0, 0}
WHITE :: Color{255, 255, 255}
RED :: Color{255, 0, 0}
GREEN :: Color{0, 128, 0}
BLUE :: Color{0, 0, 255}
ORANGE :: Color{255, 140, 0}
PURPLE :: Color{128, 0, 128}
BROWN :: Color{139, 69, 19}
MAGENTA :: Color{255, 0, 255}

Line :: struct {
	a, b: Vec2,
}

Circle :: struct {
	center: Vec2,
	r: f32,
}

Polyline :: struct {
	points: []Vec2,
	closed: bool,
}

Geom :: union {
	Line,
	Circle,
	Polyline,
}

Shape :: struct {
	geom: Geom,
	color: Color,
	weight: f32,
}

Canvas :: struct {
	width, height: f32,
	frame: int,
	seed: u64,
	weight: f32,
	color: Color,
	shapes: [dynamic]Shape,
	xform: Mat,
	xform_stack: [dynamic]Mat,
	verts: [dynamic]Vec2,
	clips: [dynamic]Clip,
}

// The single canvas. Sketches read width/height/seed off it and the whole
// package records against it, so no proc needs a canvas argument.
canvas: Canvas

// Opens the preview window and calls draw_proc once per frame. The canvas is
// cleared before every call, so draw_proc re-records the whole frame each time.
// With loop = false, draw_proc runs once and the recorded shapes are re-rendered
// until R rerolls the seed and triggers a redraw.
// Keys: S exports the current frame as SVG, R rerolls the random seed.
run :: proc(width, height: int, title: string, draw_proc: proc(), loop := true) {
	rl.SetConfigFlags({.WINDOW_HIGHDPI, .MSAA_4X_HINT})
	rl.InitWindow(i32(width), i32(height), fmt.ctprintf("%s | S: save svg, R: reseed", title))
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	canvas.width = f32(width)
	canvas.height = f32(height)
	canvas.seed = u64(time.now()._nsec)

	needs_draw := true

	for !rl.WindowShouldClose() {
		if rl.IsKeyPressed(.R) {
			canvas.seed += 1
			needs_draw = true
			rl.SetWindowTitle(fmt.ctprintf("%s | seed %d | S: save svg, R: reseed", title, canvas.seed))
		}

		if loop || needs_draw {
			// Recorded shapes live on the temp allocator, so it is only safe
			// to free once we are about to re-record the frame
			free_all(context.temp_allocator)
			canvas_reset()
			rand.reset(canvas.seed) // deterministic per frame, so the preview holds still until reseeded
			draw_proc()
			needs_draw = false
		}

		rl.BeginDrawing()
		rl.ClearBackground(rl.WHITE)
		render_shapes()
		rl.EndDrawing()

		if rl.IsKeyPressed(.S) {
			export_svg()
		}
		canvas.frame += 1
	}
}

// Clears all recording state onto a fresh temp-allocator frame. run calls this
// every frame; call it yourself if driving the canvas without a window
canvas_reset :: proc() {
	canvas.shapes = make([dynamic]Shape, context.temp_allocator)
	canvas.xform_stack = make([dynamic]Mat, context.temp_allocator)
	canvas.verts = make([dynamic]Vec2, context.temp_allocator)
	canvas.clips = make([dynamic]Clip, context.temp_allocator)
	canvas.xform = 1
	canvas.weight = DEFAULT_WEIGHT
	canvas.color = DEFAULT_COLOR
}

// Transforms

push_matrix :: proc() {
	append(&canvas.xform_stack, canvas.xform)
}

pop_matrix :: proc() {
	canvas.xform = pop(&canvas.xform_stack)
}

translate :: proc(x, y: f32) {
	canvas.xform *= Mat{1, 0, x, 0, 1, y, 0, 0, 1}
}

rotate :: proc(radians: f32) {
	co := math.cos(radians)
	si := math.sin(radians)
	canvas.xform *= Mat{co, -si, 0, si, co, 0, 0, 0, 1}
}

scale :: proc(sx: f32, sy := f32(0)) {
	sy := sy if sy != 0 else sx
	canvas.xform *= Mat{sx, 0, 0, 0, sy, 0, 0, 0, 1}
}

// Bakes the current transform into a point. Every shape proc routes its
// coordinates through this, so recorded shapes are always in canvas space.
apply :: proc(p: Vec2) -> Vec2 {
	v := canvas.xform * [3]f32{p.x, p.y, 1}
	return v.xy
}

// Largest stretch the current transform applies to any direction, estimated as
// the longer column of the 2x2 part; exact under rotation and uniform scale
xform_scale :: proc() -> f32 {
	sx := linalg.length(Vec2{canvas.xform[0, 0], canvas.xform[1, 0]})
	sy := linalg.length(Vec2{canvas.xform[0, 1], canvas.xform[1, 1]})
	return max(sx, sy)
}

// Segments for a full circle of canvas-space radius r so the sagitta of each
// chord stays under FLATTEN_TOLERANCE
circle_segments :: proc(r: f32) -> int {
	if r <= FLATTEN_TOLERANCE * 2 {
		return MIN_CIRCLE_SEGMENTS
	}
	n := int(math.ceil(math.PI / math.acos(1 - FLATTEN_TOLERANCE / r)))
	return clamp(n, MIN_CIRCLE_SEGMENTS, MAX_CIRCLE_SEGMENTS)
}

// Shapes

stroke_weight :: proc(w: f32) {
	canvas.weight = w
}

// Sets the stroke color for subsequent shapes. Carousel pen assignment happens
// later in svg2hpgl, keyed on (color, weight).
stroke :: proc {
	stroke_gray,
	stroke_rgb,
	stroke_color,
}

stroke_gray :: proc(gray: u8) {
	canvas.color = {gray, gray, gray}
}

stroke_rgb :: proc(r, g, b: u8) {
	canvas.color = {r, g, b}
}

stroke_color :: proc(col: Color) {
	canvas.color = col
}

record :: proc(g: Geom) {
	if len(canvas.clips) > 0 && record_clipped(g) {
		return
	}
	append(&canvas.shapes, Shape{g, canvas.color, canvas.weight})
}

// Every primitive is a proc group: pass expanded coordinates or Vec2s

LineIter :: struct {
	p0, p1: Vec2,
	total: f32,
	next_t: f32,
}

make_line_iterator :: proc(p0, p1: Vec2, total: f32) -> LineIter {
	return {p0, p1, total, 0}
}

iterate_line:: proc(iter: ^LineIter) -> (f32, Vec2, bool) {
	t := iter.next_t

	if t <= 1 {
		iter.next_t = t + 1 / (iter.total - 1)
		return t, {
			math.lerp(iter.p0.x, iter.p1.x, t),
			math.lerp(iter.p0.y, iter.p1.y, t)
		}, true
	} else do return 0, {}, false
}

line :: proc {
	line_xy,
	line_v,
}

line_v :: proc(a, b: Vec2) {
	record(Line{apply(a), apply(b)})
}

line_xy :: proc(x1, y1, x2, y2: f32) {
	line_v({x1, y1}, {x2, y2})
}

// A pen dot: exported as a zero-length line, which svg2hpgl turns into a pen-down dot
point :: proc {
	point_xy,
	point_v,
}

point_v :: proc(pt: Vec2) {
	p := apply(pt)
	record(Line{p, p})
}

point_xy :: proc(x, y: f32) {
	point_v({x, y})
}

// Radius follows uniform scale (sqrt of the transform determinant); use ellipse under nonuniform scale
circle :: proc {
	circle_xy,
	circle_v,
}

circle_v :: proc(center: Vec2, r: f32) {
	s := math.sqrt(abs(canvas.xform[0, 0] * canvas.xform[1, 1] - canvas.xform[0, 1] * canvas.xform[1, 0]))
	record(Circle{apply(center), r * s})
}

circle_xy :: proc(x, y, r: f32) {
	circle_v({x, y}, r)
}

// Flattened to a closed polyline so arbitrary transforms (rotation, shear) stay correct
ellipse :: proc {
	ellipse_xy,
	ellipse_v,
}

ellipse_v :: proc(center: Vec2, rx, ry: f32) {
	n := circle_segments(max(rx, ry) * xform_scale())
	pts := make([]Vec2, n, context.temp_allocator)
	for i in 0 ..< n {
		t := f32(i) / f32(n) * math.TAU
		pts[i] = apply(center + {rx * math.cos(t), ry * math.sin(t)})
	}
	record(Polyline{pts, true})
}

ellipse_xy :: proc(x, y, rx, ry: f32) {
	ellipse_v({x, y}, rx, ry)
}

// Circular arc from start_angle to end_angle in radians, flattened to an open
// polyline; sweeps backwards when end_angle < start_angle
arc :: proc {
	arc_xy,
	arc_v,
}

arc_v :: proc(center: Vec2, r, start_angle, end_angle: f32) {
	span := end_angle - start_angle
	full := circle_segments(r * xform_scale())
	n := max(int(math.ceil(f32(full) * abs(span) / math.TAU)), 1)
	pts := make([]Vec2, n + 1, context.temp_allocator)
	for i in 0 ..= n {
		t := start_angle + span * f32(i) / f32(n)
		pts[i] = apply(center + {r * math.cos(t), r * math.sin(t)})
	}
	record(Polyline{pts, false})
}

arc_xy :: proc(x, y, r, start_angle, end_angle: f32) {
	arc_v({x, y}, r, start_angle, end_angle)
}

rect :: proc {
	rect_xy,
	rect_v,
}

rect_v :: proc(pos, size: Vec2) {
	pts := make([]Vec2, 4, context.temp_allocator)
	pts[0] = apply(pos)
	pts[1] = apply(pos + {size.x, 0})
	pts[2] = apply(pos + size)
	pts[3] = apply(pos + {0, size.y})
	record(Polyline{pts, true})
}

rect_xy :: proc(x, y, w, h: f32) {
	rect_v({x, y}, {w, h})
}

bezier :: proc {
	bezier_xy,
	bezier_v,
}

bezier_v :: proc(a, ctrl1, ctrl2, b: Vec2) {
	p0 := apply(a)
	p1 := apply(ctrl1)
	p2 := apply(ctrl2)
	p3 := apply(b)
	// Uniform subdivision into n parts errs by at most 3*d/(4*n^2), where d is
	// the largest second difference of the control points (Wang's bound)
	d := max(linalg.length(p0 - 2 * p1 + p2), linalg.length(p1 - 2 * p2 + p3))
	n := clamp(int(math.ceil(math.sqrt(3 * d / (4 * FLATTEN_TOLERANCE)))), 1, 1024)
	pts := make([]Vec2, n + 1, context.temp_allocator)
	for i in 0 ..= n {
		t := f32(i) / f32(n)
		u := 1 - t
		pts[i] = u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3
	}
	record(Polyline{pts, false})
}

bezier_xy :: proc(x1, y1, cx1, cy1, cx2, cy2, x2, y2: f32) {
	bezier_v({x1, y1}, {cx1, cy1}, {cx2, cy2}, {x2, y2})
}

BezierIter :: struct {
	a, c1, c2, b: Vec2,
	total: f32,
	next_t: f32,
}

// Pen-down dots every gap units along the segment, endpoints included
dotted_line :: proc {
	dotted_line_xy,
	dotted_line_v,
}

dotted_line_v :: proc(a, b: Vec2, gap: f32) {
	n := max(int(linalg.distance(a, b) / gap), 1)
	for i in 0 ..= n {
		point_v(a + (b - a) * (f32(i) / f32(n)))
	}
}

dotted_line_xy :: proc(x1, y1, x2, y2, gap: f32) {
	dotted_line_v({x1, y1}, {x2, y2}, gap)
}

// Records a caller-built point list (e.g. from smooth or simplify) as one
// polyline; the points are copied, so any allocation may back the input
polyline :: proc(points: []Vec2, closed := false) {
	if len(points) < 2 {
		return
	}
	pts := make([]Vec2, len(points), context.temp_allocator)
	for p, i in points {
		pts[i] = apply(p)
	}
	record(Polyline{pts, closed})
}

begin_shape :: proc() {
	clear(&canvas.verts)
}

vertex :: proc {
	vertex_xy,
	vertex_v,
}

vertex_v :: proc(p: Vec2) {
	append(&canvas.verts, apply(p))
}

vertex_xy :: proc(x, y: f32) {
	vertex_v({x, y})
}

end_shape :: proc(close := false) {
	if len(canvas.verts) >= 2 {
		pts := slice.clone(canvas.verts[:], context.temp_allocator)
		record(Polyline{pts, close})
	}
}

// Preview rendering

render_shapes :: proc() {
	for shape in canvas.shapes {
		color := rl.Color{shape.color.r, shape.color.g, shape.color.b, 255}
		w := shape.weight
		half := w / 2
		switch s in shape.geom {
		case Line:
			rl.DrawLineEx(s.a, s.b, w, color)
			rl.DrawCircleV(s.a, half, color) // round caps, matching the SVG
			rl.DrawCircleV(s.b, half, color)
		case Circle:
			rl.DrawRing(s.center, max(s.r - half, 0), s.r + half, 0, 360, i32(circle_segments(s.r + half)), color)
		case Polyline:
			for i in 0 ..< len(s.points) - 1 {
				rl.DrawLineEx(s.points[i], s.points[i + 1], w, color)
			}
			if s.closed {
				rl.DrawLineEx(s.points[len(s.points) - 1], s.points[0], w, color)
			}
			for p in s.points {
				rl.DrawCircleV(p, half, color)
			}
		}
	}
}
