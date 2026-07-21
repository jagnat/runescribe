package plot

import "core:unicode/utf8"

// TeX-subset math layout on the single-line font. Supported: literal ASCII,
// {} grouping, ^ and _ scripts (one char, \command, or {group}), \commands
// for Greek letters and symbols (\alpha, \pi, \sum, \infty, \cdot, \to, ...).
// \sum renders enlarged with ^/_ limits centered above/below. Spaces are
// ignored, as in TeX math mode; unknown commands render as their raw name.
// pos is the baseline origin; size is the em height, matching text().

MATH_SCRIPT_SCALE :: f32(0.65)
MATH_SUP_RAISE :: f32(0.42) // script baseline offsets, fractions of the em
MATH_SUB_DROP :: f32(0.18)
MATH_OP_SCALE :: f32(1.4)
MATH_OP_GAP :: f32(0.12)
MATH_AXIS :: f32(0.36) // big operators center on this height above baseline

math_text :: proc {
	math_text_xy,
	math_text_v,
}

math_text_v :: proc(str: string, pos: Vec2, size: f32) {
	math_render(math_parse(str), pos, size)
}

math_text_xy :: proc(str: string, x, y, size: f32) {
	math_text_v(str, {x, y}, size)
}

math_text_width :: proc(str: string, size: f32) -> f32 {
	return math_measure(math_parse(str), size).w
}

@(private)
Math_Kind :: enum {
	Sym,
	Row,
	Scripts,
}

@(private)
Math_Node :: struct {
	kind: Math_Kind,
	ch: rune, // Sym
	items: [dynamic]^Math_Node, // Row
	base, sup, sub: ^Math_Node, // Scripts
}

@(private)
Math_Box :: struct {
	w, asc, desc: f32, // extents above/below the baseline, positive down for desc
}

@(private)
math_symbols := [?]struct {
	name: string,
	ch: rune,
}{
	{"alpha", 'α'}, {"beta", 'β'}, {"gamma", 'γ'}, {"delta", 'δ'},
	{"epsilon", 'ε'}, {"zeta", 'ζ'}, {"eta", 'η'}, {"theta", 'θ'},
	{"iota", 'ι'}, {"kappa", 'κ'}, {"lambda", 'λ'}, {"mu", 'μ'},
	{"nu", 'ν'}, {"xi", 'ξ'}, {"omicron", 'ο'}, {"pi", 'π'},
	{"rho", 'ρ'}, {"sigma", 'σ'}, {"tau", 'τ'}, {"upsilon", 'υ'},
	{"phi", 'φ'}, {"chi", 'χ'}, {"psi", 'ψ'}, {"omega", 'ω'},
	{"Gamma", 'Γ'}, {"Delta", 'Δ'}, {"Theta", 'Θ'}, {"Lambda", 'Λ'},
	{"Xi", 'Ξ'}, {"Pi", 'Π'}, {"Sigma", 'Σ'}, {"Upsilon", 'Υ'},
	{"Phi", 'Φ'}, {"Psi", 'Ψ'}, {"Omega", 'Ω'},
	{"sum", '∑'}, {"int", '∫'}, {"sqrt", '√'}, {"infty", '∞'},
	{"partial", '∂'}, {"pm", '±'}, {"times", '×'}, {"cdot", '·'},
	{"approx", '≈'}, {"neq", '≠'}, {"leq", '≤'}, {"geq", '≥'},
	{"to", '→'}, {"rightarrow", '→'},
}

// Parsing; nodes live on the temp allocator like all per-frame recording

@(private)
Math_Parser :: struct {
	src: string,
	pos: int,
}

@(private)
math_new :: proc(kind: Math_Kind) -> ^Math_Node {
	n := new(Math_Node, context.temp_allocator)
	n.kind = kind
	if kind == .Row {
		n.items = make([dynamic]^Math_Node, context.temp_allocator)
	}
	return n
}

@(private)
math_peek :: proc(p: ^Math_Parser) -> rune {
	if p.pos >= len(p.src) {
		return 0
	}
	ch, _ := utf8.decode_rune_in_string(p.src[p.pos:])
	return ch
}

@(private)
math_next :: proc(p: ^Math_Parser) -> rune {
	if p.pos >= len(p.src) {
		return 0
	}
	ch, n := utf8.decode_rune_in_string(p.src[p.pos:])
	p.pos += n
	return ch
}

@(private)
math_parse :: proc(str: string) -> ^Math_Node {
	p := Math_Parser{src = str}
	return math_parse_row(&p, stop_at_brace = false)
}

@(private)
math_parse_row :: proc(p: ^Math_Parser, stop_at_brace: bool) -> ^Math_Node {
	row := math_new(.Row)
	for {
		ch := math_peek(p)
		if ch == 0 {
			break
		}
		if ch == '}' {
			if stop_at_brace {
				math_next(p)
			} else {
				math_next(p) // stray close brace, ignore
				continue
			}
			break
		}
		if ch == ' ' {
			math_next(p)
			continue
		}
		if ch == '^' || ch == '_' {
			math_next(p)
			arg := math_parse_atom(p)
			target: ^Math_Node
			if last := len(row.items) - 1; last >= 0 && row.items[last].kind == .Scripts {
				target = row.items[last]
			} else {
				target = math_new(.Scripts)
				if len(row.items) > 0 {
					target.base = pop(&row.items)
				} else {
					target.base = math_new(.Row)
				}
				append(&row.items, target)
			}
			if ch == '^' {
				target.sup = arg
			} else {
				target.sub = arg
			}
			continue
		}
		append(&row.items, math_parse_atom(p))
	}
	return row
}

