#+feature using-stmt
package sketch

import p "../../plot"
import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:math/linalg"

Vec2 :: p.Vec2
Vec3 :: [3]f32

COS30 :: 0.86602540378
SIN30 :: 0.5

SCALE :: 20 // pixels per unit cell

origin: Vec2

to_screen :: proc(c: Vec3) -> Vec2 {
	return {origin.x + (c.x - c.y) * COS30 * SCALE,
	origin.y + (c.x + c.y) * SIN30 * SCALE - c.z * SCALE }
}

main :: proc() {
	p.run(600, 600, "sketch", draw, loop = false)
}

box_faces :: proc(pos, bounds: Vec3) -> [3][4]Vec3 {
	x0, x1 := pos.x, pos.x + bounds.x
	y0, y1 := pos.y, pos.y + bounds.y
	z0, z1 := pos.z, pos.z + bounds.z
	return {
		{{x0, y0, z1}, {x1, y0, z1}, {x1, y1, z1}, {x0, y1, z1}}, // Top +Z
		{{x1, y0, z0}, {x1, y1, z0}, {x1, y1, z1}, {x1, y0, z1}}, // Right +X
		{{x0, y1, z0}, {x1, y1, z0}, {x1, y1, z1}, {x0, y1, z1}}, // Left +Y
	}
}

draw_box :: proc(point, bounds: Vec3) {
	for verts in box_faces(point, bounds) {
		two_d: [4]Vec2
		for pt, i in verts {
			two_d[i] = to_screen(pt)
		}
		p.polyline(two_d[:], true)
	}
}

draw_cube :: proc(c: Vec3) {
	draw_box(c, {1, 1, 1})
}

draw :: proc() {
	origin = {p.canvas.width / 2, p.canvas.height / 2}
	draw_box({0, 0, 0}, {2, 3, 5})
	draw_cube({0, 0, 0})
}

