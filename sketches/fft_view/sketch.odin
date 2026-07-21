#+feature using-stmt
package sketch

import p "../../plot"
import "base:intrinsics"
import "core:math"
import "core:fmt"
import "core:math/rand"
import "core:math/linalg"
import "core:math/cmplx"
import "core:slice"

Vec2 :: p.Vec2

main :: proc() {
	p.run(1400, 750, "sketch", draw)
}

FFT_SIZE :: 8
PageProc :: #type proc()
pages := []PageProc{draw_page_0, draw_page_1, draw_page_2, draw_page_3, draw_page_4}

signal: [FFT_SIZE]complex64

SignalType :: enum {
	SINE,
	COS,
	SQUARE,
	SAW,
	DC,
	IMPULSE,
}

draw :: proc() {
	page := p.param_int("page", 0, 0, len(pages) - 1)
	wave := p.param_enum("wave", SignalType.SQUARE)
	freq := p.param_int("freq", 1, 0, FFT_SIZE / 2)
	gen_wave(wave, freq)
	if page < len(pages) && pages[page] != nil {
pages[page]()
	}
}

gen_wave :: proc(type: SignalType, freq: int) {
	for i in 0..<FFT_SIZE {
		t := f32(i) / FFT_SIZE
		phase := t * f32(freq) * 2 * math.PI
		v: f32
		switch type {
		case .SINE: v = math.sin_f32(phase)
		case .COS: v = math.cos_f32(phase)
		case .SQUARE: v = math.sin_f32(phase) >= 0 ? 1 : -1
		case .SAW:v = ((t * f32(freq)) - math.floor(t* f32(freq))) * 2 - 1
		case .DC: v = 1
		case .IMPULSE: v = i == 2 ? 1 : 0
		}
		signal[i] = complex(v, 0)
	}
}


// page 0: intro, summing waves, cochlear
// page 1: input signal, dft eq, wave summing
// page 2: showing the matrix thing
// page 3: butterfly

draw_page_0 :: proc() {
	p.stroke_weight(4)
	p.text("Going in circles with the FFT", 300, 50, 32)
	p.stroke_weight(2)
	p.text("jagi 'S1", 1000, 50, 22)

	stage := p.param_int("next_0", 0, 0, 4)

	if stage > 0 {
		p.text("What is fourier analysis?", 400, 170, 22)
	}
	if stage > 1 {
		draw_square_synthesis({400, 270})
	}
	if stage > 2 {
		p.stroke_weight(2)
		p.text("Fourier Transform: Time => Frequency", 150, 380, 22)
		draw_square_synthesis({10, 500}, skip_harmonics = true)
		p.text("=>", 650, 500, 50)
		draw_spectrum({760, 500})
	}
	if stage > 3 {
		draw_cochlea({1200, 250}, 120)
	}
}

draw_cochlea :: proc(pos: Vec2, size: f32) {
	N :: 220
	TURNS :: f32(2.75)
	GROWTH :: f32(2.1) // radius multiplier per turn
	k := math.ln(GROWTH) / math.TAU
	theta_max := TURNS * math.TAU

	spine := make([]Vec2, N + 1, context.temp_allocator)
	widths := make([]f32, N + 1, context.temp_allocator)
	for i in 0 ..= N {
		theta := f32(i) / N * theta_max
		r := size * math.exp(k * (theta - theta_max))
		spine[i] = pos + {r * math.cos(theta), r * math.sin(theta)}
		widths[i] = r * 0.45
	}

	wall := p.offset(spine, widths)

	p.stroke(u8(0))
	p.stroke_weight(2)
	p.polyline(spine)
	p.polyline(wall)

	// hair cells along the basilar membrane
	p.stroke(200)
	p.stroke_weight(1)
	for i := 1; i < N; i += 1 {
		p.line(spine[i], spine[i] + (wall[i] - spine[i]) * 0.8)
	}

	p.stroke(u8(0))
	p.stroke_weight(2)
	p.circle_v(pos, size * math.exp(-k * theta_max) * 0.5) // helicotrema at the apex
}

