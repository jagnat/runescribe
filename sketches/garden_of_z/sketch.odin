#+feature using-stmt
package sketch

import p "../../plot"
import "core:math"
import "core:fmt"
import "core:math/rand"
import "core:math/linalg"

Vec2 :: p.Vec2

main :: proc() {
	p.run(600, 600, "sketch", draw, loop = false)
}

draw :: proc() {
	using p;

	center :Vec2= {canvas.width / 2, canvas.height / 2}

	ang :f32= 0.123456789
	size := canvas.width - 10
	for size > 10 {
		half := size / 2
		//p.push_clip_circle(center, size / 2, )
		r := rand.float32()
		if r < 0.15 {
			p.stroke(p.GREEN)
		} else if r < 0.3 { 
			p.stroke(p.BLUE)
		} else {
			p.stroke(p.BLACK)
		}
		p.hatch_circle(center.x, center.y, half, 40, ang)
		//p.circle(center, size / 2)
		size -= 20
		ang += 0.08
	}
}
