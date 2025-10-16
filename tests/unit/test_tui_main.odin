package test_wayu

import "core:testing"
import "core:fmt"
import tui "../../src/tui"

// Test: tui_state_init initializes state correctly
@(test)
test_tui_state_init :: proc(t: ^testing.T) {
	state := tui.tui_state_init()
	defer tui.tui_state_destroy(&state)

	testing.expect(t, state.current_view == .MAIN_MENU, "Initial view should be MAIN_MENU")
	testing.expect(t, state.previous_view == .MAIN_MENU, "Previous view should be MAIN_MENU")
	testing.expect(t, state.selected_index == 0, "Initial selected index should be 0")
	testing.expect(t, state.scroll_offset == 0, "Initial scroll offset should be 0")
	testing.expect(t, state.terminal_width == 80, "Default terminal width should be 80")
	testing.expect(t, state.terminal_height == 24, "Default terminal height should be 24")
	testing.expect(t, state.needs_refresh == true, "Initial needs_refresh should be true")
	testing.expect(t, state.running == true, "Initial running should be true")
}

// Test: tui_state_goto_view changes view correctly
@(test)
test_tui_state_goto_view :: proc(t: ^testing.T) {
	state := tui.tui_state_init()
	defer tui.tui_state_destroy(&state)

	// Navigate to PATH view
	tui.tui_state_goto_view(&state, .PATH_VIEW)

	testing.expect(t, state.current_view == .PATH_VIEW, "Current view should be PATH_VIEW")
	testing.expect(t, state.previous_view == .MAIN_MENU, "Previous view should be MAIN_MENU")
	testing.expect(t, state.selected_index == 0, "Selected index should reset to 0")
	testing.expect(t, state.scroll_offset == 0, "Scroll offset should reset to 0")
	testing.expect(t, state.needs_refresh == true, "needs_refresh should be true")
}

// Test: tui_state_go_back returns to previous view
@(test)
test_tui_state_go_back :: proc(t: ^testing.T) {
	state := tui.tui_state_init()
	defer tui.tui_state_destroy(&state)

	// Navigate to PATH view
	tui.tui_state_goto_view(&state, .PATH_VIEW)

	// Go back
	tui.tui_state_go_back(&state)

	testing.expect(t, state.current_view == .MAIN_MENU, "Should return to MAIN_MENU")
	testing.expect(t, state.previous_view == .PATH_VIEW, "Previous view should now be PATH_VIEW")
	testing.expect(t, state.needs_refresh == true, "needs_refresh should be true")
}

// Test: tui_state_move_selection navigates correctly
@(test)
test_tui_state_move_selection :: proc(t: ^testing.T) {
	state := tui.tui_state_init()
	defer tui.tui_state_destroy(&state)

	item_count := 7  // Main menu has 7 items

	// Move down
	tui.tui_state_move_selection(&state, 1, item_count)
	testing.expect(t, state.selected_index == 1, "Should move to index 1")

	// Move down again
	tui.tui_state_move_selection(&state, 1, item_count)
	testing.expect(t, state.selected_index == 2, "Should move to index 2")

	// Move up
	tui.tui_state_move_selection(&state, -1, item_count)
	testing.expect(t, state.selected_index == 1, "Should move back to index 1")

	// Test wrap-around at bottom
	state.selected_index = 6
	tui.tui_state_move_selection(&state, 1, item_count)
	testing.expect(t, state.selected_index == 0, "Should wrap to index 0")

	// Test wrap-around at top
	state.selected_index = 0
	tui.tui_state_move_selection(&state, -1, item_count)
	testing.expect(t, state.selected_index == 6, "Should wrap to index 6")
}

// Test: get_view_item_count returns correct count
@(test)
test_main_get_view_item_count :: proc(t: ^testing.T) {
	state := tui.tui_state_init()
	defer tui.tui_state_destroy(&state)

	// Main menu has 7 items
	count := tui.get_view_item_count(&state)
	testing.expect(t, count == 7, "Main menu should have 7 items")

	// PATH view (placeholder count)
	tui.tui_state_goto_view(&state, .PATH_VIEW)
	count = tui.get_view_item_count(&state)
	testing.expect(t, count > 0, "PATH view should have items")

	// ALIAS view (placeholder count)
	tui.tui_state_goto_view(&state, .ALIAS_VIEW)
	count = tui.get_view_item_count(&state)
	testing.expect(t, count > 0, "ALIAS view should have items")
}

// Test: parse_key_event handles arrow keys
@(test)
test_parse_key_event_arrows :: proc(t: ^testing.T) {
	// Up arrow: ESC [ A
	buf_up := []byte{27, '[', 'A'}
	key, ok := tui.parse_key_event(buf_up[:], 3)
	testing.expect(t, ok, "Should parse up arrow")
	testing.expect(t, key.key == .Up, "Should be Up key")

	// Down arrow: ESC [ B
	buf_down := []byte{27, '[', 'B'}
	key, ok = tui.parse_key_event(buf_down[:], 3)
	testing.expect(t, ok, "Should parse down arrow")
	testing.expect(t, key.key == .Down, "Should be Down key")
}

// Test: parse_key_event handles Enter
@(test)
test_parse_key_event_enter :: proc(t: ^testing.T) {
	buf := []byte{13}  // Enter key
	key, ok := tui.parse_key_event(buf[:], 1)
	testing.expect(t, ok, "Should parse Enter")
	testing.expect(t, key.key == .Enter, "Should be Enter key")
}

// Test: parse_key_event handles Escape
@(test)
test_parse_key_event_escape :: proc(t: ^testing.T) {
	buf := []byte{27}  // Escape key
	key, ok := tui.parse_key_event(buf[:], 1)
	testing.expect(t, ok, "Should parse Escape")
	testing.expect(t, key.key == .Escape, "Should be Escape key")
}

// Test: parse_key_event handles Ctrl+C
@(test)
test_parse_key_event_ctrl_c :: proc(t: ^testing.T) {
	buf := []byte{3}  // Ctrl+C
	key, ok := tui.parse_key_event(buf[:], 1)
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
	key, ok := tui.parse_key_event(buf_j[:], 1)
	testing.expect(t, ok, "Should parse 'j'")
	testing.expect(t, key.key == .Char, "Should be Char key")
	testing.expect(t, key.char == 'j', "Should be 'j' character")

	// Test 'k'
	buf_k := []byte{'k'}
	key, ok = tui.parse_key_event(buf_k[:], 1)
	testing.expect(t, ok, "Should parse 'k'")
	testing.expect(t, key.key == .Char, "Should be Char key")
	testing.expect(t, key.char == 'k', "Should be 'k' character")

	// Test 'q'
	buf_q := []byte{'q'}
	key, ok = tui.parse_key_event(buf_q[:], 1)
	testing.expect(t, ok, "Should parse 'q'")
	testing.expect(t, key.key == .Char, "Should be Char key")
	testing.expect(t, key.char == 'q', "Should be 'q' character")
}

// Note: Screen tests (screen_create, screen_clear, screen_set_cell, render_text)
// are already covered in test_tui_screen.odin

// Test: Main loop integration - terminal size
@(test)
test_main_terminal_size :: proc(t: ^testing.T) {
	width, height, ok := tui.get_terminal_size()

	// Should return fallback values if not a terminal
	testing.expect(t, width > 0, "Width should be positive")
	testing.expect(t, height > 0, "Height should be positive")
	// ok may be false if not running in a terminal, which is fine for tests
}