@(private)
math_parse_atom :: proc(p: ^Math_Parser) -> ^Math_Node {
	for math_peek(p) == ' ' {
		math_next(p)
	}
	ch := math_next(p)
	switch ch {
	case 0:
		return math_new(.Row)
	case '{':
		return math_parse_row(p, stop_at_brace = true)
	case '\\':
		start := p.pos
		for c := math_peek(p); (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); c = math_peek(p) {
			math_next(p)
		}
		name := p.src[start:p.pos]
		for s in math_symbols {
			if s.name == name {
				sym := math_new(.Sym)
				sym.ch = s.ch
				return sym
			}
		}
		row := math_new(.Row)
		for c in name {
			sym := math_new(.Sym)
			sym.ch = c
			append(&row.items, sym)
		}
		return row
	case:
		sym := math_new(.Sym)
		sym.ch = ch
		return sym
	}
}

// Layout

// Vertical extent of a glyph's strokes in em units, y-down (negative above
// baseline). Control points can overshoot the curve slightly; close enough.
@(private)
glyph_y_range :: proc(strokes: []Glyph_Stroke) -> (lo, hi: f32) {
	for st in strokes {
		for pt in st.points {
			lo = min(lo, pt.y)
			hi = max(hi, pt.y)
		}
	}
	return
}

@(private)
math_is_bigop :: proc(n: ^Math_Node) -> bool {
	return n.kind == .Scripts && n.base.kind == .Sym && n.base.ch == '∑' && (n.sup != nil || n.sub != nil)
}

@(private)
math_measure :: proc(n: ^Math_Node, size: f32) -> Math_Box {
	switch n.kind {
	case .Sym:
		lo, hi := glyph_y_range(glyph_strokes(n.ch))
		return {w = FONT_ADVANCE * size, asc = -lo * size, desc = hi * size}
	case .Row:
		b: Math_Box
		for it in n.items {
			c := math_measure(it, size)
			b.w += c.w
			b.asc = max(b.asc, c.asc)
			b.desc = max(b.desc, c.desc)
		}
		return b
	case .Scripts:
		if math_is_bigop(n) {
			return math_measure_bigop(n, size)
		}
		b := math_measure(n.base, size)
		ss := size * MATH_SCRIPT_SCALE
		sw: f32
		if n.sup != nil {
			s := math_measure(n.sup, ss)
			sw = max(sw, s.w)
			b.asc = max(b.asc, MATH_SUP_RAISE * size + s.asc)
		}
		if n.sub != nil {
			s := math_measure(n.sub, ss)
			sw = max(sw, s.w)
			b.desc = max(b.desc, MATH_SUB_DROP * size + s.desc)
		}
		b.w += sw
		return b
	}
	return {}
}

// Baseline shift that centers the enlarged operator glyph on the math axis
@(private)
math_bigop_shift :: proc(n: ^Math_Node, size: f32) -> (dy, top, bot: f32) {
	lo, hi := glyph_y_range(glyph_strokes(n.base.ch))
	os := size * MATH_OP_SCALE
	dy = -MATH_AXIS * size - (lo + hi) / 2 * os
	top = lo * os + dy
	bot = hi * os + dy
	return
}

@(private)
math_measure_bigop :: proc(n: ^Math_Node, size: f32) -> Math_Box {
	_, top, bot := math_bigop_shift(n, size)
	b := Math_Box{w = FONT_ADVANCE * MATH_OP_SCALE * size, asc = -top, desc = bot}
	ss := size * MATH_SCRIPT_SCALE
	if n.sup != nil {
		s := math_measure(n.sup, ss)
		b.w = max(b.w, s.w)
		b.asc = -(top - MATH_OP_GAP * size - s.desc) + s.asc
	}
	if n.sub != nil {
		s := math_measure(n.sub, ss)
		b.w = max(b.w, s.w)
		b.desc = bot + MATH_OP_GAP * size + s.asc + s.desc
	}
	return b
}

@(private)
math_render :: proc(n: ^Math_Node, pos: Vec2, size: f32) {
	switch n.kind {
	case .Sym:
		if strokes := glyph_strokes(n.ch); strokes != nil {
			glyph(strokes, pos, size)
		}
	case .Row:
		pen := pos
		for it in n.items {
			math_render(it, pen, size)
			pen.x += math_measure(it, size).w
		}
	case .Scripts:
		if math_is_bigop(n) {
			math_render_bigop(n, pos, size)
			return
		}
		base := math_measure(n.base, size)
		math_render(n.base, pos, size)
		ss := size * MATH_SCRIPT_SCALE
		sx := pos.x + base.w
		if n.sup != nil {
			math_render(n.sup, {sx, pos.y - MATH_SUP_RAISE * size}, ss)
		}
		if n.sub != nil {
			math_render(n.sub, {sx, pos.y + MATH_SUB_DROP * size}, ss)
		}
	}
}

@(private)
math_render_bigop :: proc(n: ^Math_Node, pos: Vec2, size: f32) {
	w := math_measure_bigop(n, size).w
	dy, top, bot := math_bigop_shift(n, size)
	os := size * MATH_OP_SCALE
	glyph(glyph_strokes(n.base.ch), {pos.x + (w - FONT_ADVANCE * os) / 2, pos.y + dy}, os)
	ss := size * MATH_SCRIPT_SCALE
	if n.sup != nil {
		s := math_measure(n.sup, ss)
		math_render(n.sup, {pos.x + (w - s.w) / 2, pos.y + top - MATH_OP_GAP * size - s.desc}, ss)
	}
	if n.sub != nil {
		s := math_measure(n.sub, ss)
		math_render(n.sub, {pos.x + (w - s.w) / 2, pos.y + bot + MATH_OP_GAP * size + s.asc}, ss)
	}
}