SYNTH_HARMONICS :: 8

synth_comps :: proc() -> f32 {
	PERIOD :: f32(10)
	LOW :: f32(0.5)
	t := f32(p.canvas.frame) / 60
	phase := t / PERIOD
	phase -= math.floor(phase)
	tri := 1 - abs(2 * phase - 1) // 0 -> 1 -> 0
	return LOW + tri * (f32(SYNTH_HARMONICS) - LOW)
}

draw_square_synthesis :: proc(tx: Vec2, skip_harmonics: bool = false) {
	W :: f32(620)
	AMP :: f32(54)
	SAMPLES :: 160

	comps := synth_comps()

	harmonic :: proc(k: f32, weight, u: f32) -> f32 {
		return weight * (4 / math.PI) * math.sin(math.TAU * k * u) / k
	}

	p.push_matrix()
	// p.translate(10, 270)
	p.translate(tx.x, tx.y)

	if !skip_harmonics {
		p.stroke(u8(210))
		p.stroke_weight(1)
		p.line(0, 0, W, 0)
	}

	for i in 0 ..< SYNTH_HARMONICS {
		weight := clamp(comps - f32(i), 0, 1)
		if weight <= 0 {
			break
		}
		k := f32(2 * i + 1)
		if !skip_harmonics {
			p.stroke(u8(225 - weight * 90)) // white -> gray as it fades in
			p.stroke_weight(1)
			p.begin_shape()
			for s in 0 ..= SAMPLES {
				u := f32(s) / SAMPLES
				p.vertex(u * W, -harmonic(k, weight, u) * AMP)
			}
			p.end_shape()
		}
	}

	p.stroke(u8(0))
	p.stroke_weight(2.5)
	p.begin_shape()
	for s in 0 ..= SAMPLES {
		u := f32(s) / SAMPLES
		y: f32
		for i in 0 ..< SYNTH_HARMONICS {
			weight := clamp(comps - f32(i), 0, 1)
			if weight <= 0 {
				break
			}
			y += harmonic(f32(2 * i + 1), weight, u)
		}
		p.vertex(u * W, -y * AMP)
	}
	p.end_shape()

	p.pop_matrix()
}

draw_spectrum :: proc(tx: Vec2) {
	W :: f32(480)
	BINS :: 16
	SPEC_TOP :: f32(90)

	comps := synth_comps()
	p.push_matrix()
	p.translate(tx.x, tx.y)

	p.stroke(u8(0))
	p.stroke_weight(2)
	p.line(0, 0, W, 0)

	for i in 0 ..< SYNTH_HARMONICS {
		weight := clamp(comps - f32(i), 0, 1)
		if weight <= 0 {
			break
		}
		k := 2 * i + 1
		x := f32(k) / BINS * W
		h := weight * SPEC_TOP / f32(k)
		p.stroke_weight(2)
		p.line(x, 0, x, -h)
		p.stroke_weight(6)
		p.point(x, -h)
	}

	p.pop_matrix()
}

CURRENT :: p.BLUE

WAVE_X :: f32(10)
WAVE_Y :: f32(230)
GRAPH_WIDTH :: f32(400)
GRAPH_HEIGHT :: f32(100)

wave_point :: proc(n: int) -> Vec2 {
	return Vec2{WAVE_X + (f32(n) / FFT_SIZE) * GRAPH_WIDTH, WAVE_Y - real(signal[n]) * GRAPH_HEIGHT / 2}
}

