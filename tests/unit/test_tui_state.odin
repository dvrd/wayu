package test_wayu

import "core:testing"
import tui "../../src/tui"

@(test)
test_state_init :: proc(t: ^testing.T) {
	state := tui.tui_state_init()
	defer tui.tui_state_destroy(&state)

	testing.expect(t, state.current_view == .MAIN_MENU, "Should start at MAIN_MENU")
	testing.expect(t, state.previous_view == .MAIN_MENU, "Previous view should be MAIN_MENU")
	testing.expect(t, state.selected_index == 0, "Selected index should start at 0")
	testing.expect(t, state.scroll_offset == 0, "Scroll offset should start at 0")
	testing.expect(t, state.terminal_width == 80, "Default width should be 80")
	testing.expect(t, state.terminal_height == 24, "Default height should be 24")
	testing.expect(t, state.needs_refresh == true, "Should need refresh on init")
	testing.expect(t, state.running == true, "Should be running on init")
	testing.expect(t, state.data_cache != nil, "Data cache should be initialized")
}

@(test)
test_goto_view :: proc(t: ^testing.T) {
	state := tui.tui_state_init()
	defer tui.tui_state_destroy(&state)

	// Go to PATH_VIEW
	tui.tui_state_goto_view(&state, .PATH_VIEW)

	testing.expect(t, state.current_view == .PATH_VIEW, "Should transition to PATH_VIEW")
	testing.expect(t, state.previous_view == .MAIN_MENU, "Previous view should be MAIN_MENU")
	testing.expect(t, state.selected_index == 0, "Selected index should reset to 0")
	testing.expect(t, state.scroll_offset == 0, "Scroll offset should reset to 0")
	testing.expect(t, state.needs_refresh == true, "Should need refresh after view change")
}

@(test)
test_goto_view_multiple :: proc(t: ^testing.T) {
	state := tui.tui_state_init()
	defer tui.tui_state_destroy(&state)

	// Chain transitions
	tui.tui_state_goto_view(&state, .PATH_VIEW)
	testing.expect(t, state.current_view == .PATH_VIEW, "Should be at PATH_VIEW")
	testing.expect(t, state.previous_view == .MAIN_MENU, "Previous should be MAIN_MENU")

	tui.tui_state_goto_view(&state, .ALIAS_VIEW)
	testing.expect(t, state.current_view == .ALIAS_VIEW, "Should be at ALIAS_VIEW")
	testing.expect(t, state.previous_view == .PATH_VIEW, "Previous should be PATH_VIEW")
}

@(test)
test_go_back :: proc(t: ^testing.T) {
	state := tui.tui_state_init()
	defer tui.tui_state_destroy(&state)

	// Go to PATH_VIEW then back
	tui.tui_state_goto_view(&state, .PATH_VIEW)
	tui.tui_state_go_back(&state)

	testing.expect(t, state.current_view == .MAIN_MENU, "Should return to MAIN_MENU")
	testing.expect(t, state.previous_view == .PATH_VIEW, "Previous view should be PATH_VIEW")
	testing.expect(t, state.selected_index == 0, "Selected index should reset to 0")
	testing.expect(t, state.scroll_offset == 0, "Scroll offset should reset to 0")
	testing.expect(t, state.needs_refresh == true, "Should need refresh after going back")
}

@(test)
test_go_back_swap :: proc(t: ^testing.T) {
	state := tui.tui_state_init()
	defer tui.tui_state_destroy(&state)

	// Go to PATH_VIEW
	tui.tui_state_goto_view(&state, .PATH_VIEW)
	testing.expect(t, state.current_view == .PATH_VIEW, "Should be at PATH_VIEW")
	testing.expect(t, state.previous_view == .MAIN_MENU, "Previous should be MAIN_MENU")

	// Go back (swap views)
	tui.tui_state_go_back(&state)
	testing.expect(t, state.current_view == .MAIN_MENU, "Should be at MAIN_MENU")
	testing.expect(t, state.previous_view == .PATH_VIEW, "Previous should be PATH_VIEW")

	// Go back again (swap back)
	tui.tui_state_go_back(&state)
	testing.expect(t, state.current_view == .PATH_VIEW, "Should be at PATH_VIEW again")
	testing.expect(t, state.previous_view == .MAIN_MENU, "Previous should be MAIN_MENU again")
}

@(test)
test_move_selection_down :: proc(t: ^testing.T) {
	state := tui.tui_state_init()
	defer tui.tui_state_destroy(&state)

	item_count := 7

	// Move down once
	tui.tui_state_move_selection(&state, 1, item_count)
	testing.expect(t, state.selected_index == 1, "Should move to index 1")

	// Move down again
	tui.tui_state_move_selection(&state, 1, item_count)
	testing.expect(t, state.selected_index == 2, "Should move to index 2")
}

@(test)
test_move_selection_up :: proc(t: ^testing.T) {
	state := tui.tui_state_init()
	defer tui.tui_state_destroy(&state)

	item_count := 7

	// Start at index 0, move up should wrap to end
	tui.tui_state_move_selection(&state, -1, item_count)
	testing.expect(t, state.selected_index == 6, "Should wrap to index 6")

	// Move up again
	tui.tui_state_move_selection(&state, -1, item_count)
	testing.expect(t, state.selected_index == 5, "Should move to index 5")
}

