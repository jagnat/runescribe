package plot

import "core:math"
import "core:math/linalg"

// Single-line text in the bundled Maple Mono derivative (font_maple.odin).
// size is the em height in local units: caps are 0.73*size, lowercase
// 0.55*size. pos is the baseline origin of the first glyph. Monospace;
// newlines drop one line and return to pos.x. Non-ASCII runes advance blank.

text :: proc {
	text_xy,
	text_v,
}

text_v :: proc(str: string, pos: Vec2, size: f32) {
	pen := pos
	for ch in str {
		if ch == '\n' {
			pen = {pos.x, pen.y + FONT_LINE_HEIGHT * size}
			continue
		}
		if strokes := glyph_strokes(ch); strokes != nil {
			glyph(strokes, pen, size)
		}
		pen.x += FONT_ADVANCE * size
	}
}

text_xy :: proc(str: string, x, y, size: f32) {
	text_v(str, {x, y}, size)
}

// Width of the widest line, in local units
text_width :: proc(str: string, size: f32) -> f32 {
	longest, run := 0, 0
	for ch in str {
		if ch == '\n' {
			longest = max(longest, run)
			run = 0
		} else {
			run += 1
		}
	}
	return f32(max(longest, run)) * FONT_ADVANCE * size
}

// Strokes for a rune, or nil if the font has no glyph for it
@(private)
glyph_strokes :: proc(ch: rune) -> []Glyph_Stroke {
	if ch >= 33 && ch <= 126 {
		return font_glyphs[int(ch) - 33]
	}
	lo, hi := 0, len(font_glyphs_ext)
	for lo < hi {
		mid := (lo + hi) / 2
		if font_glyphs_ext[mid].ch < ch {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < len(font_glyphs_ext) && font_glyphs_ext[lo].ch == ch {
		return font_glyphs_ext[lo].strokes
	}
	return nil
}

@(private)
glyph :: proc(strokes: []Glyph_Stroke, origin: Vec2, size: f32) {
	for st in strokes {
		if len(st.points) == 1 {
			point_v(origin + st.points[0] * size)
			continue
		}
		pts := make([dynamic]Vec2, 0, 32, context.temp_allocator)
		append(&pts, apply(origin + st.points[0] * size))
		for i := 1; i + 2 < len(st.points); i += 3 {
			c1 := apply(origin + st.points[i] * size)
			c2 := apply(origin + st.points[i + 1] * size)
			p := apply(origin + st.points[i + 2] * size)
			flatten_cubic(&pts, pts[len(pts) - 1], c1, c2, p)
		}
		record(Polyline{pts[:], st.closed})
	}
}

// Appends the flattened curve after p0, which is already in the array.
// Same Wang bound as bezier_v
@(private)
flatten_cubic :: proc(pts: ^[dynamic]Vec2, p0, p1, p2, p3: Vec2) {
	d := max(linalg.length(p0 - 2 * p1 + p2), linalg.length(p1 - 2 * p2 + p3))
	n := clamp(int(math.ceil(math.sqrt(3 * d / (4 * FLATTEN_TOLERANCE)))), 1, 256)
	for i in 1 ..= n {
		t := f32(i) / f32(n)
		u := 1 - t
		append(pts, u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3)
	}
}
