package plot

import "base:intrinsics"
import "core:fmt"
import "core:math"
import "core:reflect"
import rl "vendor:raylib"

// Tweak panel: immediate-mode parameters for live-tuning a sketch.
// Call param/param_int/toggle inside draw — the first call registers the
// control, every call returns its live value. Tab shows the panel; drag a row
// to scrub it, arrow keys nudge the hovered row. The panel draws straight to
// the preview and records nothing, so SVG exports stay clean.

UI_PANEL_W :: f32(230)
UI_ROW_H :: f32(20)
UI_ROW_GAP :: f32(4)
UI_PAD :: f32(8)
UI_FONT :: i32(10)

ParamKind :: enum {
	F32,
	Int,
	Toggle,
	Enum,
}

Param :: struct {
	name: string, // not copied; pass a literal
	kind: ParamKind,
	value, lo, hi: f32, // for .Enum, value is the member index [0, hi]
	enum_type: typeid, // .Enum only: resolves member names/values via reflect
	seen: bool, // declared this draw; unseen params are hidden but keep their value
}

// Params outlive frames on purpose: allocated once in run, freed when it returns
@(private)
ui: struct {
	params: [dynamic]Param, // seen (visible) params partitioned to the front
	shown: int, // count of visible params; hidden ones sit past this
	visible: bool,
	active: int, // row being dragged, -1 when none
}

param :: proc(name: string, initial, lo, hi: f32) -> f32 {
	return ui_param(name, .F32, initial, lo, hi, nil)
}

param_int :: proc(name: string, initial, lo, hi: int) -> int {
	return int(ui_param(name, .Int, f32(initial), f32(lo), f32(hi), nil))
}

toggle :: proc(name: string, initial: bool) -> bool {
	return ui_param(name, .Toggle, initial ? 1 : 0, 0, 1, nil) != 0
}

// Scrub through an enum's members; T is inferred from initial. Non-contiguous
// values are fine — the row scrubs member index, so the returned value is always
// a real member.
param_enum :: proc(name: string, initial: $T) -> T where intrinsics.type_is_enum(T) {
	values := reflect.enum_field_values(T)
	init_idx := 0
	for v, i in values {
		if i64(v) == i64(initial) {
			init_idx = i
		}
	}
	idx := int(ui_param(name, .Enum, f32(init_idx), 0, f32(len(values) - 1), T))
	return T(i64(values[clamp(idx, 0, len(values) - 1)]))
}

@(private)
ui_param :: proc(name: string, kind: ParamKind, initial, lo, hi: f32, enum_type: typeid) -> f32 {
	for &pa in ui.params {
		if pa.name == name {
			pa.seen = true
			return pa.value
		}
	}
	append(&ui.params, Param{name, kind, clamp(initial, lo, hi), lo, hi, enum_type, true})
	return ui.params[len(ui.params) - 1].value
}

// Bracket the draw call: clear marks before, partition after. A param the
// sketch re-declares stays visible; one it stops declaring (its function no
// longer selected) is hidden but retains its value, so re-enabling it restores
// the last value instead of the initial. Stable partition preserves
// declaration order in both groups, so rows don't jump and a hidden param
// reappears in its original slot.
@(private)
ui_mark :: proc() {
	for &pa in ui.params {
		pa.seen = false
	}
}

@(private)
ui_sweep :: proc() {
	sorted := make([dynamic]Param, 0, len(ui.params), context.temp_allocator)
	for pa in ui.params {
		if pa.seen {
			append(&sorted, pa)
		}
	}
	ui.shown = len(sorted)
	for pa in ui.params {
		if !pa.seen {
			append(&sorted, pa)
		}
	}
	copy(ui.params[:], sorted[:])
	if ui.active >= ui.shown {
		ui.active = -1
	}
}

// Row 0 of the panel is the seed line; param rows follow
@(private)
ui_row_rect :: proc(i: int) -> rl.Rectangle {
	y := UI_PAD + (UI_ROW_H + UI_ROW_GAP) * f32(i + 1)
	return {UI_PAD, y, UI_PANEL_W - 2 * UI_PAD, UI_ROW_H}
}

@(private)
ui_panel_height :: proc() -> f32 {
	return UI_PAD * 2 + (UI_ROW_H + UI_ROW_GAP) * f32(ui.shown + 1) - UI_ROW_GAP
}