draw_page_1 :: proc() {
	// draw signal input
	stage := p.param_int("next_1", 0, 0, 2)

	PERIOD :: f32(4)
	tt := f32(p.canvas.frame) / 60 / PERIOD
	tt -= math.floor(tt)
	cursor := min(tt * 1.15, f32(1)) * f32(FFT_SIZE)
	n_cur := int(cursor)

	p.push_matrix()
	p.translate(WAVE_X, WAVE_Y)
	p.stroke_weight(2)
	p.text("input wave", {0, -GRAPH_HEIGHT / 2- 16}, 22)
	p.line(0, 0, GRAPH_WIDTH, 0)
	p.line(0, GRAPH_HEIGHT / 2, 0, -GRAPH_HEIGHT / 2)
	for i in 0..< FFT_SIZE {
		x := (f32(i) / FFT_SIZE) * GRAPH_WIDTH
		v := real(signal[i])
		h := v * GRAPH_HEIGHT / 2
		p.line(x, 0, x, -h)
		p.stroke(i == n_cur ? CURRENT : p.BLACK)
		p.stroke_weight(i == n_cur ? 8 : 5)
		p.point(x, -h)
		lbl := fmt.tprintf("%d", i)
		p.stroke(i == n_cur ? CURRENT : p.Color{170, 170, 170})
		p.stroke_weight(1)
		p.text(lbl, Vec2{x - p.text_width(lbl, 14) / 2, GRAPH_HEIGHT / 2 + 22}, 14)
		p.stroke(0)
		p.stroke_weight(2)
	}
	p.pop_matrix()

	if stage == 1 {
		draw_phasor({800, 400}, 180, 1, cursor, true)
	}
	if stage >= 2 {
		for k in 0 ..< FFT_SIZE {
			draw_phasor({130 + f32(k) * 165, 560}, 60, k, cursor)
		}
		eq := "X_k = \\sum_{n=0}^{N-1} x_n e^{-i2\\pi kn/N}"
		p.stroke(u8(0))
		p.stroke_weight(2)
		p.math_text(eq, 910 - p.math_text_width(eq, 34) / 2, 300, 34)
	}

	t: [FFT_SIZE]complex64
	compute_twiddles(t[:])

	naive_mat := make_mat(FFT_SIZE, FFT_SIZE)

	slice0 := slice.clone(signal[:])

	smooth_brain_dft(slice0, naive_mat)

	radix2_fft(signal[:])
	mag := [FFT_SIZE]f32{}
	for i in 0..<FFT_SIZE {
		mag[i] = abs(signal[i])
	}

	if stage >= 2 {
		p.push_matrix()
		p.translate(10, 450)
		p.stroke(0)
		p.stroke_weight(2)
		p.text("output frequencies", 0, -80, 22)
		p.line(0, 0, GRAPH_WIDTH, 0)
		p.line(0, GRAPH_HEIGHT / 2, 0, -GRAPH_HEIGHT / 2)
		for i in 0..<FFT_SIZE {
			x := (f32(i) / FFT_SIZE) * GRAPH_WIDTH
			h := mag[i] / f32(FFT_SIZE) * GRAPH_HEIGHT
			p.line(x, 0, x, -h)
			p.stroke_weight(5)
			p.point(x, -h)
			p.stroke_weight(2)
		}
		p.pop_matrix()
	}
}

MAT_X :: f32(450)
MAT_Y :: f32(160)
MAT_CELL :: f32(70)
MAT_R :: f32(26)

mat_center :: proc(k, n: int) -> Vec2 {
	return Vec2{MAT_X + f32(n) * MAT_CELL, MAT_Y + f32(k) * MAT_CELL}
}

title_text :: proc(str: string, y, size: f32) {
	p.text(str, Vec2{(p.canvas.width - p.text_width(str, size)) / 2, y}, size)
}

