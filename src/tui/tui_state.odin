package wayu_tui

TUIView :: enum {
	MAIN_MENU,
	PATH_VIEW,
	ALIAS_VIEW,
	CONSTANTS_VIEW,
	COMPLETIONS_VIEW,
	BACKUPS_VIEW,
	PLUGINS_VIEW,
	SETTINGS_VIEW,
}

TUIState :: struct {
	current_view:    TUIView,
	previous_view:   TUIView,
	selected_index:  int,
	scroll_offset:   int,
	terminal_width:  int,
	terminal_height: int,
	needs_refresh:   bool,
	running:         bool,
	data_cache:      map[TUIView]rawptr,
}

// Initialize TUI state
tui_state_init :: proc() -> TUIState {
	return TUIState{
		current_view = .MAIN_MENU,
		previous_view = .MAIN_MENU,
		selected_index = 0,
		scroll_offset = 0,
		terminal_width = 80,
		terminal_height = 24,
		needs_refresh = true,
		running = true,
		data_cache = make(map[TUIView]rawptr),
	}
}

// Destroy state and free resources
tui_state_destroy :: proc(state: ^TUIState) {
	// Free cached data properly - must free strings, dynamic arrays, then pointers
	for key, value in state.data_cache {
		if value != nil {
			// Cast to actual type
			items := cast(^[dynamic]string)value
			if items != nil {
				// Free each string
				for item in items^ {
					delete(item)
				}
				// Free the dynamic array itself
				delete(items^)
				// Free the pointer
				free(items)
			}
		}
	}
	delete(state.data_cache)
}

// Go to new view
tui_state_goto_view :: proc(state: ^TUIState, view: TUIView) {
	state.previous_view = state.current_view
	state.current_view = view
	state.selected_index = 0
	state.scroll_offset = 0
	state.needs_refresh = true
}

// Go back to previous view
tui_state_go_back :: proc(state: ^TUIState) {
	temp := state.current_view
	state.current_view = state.previous_view
	state.previous_view = temp
	state.selected_index = 0
	state.scroll_offset = 0
	state.needs_refresh = true
}

// Move selection up/down
tui_state_move_selection :: proc(state: ^TUIState, delta: int, item_count: int) {
	if item_count == 0 do return

	state.selected_index += delta

	// Wrap around at boundaries (handle large deltas with modulo)
	if state.selected_index < 0 {
		// For negative values, we need to handle modulo properly
		state.selected_index = ((state.selected_index % item_count) + item_count) % item_count
	} else if state.selected_index >= item_count {
		// For positive values, simple modulo works
		state.selected_index = state.selected_index % item_count
	}

	// Update scroll offset to keep selection visible
	visible_height := state.terminal_height - 6  // Header + footer

	if state.selected_index < state.scroll_offset {
		// Scrolled above visible area
		state.scroll_offset = state.selected_index
	} else if state.selected_index >= state.scroll_offset + visible_height {
		// Scrolled below visible area
		state.scroll_offset = state.selected_index - visible_height + 1
	}

	state.needs_refresh = true
}

// Note: get_view_item_count() is now implemented in tui_views.odin
