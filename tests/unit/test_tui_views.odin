// test_tui_views.odin - Tests for TUI view rendering
//
// This file tests the TUI view system including:
// - View rendering functions
// - Event handlers
// - Data caching
// - Navigation

package test_tui_views

import "core:testing"
import "core:fmt"
import tui "../../src/tui"

@(test)
test_tui_state_init :: proc(t: ^testing.T) {
	state := tui.tui_state_init()
	defer tui.tui_state_destroy(&state)

	testing.expect_value(t, state.current_view, tui.TUIView.MAIN_MENU)
	testing.expect_value(t, state.selected_index, 0)
	testing.expect_value(t, state.scroll_offset, 0)
	testing.expect_value(t, state.running, true)
	testing.expect(t, state.data_cache != nil, "data_cache should be initialized")
}

@(test)
test_tui_state_goto_view :: proc(t: ^testing.T) {
	state := tui.tui_state_init()
	defer tui.tui_state_destroy(&state)

	// Go to PATH view
	tui.tui_state_goto_view(&state, .PATH_VIEW)

	testing.expect_value(t, state.current_view, tui.TUIView.PATH_VIEW)
	testing.expect_value(t, state.previous_view, tui.TUIView.MAIN_MENU)
	testing.expect_value(t, state.selected_index, 0)  // Reset on view change
	testing.expect_value(t, state.scroll_offset, 0)
	testing.expect_value(t, state.needs_refresh, true)
}

@(test)
test_tui_state_go_back :: proc(t: ^testing.T) {
	state := tui.tui_state_init()
	defer tui.tui_state_destroy(&state)

	// Go to PATH view
	tui.tui_state_goto_view(&state, .PATH_VIEW)

	// Go back to main menu
	tui.tui_state_go_back(&state)

	testing.expect_value(t, state.current_view, tui.TUIView.MAIN_MENU)
	testing.expect_value(t, state.previous_view, tui.TUIView.PATH_VIEW)
}

@(test)
test_tui_state_move_selection :: proc(t: ^testing.T) {
	state := tui.tui_state_init()
	defer tui.tui_state_destroy(&state)

	// Test moving down in main menu (7 items)
	tui.tui_state_move_selection(&state, 1, 7)
	testing.expect_value(t, state.selected_index, 1)

	// Test moving up
	tui.tui_state_move_selection(&state, -1, 7)
	testing.expect_value(t, state.selected_index, 0)

	// Test wrapping (move up from 0 should wrap to 6)
	tui.tui_state_move_selection(&state, -1, 7)
	testing.expect_value(t, state.selected_index, 6)

	// Test wrapping (move down from 6 should wrap to 0)
	tui.tui_state_move_selection(&state, 1, 7)
	testing.expect_value(t, state.selected_index, 0)
}

@(test)
test_get_view_item_count :: proc(t: ^testing.T) {
	state := tui.tui_state_init()
	defer tui.tui_state_destroy(&state)

	// Main menu should have 7 items
	count := tui.get_view_item_count(&state)
	testing.expect_value(t, count, 7)

	// PATH view with no cache should return 0
	tui.tui_state_goto_view(&state, .PATH_VIEW)
	count = tui.get_view_item_count(&state)
	testing.expect_value(t, count, 0)
}

@(test)
test_clear_view_cache :: proc(t: ^testing.T) {
	state := tui.tui_state_init()
	defer tui.tui_state_destroy(&state)

	// Add some mock data to PATH_VIEW cache
	items_ptr := new([dynamic]string)
	items_ptr^ = make([dynamic]string)
	append(&items_ptr^, fmt.aprintf("test1"))
	append(&items_ptr^, fmt.aprintf("test2"))

	state.data_cache[.PATH_VIEW] = items_ptr

	// Verify cache is populated
	testing.expect(t, state.data_cache[.PATH_VIEW] != nil, "Cache should be populated")

	// Clear cache
	tui.clear_view_cache(&state, .PATH_VIEW)

	// Verify cache is cleared
	testing.expect(t, state.data_cache[.PATH_VIEW] == nil, "Cache should be cleared")
}

@(test)
test_render_functions_exist :: proc(t: ^testing.T) {
	// This test just verifies that all render functions exist and can be referenced
	// We can't actually test rendering without a screen buffer

	state := tui.tui_state_init()
	defer tui.tui_state_destroy(&state)

	screen := tui.screen_create(80, 24)
	defer tui.screen_destroy(&screen)

	// Test that render functions don't crash with empty cache
	// They should display "Loading..." messages

	tui.render_path_view(&state, &screen)
	tui.render_alias_view(&state, &screen)
	tui.render_constants_view(&state, &screen)
	tui.render_completions_view(&state, &screen)
	tui.render_backups_view(&state, &screen)
	tui.render_plugins_view(&state, &screen)
	tui.render_settings_view(&state, &screen)

	// If we got here without crashing, test passes
	testing.expect(t, true, "All render functions executed without crashing")
}

@(test)
test_handle_view_event_exists :: proc(t: ^testing.T) {
	// Verify event handler exists and can be called
	state := tui.tui_state_init()
	defer tui.tui_state_destroy(&state)

	key := tui.KeyEvent{
		key = .Char,
		char = 'd',
	}

	// Should not crash even with empty cache
	tui.handle_view_event(&state, key)

	testing.expect(t, true, "Event handler executed without crashing")
}
