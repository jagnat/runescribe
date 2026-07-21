package plot

import rl "vendor:raylib"

// Raw input for interactive sketches. Run with loop = true so draw sees fresh
// state each frame. S, R, and Tab are claimed by the framework.

Key :: rl.KeyboardKey
MouseButton :: rl.MouseButton

mouse :: proc() -> Vec2 {
	return rl.GetMousePosition()
}

// Mouse queries report false while the tweak panel has the pointer
mouse_down :: proc(button := MouseButton.LEFT) -> bool {
	return rl.IsMouseButtonDown(button) && !ui_wants_mouse()
}

mouse_pressed :: proc(button := MouseButton.LEFT) -> bool {
	return rl.IsMouseButtonPressed(button) && !ui_wants_mouse()
}

wheel :: proc() -> f32 {
	return rl.GetMouseWheelMove()
}

key_down :: proc(key: Key) -> bool {
	return rl.IsKeyDown(key)
}

key_pressed :: proc(key: Key) -> bool {
	return rl.IsKeyPressed(key)
}
