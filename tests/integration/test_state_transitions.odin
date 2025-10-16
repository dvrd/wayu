package test_state_transitions

import "core:fmt"
import tui "../../src/tui"

main :: proc() {
	fmt.println("=== State Transition Test ===")

	// Test state machine transitions
	state := tui.tui_state_init()
	defer tui.tui_state_destroy(&state)

	fmt.println("\n1. Initial state:")
	assert(state.current_view == .MAIN_MENU, "Should start at MAIN_MENU")
	fmt.println("   ✓ current_view == MAIN_MENU")

	fmt.println("\n2. Navigate to PATH_VIEW:")
	tui.tui_state_goto_view(&state, .PATH_VIEW)
	assert(state.current_view == .PATH_VIEW, "Should be at PATH_VIEW")
	assert(state.previous_view == .MAIN_MENU, "Previous should be MAIN_MENU")
	fmt.println("   ✓ current_view == PATH_VIEW")
	fmt.println("   ✓ previous_view == MAIN_MENU")

	fmt.println("\n3. Go back:")
	tui.tui_state_go_back(&state)
	assert(state.current_view == .MAIN_MENU, "Should be back at MAIN_MENU")
	fmt.println("   ✓ current_view == MAIN_MENU")

	fmt.println("\n4. Test selection movement:")
	tui.tui_state_move_selection(&state, 1, 7)  // Down 1 (7 items)
	assert(state.selected_index == 1, "Should be at index 1")
	fmt.println("   ✓ selected_index == 1 (moved down)")

	fmt.println("\n5. Test wrap-around:")
	tui.tui_state_move_selection(&state, 10, 7)  // Down 10 (wraps)
	assert(state.selected_index == 4, "Should wrap to index 4")  // (1 + 10) % 7 = 4
	fmt.println("   ✓ selected_index == 4 (wrapped)")

	fmt.println("\n6. Test all view transitions:")
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
		assert(state.current_view == view, "Should transition to view")
	}
	fmt.println("   ✓ All 8 views accessible")

	fmt.println("\n=== All State Transition Tests Passed ===")
}
