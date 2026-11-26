package test_wayu

import wayu "../../src"
import "core:fmt"
import "core:testing"

@(test)
test_parse_key_event_arrows :: proc(t: ^testing.T) {
	// Up arrow: ESC [ A
	buf_up := []byte{27, '[', 'A'}
	key, ok := wayu.parse_key_event(buf_up[:], 3)
	testing.expect(t, ok, "Should parse up arrow")
	testing.expect(t, key.key == .Up, "Should be Up key")

	// Down arrow: ESC [ B
	buf_down := []byte{27, '[', 'B'}
	key, ok = wayu.parse_key_event(buf_down[:], 3)
	testing.expect(t, ok, "Should parse down arrow")
	testing.expect(t, key.key == .Down, "Should be Down key")
}

// Test: parse_key_event handles Enter
@(test)
test_parse_key_event_enter :: proc(t: ^testing.T) {
	buf := []byte{13} // Enter key
	key, ok := wayu.parse_key_event(buf[:], 1)
	testing.expect(t, ok, "Should parse Enter")
	testing.expect(t, key.key == .Enter, "Should be Enter key")
}

// Test: parse_key_event handles Escape
@(test)
test_parse_key_event_escape :: proc(t: ^testing.T) {
	buf := []byte{27} // Escape key
	key, ok := wayu.parse_key_event(buf[:], 1)
	testing.expect(t, ok, "Should parse Escape")
	testing.expect(t, key.key == .Escape, "Should be Escape key")
}

// Test: parse_key_event handles Ctrl+C
@(test)
test_parse_key_event_ctrl_c :: proc(t: ^testing.T) {
	buf := []byte{3} // Ctrl+C
	key, ok := wayu.parse_key_event(buf[:], 1)
	testing.expect(t, ok, "Should parse Ctrl+C")
	testing.expect(t, key.key == .Char, "Should be Char key")
	testing.expect(t, key.char == 'c', "Should be 'c' character")
	testing.expect(t, .Ctrl in key.modifiers, "Should have Ctrl modifier")
}

// Test: parse_key_event handles regular characters
@(test)
test_parse_key_event_chars :: proc(t: ^testing.T) {
	// Test 'j'
	buf_j := []byte{'j'}
	key, ok := wayu.parse_key_event(buf_j[:], 1)
	testing.expect(t, ok, "Should parse 'j'")
	testing.expect(t, key.key == .Char, "Should be Char key")
	testing.expect(t, key.char == 'j', "Should be 'j' character")

	// Test 'k'
	buf_k := []byte{'k'}
	key, ok = wayu.parse_key_event(buf_k[:], 1)
	testing.expect(t, ok, "Should parse 'k'")
	testing.expect(t, key.key == .Char, "Should be Char key")
	testing.expect(t, key.char == 'k', "Should be 'k' character")

	// Test 'q'
	buf_q := []byte{'q'}
	key, ok = wayu.parse_key_event(buf_q[:], 1)
	testing.expect(t, ok, "Should parse 'q'")
	testing.expect(t, key.key == .Char, "Should be Char key")
	testing.expect(t, key.char == 'q', "Should be 'q' character")
}

// Note: Screen tests (screen_create, screen_clear, screen_set_cell, render_text)
// are already covered in test_tui_screen.odin

// Test: Main loop integration - terminal size
@(test)
test_main_terminal_size :: proc(t: ^testing.T) {
	width, height, ok := wayu.get_terminal_size()

	// Should return fallback values if not a terminal
	testing.expect(t, width > 0, "Width should be positive")
	testing.expect(t, height > 0, "Height should be positive")
	// ok may be false if not running in a terminal, which is fine for tests
}