draw_page_2 :: proc() {
	stage := p.param_int("next_2", 0, 0, 1)

	p.stroke(u8(0))
	p.stroke_weight(2)
	p.text("every output, every sample", 420, 30, 26)
	p.text("sample n", MAT_X - 10, MAT_Y - MAT_R - 46, 20)
	p.text("freq k", MAT_X - 160, MAT_Y + 10, 20)

	eq_x := mat_center(0, FFT_SIZE - 1).x + MAT_R + 44
	p.math_text("X = Wx", eq_x, 260, 34)
	p.math_text("W_{kn} = \\omega^{kn}", eq_x, 330, 28)
	p.stroke(u8(120))
	p.stroke_weight(1)
	p.math_text("\\omega = e^{-i2\\pi/N}", eq_x, 390, 22)

	p.stroke(u8(120))
	p.stroke_weight(1)
	for n in 0 ..< FFT_SIZE {
		lbl := fmt.tprintf("%d", n)
		c := mat_center(0, n)
		p.text(lbl, Vec2{c.x - p.text_width(lbl, 16) / 2, MAT_Y - MAT_R - 16}, 16)
	}
	for k in 0 ..< FFT_SIZE {
		lbl := fmt.tprintf("k=%d", k)
		c := mat_center(k, 0)
		p.text(lbl, Vec2{MAT_X - MAT_R - 16 - p.text_width(lbl, 16), c.y + 5}, 16)
	}

	for k in 0 ..< FFT_SIZE {
		for n in 0 ..< FFT_SIZE {
			c := mat_center(k, n)
			d := slot_dir((k * n) % FFT_SIZE)
			p.stroke(u8(225))
			p.stroke_weight(1)
			p.circle_v(c, MAT_R)
			p.stroke(u8(0))
			p.stroke_weight(2)
			p.line(c.x, c.y, c.x + d.x * MAT_R, c.y + d.y * MAT_R)
		}
	}

	if stage >= 1 {
		row := p.param_int("row", 2, 0, FFT_SIZE - 1)
		for n in 0 ..< FFT_SIZE {
			c := mat_center(row, n)
			tip := c + slot_dir((row * n) % FFT_SIZE) * MAT_R
			p.stroke(CURRENT)
			p.stroke_weight(4)
			p.line(c.x, c.y, tip.x, tip.y)
			p.stroke_weight(8)
			p.point(tip.x, tip.y)
		}
	}
}

MAT3_X :: f32(420)
MAT_GAP :: f32(44)

split_sample :: proc(col: int) -> int {
	return col < FFT_SIZE / 2 ? col * 2 : (col - FFT_SIZE / 2) * 2 + 1
}

mat3_center :: proc(k, col: int) -> Vec2 {
	gap := col < FFT_SIZE / 2 ? f32(0) : MAT_GAP
	return Vec2{MAT3_X + f32(col) * MAT_CELL + gap, MAT_Y + f32(k) * MAT_CELL}
}

draw_split_row :: proc(k: int, tint: p.Color) {
	for col in 0 ..< FFT_SIZE {
		c := mat3_center(k, col)
		tip := c + slot_dir((k * split_sample(col)) % FFT_SIZE) * MAT_R
		p.stroke(tint)
		p.stroke_weight(4)
		p.line(c.x, c.y, tip.x, tip.y)
		p.stroke_weight(8)
		p.point(tip.x, tip.y)
	}
}

draw_page_3 :: proc() {
	stage := p.param_int("next_3", 0, 0, 2)

	p.stroke(u8(0))
	p.stroke_weight(2)
	title_text("split by evens and odds", 40, 26)

	p.stroke(u8(120))
	p.stroke_weight(1)
	p.text("even samples", Vec2{mat3_center(0, 0).x - MAT_R, MAT_Y - MAT_R - 44}, 20)
	p.text("odd samples", Vec2{mat3_center(0, FFT_SIZE / 2).x - MAT_R, MAT_Y - MAT_R - 44}, 20)

	for col in 0 ..< FFT_SIZE {
		lbl := fmt.tprintf("%d", split_sample(col))
		c := mat3_center(0, col)
		p.text(lbl, Vec2{c.x - p.text_width(lbl, 16) / 2, MAT_Y - MAT_R - 16}, 16)
	}
	for k in 0 ..< FFT_SIZE {
		lbl := fmt.tprintf("k=%d", k)
		c := mat3_center(k, 0)
		p.text(lbl, Vec2{MAT3_X - MAT_R - 16 - p.text_width(lbl, 16), c.y + 5}, 16)
	}

	for k in 0 ..< FFT_SIZE {
		for col in 0 ..< FFT_SIZE {
			c := mat3_center(k, col)
			d := slot_dir((k * split_sample(col)) % FFT_SIZE)
			p.stroke(u8(225))
			p.stroke_weight(1)
			p.circle_v(c, MAT_R)
			p.stroke(u8(0))
			p.stroke_weight(2)
			p.line(c.x, c.y, c.x + d.x * MAT_R, c.y + d.y * MAT_R)
		}
	}

	krow := p.param_int("krow", 1, 0, FFT_SIZE / 2 - 1)
	if stage >= 1 {
		draw_split_row(krow, CURRENT)
		draw_split_row(krow + FFT_SIZE / 2, p.ORANGE)
	}

	if stage >= 2 {
		eq_x := mat3_center(0, FFT_SIZE - 1).x + MAT_R + 30
		p.stroke_weight(2)
		p.stroke(CURRENT)
		p.math_text("X_k = E_k + \\omega^k O_k", eq_x, mat3_center(krow, 0).y + 8, 26)
		p.stroke(p.ORANGE)
		p.math_text("X_{k+N/2} = E_k - \\omega^k O_k", eq_x, mat3_center(krow + FFT_SIZE / 2, 0).y + 8, 26)
	}
}

