package clip_demo

import "core:math"
import "../../plot"

main :: proc() {
	plot.run(800, 800, "clip demo: occluded ridgelines", draw, loop = false)
}

// Hidden-line removal via record-time occlusion: ridges are drawn front to
// back, each pushing its silhouette as an occluder, so farther ridges and the
// sun only survive where nothing nearer covers them. A frame mask keeps every
// stroke inside the border
draw :: proc() {
	W := plot.canvas.width
	H := plot.canvas.height
	margin := f32(70)

	plot.rect(margin, margin, W - 2 * margin, H - 2 * margin)
	frame := [4]plot.Vec2{
		{margin, margin},
		{W - margin, margin},
		{W - margin, H - margin},
		{margin, H - margin},
	}
	plot.push_clip(frame[:])

	rows := 12
	n := 140
	for k in 0 ..< rows {
		t := f32(k) / f32(rows - 1)
		base := math.lerp(H - margin - 20, H * 0.36, t)
		amp := math.lerp(f32(50), f32(170), t)

		ridge := make([]plot.Vec2, n, context.temp_allocator)
		for i in 0 ..< n {
			fx := f32(i) / f32(n - 1)
			h := plot.fbm(fx * 3.1, t * 2.6)
			ridge[i] = {math.lerp(margin, W - margin, fx), base - h * h * amp}
		}

		plot.stroke_weight(math.lerp(f32(2.2), f32(1.2), t))
		plot.polyline(ridge)

		// silhouette closed off below the canvas bottom
		sil := make([]plot.Vec2, n + 2, context.temp_allocator)
		copy(sil, ridge)
		sil[n] = {W - margin, H + 10}
		sil[n + 1] = {margin, H + 10}

		if k == 0 {
			plot.stroke(plot.BLUE)
			plot.stroke_weight(1)
			plot.hatch(sil, 9, -0.5)
			plot.stroke(plot.BLACK)
		}

		plot.occlude(sil)
	}

	// the sun sits behind every ridge and survives only in the gaps
	plot.stroke(plot.ORANGE)
	plot.stroke_weight(1.4)
	for r := f32(120); r >= 12; r -= 11 {
		plot.circle(W * 0.63, H * 0.30, r)
	}
}
