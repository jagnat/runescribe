package plot

import "core:math"
import simplex "core:math/noise"

// OpenSimplex2 noise in [0, 1), seeded from the canvas seed so R rerolls the
// field along with rand. Feed scaled-down coordinates (e.g. x * 0.01).

noise :: proc {
	noise_1d,
	noise_2d,
	noise_3d,
	noise_v,
}

noise_1d :: proc(x: f32) -> f32 {
	return noise_2d(x, 0)
}

noise_2d :: proc(x, y: f32) -> f32 {
	return simplex.noise_2d(i64(canvas.seed), {f64(x), f64(y)}) * 0.5 + 0.5
}

noise_3d :: proc(x, y, z: f32) -> f32 {
	return simplex.noise_3d_improve_xy(i64(canvas.seed), {f64(x), f64(y), f64(z)}) * 0.5 + 0.5
}

noise_v :: proc(p: Vec2) -> f32 {
	return noise_2d(p.x, p.y)
}

// Octaved noise, also in [0, 1)
fbm :: proc {
	fbm_xy,
	fbm_v,
}

fbm_xy :: proc(x, y: f32, octaves := 4, lacunarity := f32(2), gain := f32(0.5)) -> f32 {
	sum, amp, norm := f32(0), f32(1), f32(0)
	freq := f32(1)
	for _ in 0 ..< octaves {
		sum += amp * noise_2d(x * freq, y * freq)
		norm += amp
		freq *= lacunarity
		amp *= gain
	}
	return sum / norm
}

fbm_v :: proc(p: Vec2, octaves := 4, lacunarity := f32(2), gain := f32(0.5)) -> f32 {
	return fbm_xy(p.x, p.y, octaves, lacunarity, gain)
}

@(private)
vhash :: proc(ix, iy: i32) -> f32 {
	h := u32(ix) * 0x27d4eb2d + u32(iy) * 0x9e3779b9 + u32(canvas.seed)
	h ~= h >> 15
	h *= 0x85ebca6b
	h ~= h >> 13
	h *= 0xc2b2ae35
	h ~= h >> 16
	return f32(h) / f32(max(u32))
}

vnoise :: proc(p: Vec2) -> f32 {
	i := Vec2{math.floor(p.x), math.floor(p.y)}
	f := p - i
	u := f * f * (3 - 2 * f)
	ix := i32(i.x)
	iy := i32(i.y)
	a := vhash(ix, iy)
	b := vhash(ix + 1, iy)
	c := vhash(ix, iy + 1)
	d := vhash(ix + 1, iy + 1)
	return math.lerp(math.lerp(a, b, u.x), math.lerp(c, d, u.x), u.y)
}

// Rotates the domain between octaves; without it they stay axis-aligned and
// the field comes out blobby
@(private)
vfbm_mtx := matrix[2, 2]f32{
	0.80, 0.60,
	-0.60, 0.80,
}

// Signed value fbm in [-1, 1). Lacunarity is off 2 so octaves don't phase-lock
vfbm :: proc(p: Vec2, octaves := 4) -> f32 {
	q := p
	sum, amp, norm := f32(0), f32(0.5), f32(0)
	for _ in 0 ..< octaves {
		sum += amp * (2 * vnoise(q) - 1)
		norm += amp
		q = vfbm_mtx * q * 2.02
		amp *= 0.5
	}
	return sum / norm
}

// The offset decorrelates the components; without it both return the same value
vfbm2 :: proc(p: Vec2, octaves := 4) -> Vec2 {
	return {
		vfbm(p + {1.0, 1.0}, octaves),
		vfbm(p + {6.2, 6.2}, octaves),
	}
}

// iq's domain warp (shadertoy 4s23zz). Sampling the field at o, rather than
// offsetting p by it, is the harder fold. Scale p so the drawing spans a
// couple of units. f is in [0, 1); o and n share its structure
warp :: proc(p: Vec2) -> (f: f32, o, n: Vec2) {
	o = 0.5 + 0.5 * vfbm2(p, 4)
	n = 0.5 + 0.5 * vfbm2(4 * o, 6)
	f = 0.5 + 0.5 * vfbm(2 * (p + 2 * n + {1, 1}), 4)
	return
}