FFT_BITS :: 3

bitrev_index :: proc(v: int) -> int {
	r := 0
	for i in 0 ..< FFT_BITS {
		if v & (1 << uint(i)) != 0 {
			r |= 1 << uint(FFT_BITS - 1 - i)
		}
	}
	return r
}

draw_butterfly :: proc() {
	e := Vec2{400, 250}
	o := Vec2{400, 470}
	m := Vec2{640, 470}
	xk := Vec2{900, 250}
	xn := Vec2{900, 470}

	p.stroke(u8(0))
	p.stroke_weight(2)
	p.line(e, xk)
	p.line(e, xn)
	p.line(o, m)
	p.line(m, xk)
	p.line(m, xn)

	p.stroke(u8(120))
	p.stroke_weight(2)
	p.circle_v(m, 18)
	p.stroke(u8(0))
	p.math_text("\\omega^k", m.x - 20, m.y + 52, 26)

	p.stroke_weight(9)
	p.point(e.x, e.y)
	p.point(o.x, o.y)

	p.stroke_weight(2)
	p.math_text("E_k", e.x - 74, e.y + 8, 28)
	p.math_text("O_k", o.x - 74, o.y + 8, 28)
	p.text("+", xk.x - 54, xk.y - 16, 28)
	p.text("-", xn.x - 72, xn.y - 16, 28)

	p.stroke(CURRENT)
	p.stroke_weight(9)
	p.point(xk.x, xk.y)
	p.stroke_weight(2)
	p.math_text("X_k = E_k + \\omega^k O_k", xk.x + 34, xk.y + 8, 26)

	p.stroke(p.ORANGE)
	p.stroke_weight(9)
	p.point(xn.x, xn.y)
	p.stroke_weight(2)
	p.math_text("X_{k+N/2} = E_k - \\omega^k O_k", xn.x + 34, xn.y + 8, 26)
}

TR_X0 :: f32(360)
TR_DX :: f32(230)
TR_Y0 :: f32(150)
TR_DY :: f32(62)

trellis_pt :: proc(col, row: int) -> Vec2 {
	return Vec2{TR_X0 + f32(col) * TR_DX, TR_Y0 + f32(row) * TR_DY}
}