@(test)
test_move_selection_wrap_down :: proc(t: ^testing.T) {
	state := tui.tui_state_init()
	defer tui.tui_state_destroy(&state)

	item_count := 7
	state.selected_index = 6  // Last item

	// Move down should wrap to start
	tui.tui_state_move_selection(&state, 1, item_count)
	testing.expect(t, state.selected_index == 0, "Should wrap to index 0")
}

@(test)
test_move_selection_large_delta :: proc(t: ^testing.T) {
	state := tui.tui_state_init()
	defer tui.tui_state_destroy(&state)

	item_count := 7
	state.selected_index = 1

	// Move down by 10 (should wrap)
	tui.tui_state_move_selection(&state, 10, item_count)
	// (1 + 10) = 11, 11 % 7 = 4
	testing.expect(t, state.selected_index == 4, "Should wrap to index 4")
}

@(test)
test_move_selection_zero_items :: proc(t: ^testing.T) {
	state := tui.tui_state_init()
	defer tui.tui_state_destroy(&state)

	initial_index := state.selected_index

	// Should not change with zero items
	tui.tui_state_move_selection(&state, 1, 0)
	testing.expect(t, state.selected_index == initial_index, "Should not change with zero items")
}

@(test)
test_scroll_update_down :: proc(t: ^testing.T) {
	state := tui.tui_state_init()
	defer tui.tui_state_destroy(&state)

	state.terminal_height = 24
	visible_height := state.terminal_height - 6  // 18 items visible
	item_count := 30

	// Move to item 20 (beyond visible area)
	for i := 0; i < 20; i += 1 {
		tui.tui_state_move_selection(&state, 1, item_count)
	}

	testing.expect(t, state.selected_index == 20, "Should be at index 20")
	// Scroll offset should adjust to keep selection visible
	// scroll_offset = selected_index - visible_height + 1
	// scroll_offset = 20 - 18 + 1 = 3
	testing.expect(t, state.scroll_offset == 3, "Scroll offset should be 3")
}

@(test)
test_scroll_update_up :: proc(t: ^testing.T) {
	state := tui.tui_state_init()
	defer tui.tui_state_destroy(&state)

	state.terminal_height = 24
	item_count := 30

	// Start at bottom with scroll offset
	state.selected_index = 20
	state.scroll_offset = 10

	// Move up to index 5 (above scroll offset)
	state.selected_index = 5
	tui.tui_state_move_selection(&state, 0, item_count)  // Trigger scroll update

	testing.expect(t, state.scroll_offset == 5, "Scroll offset should follow selection up")
}

@(test)
test_needs_refresh_flag :: proc(t: ^testing.T) {
	state := tui.tui_state_init()
	defer tui.tui_state_destroy(&state)

	// Initial state needs refresh
	testing.expect(t, state.needs_refresh == true, "Should need refresh on init")

	// Clear flag
	state.needs_refresh = false

	// goto_view should set flag
	tui.tui_state_goto_view(&state, .PATH_VIEW)
	testing.expect(t, state.needs_refresh == true, "Should need refresh after goto_view")

	// Clear flag
	state.needs_refresh = false

	// go_back should set flag
	tui.tui_state_go_back(&state)
	testing.expect(t, state.needs_refresh == true, "Should need refresh after go_back")

	// Clear flag
	state.needs_refresh = false

	// move_selection should set flag
	tui.tui_state_move_selection(&state, 1, 7)
	testing.expect(t, state.needs_refresh == true, "Should need refresh after move_selection")
}

@(test)
test_get_view_item_count :: proc(t: ^testing.T) {
	state := tui.tui_state_init()
	defer tui.tui_state_destroy(&state)

	// MAIN_MENU
	count := tui.get_view_item_count(&state)
	testing.expect(t, count == 7, "MAIN_MENU should have 7 items")

	// PATH_VIEW
	tui.tui_state_goto_view(&state, .PATH_VIEW)
	count = tui.get_view_item_count(&state)
	testing.expect(t, count == 10, "PATH_VIEW should have 10 items (placeholder)")

	// ALIAS_VIEW
	tui.tui_state_goto_view(&state, .ALIAS_VIEW)
	count = tui.get_view_item_count(&state)
	testing.expect(t, count == 8, "ALIAS_VIEW should have 8 items (placeholder)")
}

@(test)
test_all_view_transitions :: proc(t: ^testing.T) {
	state := tui.tui_state_init()
	defer tui.tui_state_destroy(&state)

	views := []tui.TUIView{
		.MAIN_MENU,
		.PATH_VIEW,
		.ALIAS_VIEW,
		.CONSTANTS_VIEW,
		.COMPLETIONS_VIEW,
		.BACKUPS_VIEW,
		.PLUGINS_VIEW,
		.SETTINGS_VIEW,
	}

	for view in views {
		tui.tui_state_goto_view(&state, view)
		testing.expect(t, state.current_view == view, "Should transition to view")
		testing.expect(t, state.selected_index == 0, "Should reset selection")
		testing.expect(t, state.scroll_offset == 0, "Should reset scroll")
	}
}

@(test)
test_data_cache_init :: proc(t: ^testing.T) {
	state := tui.tui_state_init()
	defer tui.tui_state_destroy(&state)

	testing.expect(t, state.data_cache != nil, "Data cache should be initialized")
	testing.expect(t, len(state.data_cache) == 0, "Data cache should be empty on init")
}
