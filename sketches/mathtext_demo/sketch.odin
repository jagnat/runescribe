#+feature using-stmt
package sketch

import p "../../plot"

main :: proc() {
	p.run(900, 620, "mathtext demo", draw, loop = false)
}

draw :: proc() {
	using p;

	s := p.param("size", 30, 10, 60)
	x := f32(60)
	p.math_text("X_k = \\sum_{n=0}^{N-1} x_n e^{-i2\\pi kn/N}", x, 130, s)
	p.math_text("x_n = N^{-1} \\sum_{k=0}^{N-1} X_k e^{i2\\pi kn/N}", x, 260, s)
	p.math_text("\\omega_k = 2\\pi k/N", x, 370, s)
	p.math_text("e^{i\\omega n} = cos(\\omega n) + i sin(\\omega n)", x, 450, s)
	p.math_text("|X_k|^2 = a_k^2 + b_k^2 \\approx \\sigma^2", x, 530, s)
}