draw_trellis :: proc() {
	p.stroke(u8(0))
	p.stroke_weight(2)
	for s in 0 ..< FFT_BITS {
		span := 1 << uint(s)
		for i in 0 ..< FFT_SIZE {
			if i & span != 0 {
				continue
			}
			j := i + span
			p.line(trellis_pt(s, i), trellis_pt(s + 1, i))
			p.line(trellis_pt(s, i), trellis_pt(s + 1, j))
			p.line(trellis_pt(s, j), trellis_pt(s + 1, i))
			p.line(trellis_pt(s, j), trellis_pt(s + 1, j))
		}
	}

	p.stroke_weight(6)
	for s in 0 ..= FFT_BITS {
		for i in 0 ..< FFT_SIZE {
			pt := trellis_pt(s, i)
			p.point(pt.x, pt.y)
		}
	}

	p.stroke(u8(120))
	p.stroke_weight(1)
	for s in 0 ..< FFT_BITS {
		mid := (trellis_pt(s, 0).x + trellis_pt(s + 1, 0).x) / 2
		lbl := fmt.tprintf("stage %d", s + 1)
		p.text(lbl, Vec2{mid - p.text_width(lbl, 18) / 2, TR_Y0 - 36}, 18)
	}
	for i in 0 ..< FFT_SIZE {
		a := trellis_pt(0, i)
		p.math_text(fmt.tprintf("x_%d", bitrev_index(i)), a.x - 62, a.y + 6, 22)
		b := trellis_pt(FFT_BITS, i)
		p.math_text(fmt.tprintf("X_%d", i), b.x + 26, b.y + 6, 22)
	}
}

draw_page_4 :: proc() {
	stage := p.param_int("next_4", 0, 0, 2)

	p.stroke(u8(0))
	p.stroke_weight(2)

	if stage == 0 {
		title_text("one multiply, two outputs", 40, 26)
		draw_butterfly()
		return
	}

	title_text("and again, inside each half", 40, 26)
	draw_trellis()

	if stage >= 2 {
		p.stroke(u8(0))
		p.stroke_weight(2)
		eq := "N^2  =>  N \\log_2 N"
		p.math_text(eq, p.canvas.width / 2 - p.math_text_width(eq, 32) / 2, 668, 32)
		sub := "2048-sample window: 4,200,000 -> 23,000 multiplies"
		p.text(sub, Vec2{p.canvas.width / 2 - p.text_width(sub, 20) / 2, 710}, 20)
	}
}

phasor_point :: proc(k, n: int, radius: f32) -> Vec2 {
	angle := -math.TAU * f32(k) * f32(n) / f32(FFT_SIZE)
	v := real(signal[n])
	return Vec2{v * math.cos(angle), -v * math.sin(angle)} * radius
}

slot_dir :: proc(i: int) -> Vec2 {
	a := -math.TAU * f32(i) / f32(FFT_SIZE)
	return Vec2{math.cos(a), -math.sin(a)}
}

draw_phasor :: proc(pos: Vec2, radius: f32, k: int, cursor: f32, big: bool = false) {
	n_cur := int(cursor)

	p.push_matrix()
	p.translate(pos.x, pos.y)

	p.stroke(u8(210))
	p.stroke_weight(1)
	p.circle_v({0, 0}, radius)
	p.line(-radius, 0, radius, 0)
	p.line(0, -radius, 0, radius)

	slot := n_cur < FFT_SIZE ? (k * n_cur) % FFT_SIZE : -1
	for i in 0 ..< FFT_SIZE {
		d := slot_dir(i)
		if i == slot {
			p.stroke(CURRENT)
			p.stroke_weight(3)
		} else {
			p.stroke(u8(225))
			p.stroke_weight(1)
		}
		p.line(d.x * radius * 0.93, d.y * radius * 0.93, d.x * radius, d.y * radius)
		if big {
			lbl := fmt.tprintf("%d", i)
			if i != slot {
				p.stroke(u8(170))
			}
			p.stroke_weight(1)
			p.text(lbl, Vec2{d.x * radius * 1.16 - p.text_width(lbl, 14) / 2, d.y * radius * 1.16 + 5}, 14)
		}
	}

	p.stroke(u8(90))
	p.stroke_weight(2)
	p.text(fmt.tprintf("k=%d", k), Vec2{-radius, radius + 20}, 16)

	if cursor < f32(FFT_SIZE) {
		a := -math.TAU * f32(k) * cursor / f32(FFT_SIZE)
		hand := Vec2{math.cos(a), -math.sin(a)} * radius
		p.stroke(u8(215))
		p.stroke_weight(1)
		p.line(0, 0, -hand.x, -hand.y)
		p.stroke(u8(150))
		p.stroke_weight(4)
		p.line(0, 0, hand.x, hand.y)
	}

	sum: Vec2
	last := min(n_cur, FFT_SIZE - 1)
	for n in 0 ..= last {
		d := phasor_point(k, n, radius)
		if n == n_cur {
			if big {
				w := wave_point(n) - pos
				p.stroke(u8(200))
				p.stroke_weight(1)
				p.line(w.x, w.y, d.x, d.y)
			}
			p.stroke(CURRENT)
			p.stroke_weight(9)
		} else {
			p.stroke(u8(0))
			p.stroke_weight(4)
		}
		p.point(d.x, d.y)
		sum += d
	}

	res := sum / f32(FFT_SIZE)
	p.stroke(p.RED)
	p.stroke_weight(3)
	p.line(0, 0, res.x, res.y)
	p.stroke_weight(6)
	p.point(res.x, res.y)

	p.pop_matrix()
}

