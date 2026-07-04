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

BEZIER_SEGMENTS :: 32
ELLIPSE_SEGMENTS :: 64
DEFAULT_STROKE :: f32(1.5)

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
	pen: int, // carousel slot 1-8
	weight: f32,
}

// Preview colors per carousel slot, index 0 unused
PEN_COLORS := [9]rl.Color{
	rl.BLACK,
	rl.BLACK,
	rl.RED,
	rl.BLUE,
	rl.DARKGREEN,
	rl.ORANGE,
	rl.DARKPURPLE,
	rl.BROWN,
	rl.MAGENTA,
}

// SVG stroke per carousel slot, mirrors PEN_COLORS
PEN_SVG_COLORS := [9]string{
	"black",
	"black",
	"red",
	"blue",
	"green",
	"darkorange",
	"purple",
	"saddlebrown",
	"magenta",
}

Canvas :: struct {
	width, height: f32,
	frame: int,
	seed: u64,
	stroke: f32,
	cur_pen: int,
	shapes: [dynamic]Shape,
	xform: Mat,
	xform_stack: [dynamic]Mat,
	verts: [dynamic]Vec2,
}

// Opens the preview window and calls draw_proc once per frame. The canvas is
// cleared before every call, so draw_proc re-records the whole frame each time.
// With loop = false, draw_proc runs once and the recorded shapes are re-rendered
// until R rerolls the seed and triggers a redraw.
// Keys: S exports the current frame as SVG, R rerolls the random seed.
run :: proc(width, height: int, title: string, draw_proc: proc(c: ^Canvas), loop := true) {
	rl.SetConfigFlags({.WINDOW_HIGHDPI, .MSAA_4X_HINT})
	rl.InitWindow(i32(width), i32(height), fmt.ctprintf("%s | S: save svg, R: reseed", title))
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	c: Canvas
	c.width = f32(width)
	c.height = f32(height)
	c.seed = u64(time.now()._nsec)

	needs_draw := true

	for !rl.WindowShouldClose() {
		if rl.IsKeyPressed(.R) {
			c.seed += 1
			needs_draw = true
			rl.SetWindowTitle(fmt.ctprintf("%s | seed %d | S: save svg, R: reseed", title, c.seed))
		}

		if loop || needs_draw {
			// Recorded shapes live on the temp allocator, so it is only safe
			// to free once we are about to re-record the frame
			free_all(context.temp_allocator)
			canvas_reset(&c)
			rand.reset(c.seed) // deterministic per frame, so the preview holds still until reseeded
			draw_proc(&c)
			needs_draw = false
		}

		rl.BeginDrawing()
		rl.ClearBackground(rl.WHITE)
		render_shapes(&c)
		rl.EndDrawing()

		if rl.IsKeyPressed(.S) {
			export_svg(&c)
		}
		c.frame += 1
	}
}

// Clears all recording state onto a fresh temp-allocator frame. run calls this
// every frame; call it yourself if driving a Canvas without a window
canvas_reset :: proc(c: ^Canvas) {
	c.shapes = make([dynamic]Shape, context.temp_allocator)
	c.xform_stack = make([dynamic]Mat, context.temp_allocator)
	c.verts = make([dynamic]Vec2, context.temp_allocator)
	c.xform = 1
	c.stroke = DEFAULT_STROKE
	c.cur_pen = 1
}

// Transforms

push_matrix :: proc(c: ^Canvas) {
	append(&c.xform_stack, c.xform)
}

pop_matrix :: proc(c: ^Canvas) {
	c.xform = pop(&c.xform_stack)
}

translate :: proc(c: ^Canvas, x, y: f32) {
	c.xform *= Mat{1, 0, x, 0, 1, y, 0, 0, 1}
}

rotate :: proc(c: ^Canvas, radians: f32) {
	co := math.cos(radians)
	si := math.sin(radians)
	c.xform *= Mat{co, -si, 0, si, co, 0, 0, 0, 1}
}

