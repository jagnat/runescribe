package plot

import simplex "core:math/noise"

// Processing-style OpenSimplex2 noise in [0, 1), seeded from the canvas seed
// so R rerolls the noise field along with rand. Feed scaled-down coordinates
// (e.g. x * 0.01) for smooth variation.

noise :: proc {
	noise_1d,
	noise_2d,
	noise_3d,
	noise_v,
}

noise_1d :: proc(c: ^Canvas, x: f32) -> f32 {
	return noise_2d(c, x, 0)
}

noise_2d :: proc(c: ^Canvas, x, y: f32) -> f32 {
	return simplex.noise_2d(i64(c.seed), {f64(x), f64(y)}) * 0.5 + 0.5
}

noise_3d :: proc(c: ^Canvas, x, y, z: f32) -> f32 {
	return simplex.noise_3d_improve_xy(i64(c.seed), {f64(x), f64(y), f64(z)}) * 0.5 + 0.5
}

noise_v :: proc(c: ^Canvas, p: Vec2) -> f32 {
	return noise_2d(c, p.x, p.y)
}

// Fractal (octaved) noise, also in [0, 1). Each octave doubles frequency
// (lacunarity) and halves amplitude (gain)
fbm :: proc {
	fbm_xy,
	fbm_v,
}

fbm_xy :: proc(c: ^Canvas, x, y: f32, octaves := 4, lacunarity := f32(2), gain := f32(0.5)) -> f32 {
	sum, amp, norm := f32(0), f32(1), f32(0)
	freq := f32(1)
	for _ in 0 ..< octaves {
		sum += amp * noise_2d(c, x * freq, y * freq)
		norm += amp
		freq *= lacunarity
		amp *= gain
	}
	return sum / norm
}

fbm_v :: proc(c: ^Canvas, p: Vec2, octaves := 4, lacunarity := f32(2), gain := f32(0.5)) -> f32 {
	return fbm_xy(c, p.x, p.y, octaves, lacunarity, gain)
}