@(private)
ui_wants_mouse :: proc() -> bool {
	if !ui.visible {
		return false
	}
	if ui.active >= 0 {
		return true
	}
	m := rl.GetMousePosition()
	return m.x < UI_PANEL_W && m.y < ui_panel_height()
}

// Returns true when a control changed, so paused (loop = false) runs re-record
@(private)
ui_update :: proc() -> (changed: bool) {
	if rl.IsKeyPressed(.TAB) {
		ui.visible = !ui.visible
	}
	if !ui.visible {
		ui.active = -1
		return
	}

	mouse := rl.GetMousePosition()
	hover := -1
	for i in 0 ..< ui.shown {
		if rl.CheckCollisionPointRec(mouse, ui_row_rect(i)) {
			hover = i
		}
	}

	if rl.IsMouseButtonPressed(.LEFT) && hover >= 0 {
		if ui.params[hover].kind == .Toggle {
			pa := &ui.params[hover]
			pa.value = pa.value == 0 ? 1 : 0
			changed = true
		} else {
			ui.active = hover
		}
	}
	if !rl.IsMouseButtonDown(.LEFT) {
		ui.active = -1
	}

	if ui.active >= 0 {
		pa := &ui.params[ui.active]
		r := ui_row_rect(ui.active)
		v := pa.lo + (pa.hi - pa.lo) * clamp((mouse.x - r.x) / r.width, 0, 1)
		if pa.kind == .Int || pa.kind == .Enum {
			v = math.round(v)
		}
		if v != pa.value {
			pa.value = v
			changed = true
		}
	}

	if hover >= 0 && ui.params[hover].kind != .Toggle {
		pa := &ui.params[hover]
		step := (pa.kind == .Int || pa.kind == .Enum) ? 1 : (pa.hi - pa.lo) / 100
		dir := f32(0)
		if rl.IsKeyPressed(.RIGHT) || rl.IsKeyPressedRepeat(.RIGHT) {
			dir = 1
		}
		if rl.IsKeyPressed(.LEFT) || rl.IsKeyPressedRepeat(.LEFT) {
			dir = -1
		}
		if dir != 0 {
			pa.value = clamp(pa.value + dir * step, pa.lo, pa.hi)
			changed = true
		}
	}
	return
}

// Stack-formatted cstring for DrawText: the panel renders every frame, and
// while paused (loop = false) temp allocations would pile up until re-record
@(private)
ui_text :: proc(buf: []u8, format: string, args: ..any) -> cstring {
	s := fmt.bprintf(buf[:len(buf) - 1], format, ..args)
	buf[len(s)] = 0
	return cstring(raw_data(buf))
}

@(private)
ui_render :: proc() {
	if !ui.visible {
		return
	}
	buf: [64]u8
	rl.DrawRectangleRec({0, 0, UI_PANEL_W, ui_panel_height()}, {24, 24, 24, 216})
	text_dy := (i32(UI_ROW_H) - UI_FONT) / 2
	rl.DrawText(ui_text(buf[:], "seed %d", canvas.seed), i32(UI_PAD) + 4, i32(UI_PAD) + text_dy, UI_FONT, rl.RAYWHITE)

	for i in 0 ..< ui.shown {
		pa := ui.params[i]
		r := ui_row_rect(i)
		rl.DrawRectangleRec(r, {58, 58, 58, 255})
		t := (pa.value - pa.lo) / (pa.hi - pa.lo)
		rl.DrawRectangleRec({r.x, r.y, r.width * t, r.height}, {86, 128, 194, 255})
		ty := i32(r.y) + text_dy
		rl.DrawText(ui_text(buf[:], "%s", pa.name), i32(r.x) + 4, ty, UI_FONT, rl.RAYWHITE)
		val: cstring
		switch pa.kind {
		case .F32:
			val = ui_text(buf[:], "%.3f", pa.value)
		case .Int:
			val = ui_text(buf[:], "%d", int(pa.value))
		case .Toggle:
			val = pa.value != 0 ? "on" : "off"
		case .Enum:
			names := reflect.enum_field_names(pa.enum_type)
			val = ui_text(buf[:], "%s", names[clamp(int(pa.value), 0, len(names) - 1)])
		}
		rl.DrawText(val, i32(r.x + r.width) - rl.MeasureText(val, UI_FONT) - 4, ty, UI_FONT, rl.RAYWHITE)
	}
}