scale :: proc(c: ^Canvas, sx: f32, sy := f32(0)) {
	sy := sy if sy != 0 else sx
	c.xform *= Mat{sx, 0, 0, 0, sy, 0, 0, 0, 1}
}

// Bakes the current transform into a point. Every shape proc routes its
// coordinates through this, so recorded shapes are always in canvas space.
apply :: proc(c: ^Canvas, p: Vec2) -> Vec2 {
	v := c.xform * [3]f32{p.x, p.y, 1}
	return v.xy
}

// Shapes

stroke_weight :: proc(c: ^Canvas, w: f32) {
	c.stroke = w
}

// Selects the carousel pen (1-8) for subsequent shapes
pen :: proc(c: ^Canvas, n: int) {
	c.cur_pen = clamp(n, 1, 8)
}

record :: proc(c: ^Canvas, g: Geom) {
	append(&c.shapes, Shape{g, c.cur_pen, c.stroke})
}

// Every primitive is a proc group: pass expanded coordinates or Vec2s

line :: proc {
	line_xy,
	line_v,
}

line_v :: proc(c: ^Canvas, a, b: Vec2) {
	record(c, Line{apply(c, a), apply(c, b)})
}

line_xy :: proc(c: ^Canvas, x1, y1, x2, y2: f32) {
	line_v(c, {x1, y1}, {x2, y2})
}

// A pen dot: exported as a zero-length line, which svg2hpgl turns into a pen-down dot
point :: proc {
	point_xy,
	point_v,
}

point_v :: proc(c: ^Canvas, pt: Vec2) {
	p := apply(c, pt)
	record(c, Line{p, p})
}

point_xy :: proc(c: ^Canvas, x, y: f32) {
	point_v(c, {x, y})
}

// Radius follows uniform scale (sqrt of the transform determinant); use ellipse under nonuniform scale
circle :: proc {
	circle_xy,
	circle_v,
}

circle_v :: proc(c: ^Canvas, center: Vec2, r: f32) {
	s := math.sqrt(abs(c.xform[0, 0] * c.xform[1, 1] - c.xform[0, 1] * c.xform[1, 0]))
	record(c, Circle{apply(c, center), r * s})
}

circle_xy :: proc(c: ^Canvas, x, y, r: f32) {
	circle_v(c, {x, y}, r)
}

// Flattened to a closed polyline so arbitrary transforms (rotation, shear) stay correct
ellipse :: proc {
	ellipse_xy,
	ellipse_v,
}

ellipse_v :: proc(c: ^Canvas, center: Vec2, rx, ry: f32) {
	pts := make([]Vec2, ELLIPSE_SEGMENTS, context.temp_allocator)
	for i in 0 ..< ELLIPSE_SEGMENTS {
		t := f32(i) / ELLIPSE_SEGMENTS * math.TAU
		pts[i] = apply(c, center + {rx * math.cos(t), ry * math.sin(t)})
	}
	record(c, Polyline{pts, true})
}

ellipse_xy :: proc(c: ^Canvas, x, y, rx, ry: f32) {
	ellipse_v(c, {x, y}, rx, ry)
}

// Circular arc from start_angle to end_angle in radians, flattened to an open
// polyline; sweeps backwards when end_angle < start_angle
arc :: proc {
	arc_xy,
	arc_v,
}

arc_v :: proc(c: ^Canvas, center: Vec2, r, start_angle, end_angle: f32) {
	span := end_angle - start_angle
	n := max(int(f32(ELLIPSE_SEGMENTS) * abs(span) / math.TAU), 1)
	pts := make([]Vec2, n + 1, context.temp_allocator)
	for i in 0 ..= n {
		t := start_angle + span * f32(i) / f32(n)
		pts[i] = apply(c, center + {r * math.cos(t), r * math.sin(t)})
	}
	record(c, Polyline{pts, false})
}