compute_twiddles :: proc(buf: []complex64) {
	for k in 0..<len(buf) {
		buf[k] = cmplx.exp_complex64(-1i * complex64(math.TAU * f32(k) / f32(len(buf) * 2)))
	}
}

bit_reverse :: proc(buf: []$T) {
	size := u32(len(buf))
	// Perform bit-reversal swap relative to the size of the array
	bit_width := intrinsics.count_trailing_zeros(size)
	for i in 0..<size {
		rev := intrinsics.reverse_bits(i) >> (32 - bit_width)
		if i < rev {
			buf[i], buf[rev] = buf[rev], buf[i]
		}
	}
}

radix2_fft :: proc(buf: []complex64) {
	using p;
	size := u32(len(buf))
	assert(intrinsics.count_ones(size) == 1, "Must use power of 2 for array size")
	ary := [FFT_SIZE]int{}
	for i in 0..<len(ary) {
		ary[i]=i
	}
	bit_reverse(ary[:])

	twiddles := make([]complex64, size / 2, allocator = context.temp_allocator)
	compute_twiddles(twiddles)
	// fmt.println("twiddles:")
	// fmt.println(twiddles)

	bit_reverse(buf)
	bit_width := intrinsics.count_trailing_zeros(size)

	for stage in 1..=bit_width {
		m : u32= 1 << stage
		twiddle_stride := size / m
		partial := make_mat(int(size), int(size))
		m2 : u32= m / 2
		// fmt.println("--m:", m, "m2:", m2)
		for group_start: u32= 0; group_start < size; group_start += m {
			// fmt.println("\tgroup: ", group_start)
			for j in 0..<m2 {
				// fmt.println("\tm2:", m2)
				twiddle := twiddles[j * twiddle_stride]
				// fmt.println("\ttwiddle_idx:", j * twiddle_stride)
				even := buf[group_start + j]
				odd := buf[group_start + j + m2]
				// fmt.println("\tswap:", group_start + j, ",", group_start + j + m2)
				// fmt.println("\tswap idx:", ary[group_start + j], ",", ary[group_start + j + m2])
				buf[group_start + j] = even + twiddle * odd
				buf[group_start + j + m2] = even - twiddle * odd
			}
		}
		//print_rounded(buf)
		// fmt.println("-----mat-----")
		// for i in 0..<FFT_SIZE {
		// 	print_rounded(partial[i][:])
		// }
		// fmt.println("---end mat---")
	}

	// fmt.println(buf)
}

smooth_brain_dft :: proc(buf: []complex64, out: [][]complex64) {
	tmp_buf := make([]complex64, len(buf), allocator = context.temp_allocator)
	for m in 0..<len(buf) {
		sum : complex64
		for n in 0..<len(buf) {
			x_n := buf[n]
			e_bla := cmplx.exp_complex64(-1i * complex64(math.TAU * f32(n * m) / f32(len(buf))))
			out[n][m] = e_bla
			sum += x_n * e_bla
		}
		tmp_buf[m] = sum
	}

	for m in 0..<len(buf) {
		buf[m] = tmp_buf[m]
	}
}

