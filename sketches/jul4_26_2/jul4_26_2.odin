#+feature using-stmt
package j3263

import p "../../plot"
import "core:math"
import "core:fmt"
import "core:math/rand"
import "core:math/linalg"

main :: proc() {
	p.run(600, 600, "sketch", draw, loop = false)
}

draw :: proc() {
	using p;
	center: Vec2 = {canvas.width / 2, canvas.height / 2}
	SYMM :: 12
	for j in 0 ..< SYMM {
		ang_start := f32(j) / SYMM * 2 * math.PI
		ang_end := f32(j + 1) / SYMM * 2 * math.PI
		ang_mid := (ang_start + ang_end) / 2

		x := center.x + math.cos(ang_mid) * 200
		y := center.y + math.sin(ang_mid) * 200
		circle(x, y, 20)
		line(center, {center.x + math.cos(ang_start) * 200, center.y + math.sin(ang_mid) * 200})
	}
}