arc_xy :: proc(c: ^Canvas, x, y, r, start_angle, end_angle: f32) {
	arc_v(c, {x, y}, r, start_angle, end_angle)
}

rect :: proc {
	rect_xy,
	rect_v,
}

rect_v :: proc(c: ^Canvas, pos, size: Vec2) {
	pts := make([]Vec2, 4, context.temp_allocator)
	pts[0] = apply(c, pos)
	pts[1] = apply(c, pos + {size.x, 0})
	pts[2] = apply(c, pos + size)
	pts[3] = apply(c, pos + {0, size.y})
	record(c, Polyline{pts, true})
}

rect_xy :: proc(c: ^Canvas, x, y, w, h: f32) {
	rect_v(c, {x, y}, {w, h})
}

bezier :: proc {
	bezier_xy,
	bezier_v,
}

bezier_v :: proc(c: ^Canvas, a, ctrl1, ctrl2, b: Vec2) {
	p0 := apply(c, a)
	p1 := apply(c, ctrl1)
	p2 := apply(c, ctrl2)
	p3 := apply(c, b)
	pts := make([]Vec2, BEZIER_SEGMENTS + 1, context.temp_allocator)
	for i in 0 ..= BEZIER_SEGMENTS {
		t := f32(i) / BEZIER_SEGMENTS
		u := 1 - t
		pts[i] = u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3
	}
	record(c, Polyline{pts, false})
}

bezier_xy :: proc(c: ^Canvas, x1, y1, cx1, cy1, cx2, cy2, x2, y2: f32) {
	bezier_v(c, {x1, y1}, {cx1, cy1}, {cx2, cy2}, {x2, y2})
}

// Pen-down dots every gap units along the segment, endpoints included
dotted_line :: proc {
	dotted_line_xy,
	dotted_line_v,
}

dotted_line_v :: proc(c: ^Canvas, a, b: Vec2, gap: f32) {
	n := max(int(linalg.distance(a, b) / gap), 1)
	for i in 0 ..= n {
		point_v(c, a + (b - a) * (f32(i) / f32(n)))
	}
}

dotted_line_xy :: proc(c: ^Canvas, x1, y1, x2, y2, gap: f32) {
	dotted_line_v(c, {x1, y1}, {x2, y2}, gap)
}

// Records a caller-built point list (e.g. from smooth or simplify) as one
// polyline; the points are copied, so any allocation may back the input
polyline :: proc(c: ^Canvas, points: []Vec2, closed := false) {
	if len(points) < 2 {
		return
	}
	pts := make([]Vec2, len(points), context.temp_allocator)
	for p, i in points {
		pts[i] = apply(c, p)
	}
	record(c, Polyline{pts, closed})
}

begin_shape :: proc(c: ^Canvas) {
	clear(&c.verts)
}

vertex :: proc {
	vertex_xy,
	vertex_v,
}

vertex_v :: proc(c: ^Canvas, p: Vec2) {
	append(&c.verts, apply(c, p))
}

vertex_xy :: proc(c: ^Canvas, x, y: f32) {
	vertex_v(c, {x, y})
}

end_shape :: proc(c: ^Canvas, close := false) {
	if len(c.verts) >= 2 {
		pts := slice.clone(c.verts[:], context.temp_allocator)
		record(c, Polyline{pts, close})
	}
}

// Preview rendering

render_shapes :: proc(c: ^Canvas) {
	for shape in c.shapes {
		color := PEN_COLORS[shape.pen]
		w := shape.weight
		half := w / 2
		switch s in shape.geom {
		case Line:
			rl.DrawLineEx(s.a, s.b, w, color)
			rl.DrawCircleV(s.a, half, color) // round caps, matching the SVG
			rl.DrawCircleV(s.b, half, color)
		case Circle:
			rl.DrawRing(s.center, max(s.r - half, 0), s.r + half, 0, 360, 96, color)
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
