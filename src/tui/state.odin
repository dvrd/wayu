package wayu_tui

import "core:strings"

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

NotificationKind :: enum {
	NONE,
	SUCCESS,
	ERROR,
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
	// Detail overlay state
	show_detail:     bool,
	detail_title:    string,
	detail_lines:    [dynamic]string,
	// Inline filter state
	filter_active:     bool,
	filter_text:       [dynamic]u8,
	filtered_indices:  [dynamic]int,  // indices into the original cache that match
	// Notification state
	notification_kind:    NotificationKind,
	notification_message: string,
	notification_frames:  int,  // frames remaining before auto-dismiss
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
	// Free detail overlay resources
	clear_detail(state)
	delete(state.detail_lines)

	// Free notification resources
	clear_notification(state)

	// Free inline filter resources
	delete(state.filter_text)
	delete(state.filtered_indices)

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

// Clear detail overlay and free its resources
clear_detail :: proc(state: ^TUIState) {
	state.show_detail = false
	if len(state.detail_title) > 0 {
		delete(state.detail_title)
	}
	state.detail_title = ""
	for line in state.detail_lines {
		delete(line)
	}
	clear(&state.detail_lines)
	state.needs_refresh = true
}

// Show detail overlay with title and content lines
show_detail_overlay :: proc(state: ^TUIState, title: string, lines: []string) {
	clear_detail(state)
	state.show_detail = true
	state.detail_title = strings.clone(title)
	for line in lines {
		append(&state.detail_lines, strings.clone(line))
	}
	state.needs_refresh = true
}

// Go to new view
tui_state_goto_view :: proc(state: ^TUIState, view: TUIView) {
	deactivate_filter(state)
	state.previous_view = state.current_view
	state.current_view = view
	state.selected_index = 0
	state.scroll_offset = 0
	state.needs_refresh = true
}

// Go back to previous view
tui_state_go_back :: proc(state: ^TUIState) {
	deactivate_filter(state)
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
	visible_height := calculate_visible_height(state.terminal_height)

	if state.selected_index < state.scroll_offset {
		// Scrolled above visible area
		state.scroll_offset = state.selected_index
	} else if state.selected_index >= state.scroll_offset + visible_height {
		// Scrolled below visible area
		state.scroll_offset = state.selected_index - visible_height + 1
	}

	state.needs_refresh = true
}

// Activate inline filter mode
activate_filter :: proc(state: ^TUIState) {
	state.filter_active = true
	clear(&state.filter_text)
	clear(&state.filtered_indices)
	state.selected_index = 0
	state.scroll_offset = 0
}

// Deactivate inline filter mode
deactivate_filter :: proc(state: ^TUIState) {
	state.filter_active = false
	clear(&state.filter_text)
	clear(&state.filtered_indices)
	state.selected_index = 0
	state.scroll_offset = 0
}

// Case-insensitive substring match
matches_filter :: proc(item: string, filter: []u8) -> bool {
	if len(filter) == 0 { return true }
	filter_str := string(filter[:])

	// Simple case-insensitive contains
	lower_item := strings.to_lower(item)
	lower_filter := strings.to_lower(filter_str)
	defer delete(lower_item)
	defer delete(lower_filter)
	return strings.contains(lower_item, lower_filter)
}

// Rebuild filtered_indices based on current filter_text and cache
apply_filter :: proc(state: ^TUIState, items: []string) {
	clear(&state.filtered_indices)
	for item, i in items {
		if matches_filter(item, state.filter_text[:]) {
			append(&state.filtered_indices, i)
		}
	}
	if state.selected_index >= len(state.filtered_indices) {
		state.selected_index = max(0, len(state.filtered_indices) - 1)
	}
	state.scroll_offset = 0
}

// Get the current view's cache items as a string slice
get_current_cache :: proc(state: ^TUIState) -> []string {
	view := state.current_view
	if state.data_cache[view] == nil {
		return nil
	}
	items := cast(^[dynamic]string)state.data_cache[view]
	if items == nil {
		return nil
	}
	return items[:]
}

// ============================================================================
// Notification helpers
// ============================================================================

NOTIFICATION_FRAMES_SUCCESS :: 150  // ~3 seconds at 50fps
NOTIFICATION_FRAMES_ERROR   :: 200  // ~4 seconds at 50fps

// Set a notification message with auto-dismiss countdown
set_notification :: proc(state: ^TUIState, kind: NotificationKind, message: string) {
	clear_notification(state)
	state.notification_kind = kind
	state.notification_message = strings.clone(message)
	if kind == .SUCCESS {
		state.notification_frames = NOTIFICATION_FRAMES_SUCCESS
	} else {
		state.notification_frames = NOTIFICATION_FRAMES_ERROR
	}
	state.needs_refresh = true
}

// Clear the current notification and free its message
clear_notification :: proc(state: ^TUIState) {
	if len(state.notification_message) > 0 {
		delete(state.notification_message)
	}
	state.notification_message = ""
	state.notification_kind = .NONE
	state.notification_frames = 0
}

// Tick the notification countdown; clears when expired
tick_notification :: proc(state: ^TUIState) {
	if state.notification_kind == .NONE { return }
	state.notification_frames -= 1
	if state.notification_frames <= 0 {
		clear_notification(state)
		state.needs_refresh = true
	}
}

// Note: get_view_item_count() is now implemented in tui_views.odin
