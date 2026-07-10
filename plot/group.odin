package plot

// While a group is open, shapes and clip pushes are captured instead of
// executed, so a sketch can build depth-sortable chunks in any order and
// replay them front to back. A replayed group's own occluders go live for
// everything replayed after it -- hidden-line removal without generating in
// draw order. Replay a group at most once per frame: twice re-pushes its
// occluders and double-inks its strokes.

Group :: struct {
	ops: [dynamic]Group_Op,
}

Group_Op :: union {
	Shape,
	Clip,
	Pop_Clip,
}

Pop_Clip :: struct {}

// No nesting
begin_group :: proc() {
	assert(canvas.group == nil)
	canvas.group = new(Group, context.temp_allocator)
	canvas.group.ops = make([dynamic]Group_Op, context.temp_allocator)
}

end_group :: proc() -> ^Group {
	assert(canvas.group != nil)
	g := canvas.group
	canvas.group = nil
	return g
}

draw_group :: proc(g: ^Group) {
	assert(canvas.group == nil)
	col := canvas.color
	w := canvas.weight
	for op in g.ops {
		switch o in op {
		case Shape:
			canvas.color = o.color
			canvas.weight = o.weight
			record(o.geom)
		case Clip:
			append(&canvas.clips, o)
		case Pop_Clip:
			pop(&canvas.clips)
		}
	}
	canvas.color = col
	canvas.weight = w
}
