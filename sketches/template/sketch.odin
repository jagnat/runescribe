#+feature using-stmt
package sketch

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

	r := p.param("radius", 200, 10, 290)
	p.circle(canvas.width / 2, canvas.height / 2, r)
}
