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

// Saved cursor position for a view (selected_index + scroll_offset)
ViewCursor :: struct {
	selected_index: int,
	scroll_offset:  int,
}

// Add form state — rendered as a modal overlay over the current view
AddForm :: struct {
	active:        bool,
	view:          TUIView,
	field_index:   int,       // 0..field_count-1 = fields; field_count = CANCEL btn; field_count+1 = ADD btn
	field_count:   int,       // 1 for PATH, 2 for ALIAS/CONSTANTS
	label_0:       string,    // e.g. "PATH", "NAME"
	label_1:       string,    // e.g. "", "COMMAND", "VALUE"
	input_0:       [dynamic]u8,
	input_1:       [dynamic]u8,
	error_message: string,    // points into temp allocator — do NOT delete
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
	// Per-view cursor memory — remembers selection when navigating away
	saved_cursors:   map[TUIView]ViewCursor,
	// Detail overlay state
	show_detail:     bool,
	detail_title:    string,
	detail_lines:    [dynamic]string,
	// Add form state — modal overlay for adding new entries
	add_form: AddForm,
	// Delete confirmation state — when set, the detail overlay acts as a confirm dialog
	confirm_delete_pending:        bool,
	confirm_delete_view:           TUIView,
	confirm_delete_name:           string,  // heap-cloned name to delete (freed on clear)
	confirm_delete_focused_delete: bool,    // true = DELETE button focused, false = CANCEL focused
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
		saved_cursors = make(map[TUIView]ViewCursor),
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

	// Free saved cursors map
	delete(state.saved_cursors)

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

// Clear detail overlay and free its resources (also clears any pending delete)
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
	// Clear pending delete confirmation
	if state.confirm_delete_pending {
		if len(state.confirm_delete_name) > 0 {
			delete(state.confirm_delete_name)
		}
		state.confirm_delete_name = ""
		state.confirm_delete_pending = false
	}
	state.needs_refresh = true
}

// Show a delete confirmation overlay for the given item
show_delete_confirmation :: proc(state: ^TUIState, view: TUIView, display_name: string, delete_key: string) {
	clear_detail(state)
	state.show_detail = true
	state.detail_title = strings.clone("DELETE CONFIRMATION")
	append(&state.detail_lines, strings.clone(display_name))
	append(&state.detail_lines, strings.clone(""))
	append(&state.detail_lines, strings.clone("This action cannot be undone."))
	append(&state.detail_lines, strings.clone("A backup will be created automatically."))
	state.confirm_delete_pending = true
	state.confirm_delete_view = view
	state.confirm_delete_name = strings.clone(delete_key)
	state.confirm_delete_focused_delete = false  // start focused on CANCEL (safe default)
	state.needs_refresh = true
}

// Clear add form and free its input buffers
clear_add_form :: proc(state: ^TUIState) {
	state.add_form.active        = false
	state.add_form.error_message = ""
	clear(&state.add_form.input_0)
	clear(&state.add_form.input_1)
	state.needs_refresh = true
}

// Open add form modal for the given view
show_add_form :: proc(state: ^TUIState, view: TUIView) {
	clear_add_form(state)
	state.add_form.active      = true
	state.add_form.view        = view
	state.add_form.field_index = 0
	#partial switch view {
	case .PATH_VIEW:
		state.add_form.field_count = 1
		state.add_form.label_0     = "PATH"
		state.add_form.label_1     = ""
	case .ALIAS_VIEW:
		state.add_form.field_count = 2
		state.add_form.label_0     = "NAME"
		state.add_form.label_1     = "COMMAND"
	case .CONSTANTS_VIEW:
		state.add_form.field_count = 2
		state.add_form.label_0     = "NAME"
		state.add_form.label_1     = "VALUE"
	case:
		// unsupported view — close immediately
		state.add_form.active = false
		return
	}
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

// Save current cursor position for the active view
save_cursor :: proc(state: ^TUIState) {
	state.saved_cursors[state.current_view] = ViewCursor{
		selected_index = state.selected_index,
		scroll_offset  = state.scroll_offset,
	}
}

// Restore cursor position for a view (defaults to 0,0 if never visited)
restore_cursor :: proc(state: ^TUIState, view: TUIView) {
	if cursor, ok := state.saved_cursors[view]; ok {
		state.selected_index = cursor.selected_index
		state.scroll_offset  = cursor.scroll_offset
	} else {
		state.selected_index = 0
		state.scroll_offset  = 0
	}
}

// Go to new view (saves cursor of current view, restores target view cursor)
tui_state_goto_view :: proc(state: ^TUIState, view: TUIView) {
	save_cursor(state)          // Save BEFORE deactivate_filter clobbers selected_index
	deactivate_filter(state)
	state.previous_view = state.current_view
	state.current_view = view
	restore_cursor(state, view)
	state.needs_refresh = true
}

// Go back to previous view (saves cursor of current view, restores previous view cursor)
tui_state_go_back :: proc(state: ^TUIState) {
	save_cursor(state)          // Save BEFORE deactivate_filter clobbers selected_index
	deactivate_filter(state)
	temp := state.current_view
	state.current_view = state.previous_view
	state.previous_view = temp
	restore_cursor(state, state.current_view)
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

// ASCII lowercase of a single byte. Non-ASCII bytes pass through unchanged.
@(private="file")
ascii_lower :: proc(c: u8) -> u8 {
	if c >= 'A' && c <= 'Z' {
		return c + 32
	}
	return c
}

// Case-insensitive substring match — zero allocations.
// Compares byte-by-byte with inline ASCII lowering. Safe for shell
// paths, aliases, and constants which are ASCII-only.
matches_filter :: proc(item: string, filter: []u8) -> bool {
	if len(filter) == 0 { return true }
	item_bytes := transmute([]u8)item
	if len(filter) > len(item_bytes) { return false }

	// Sliding window: check each starting position in item.
	outer: for i in 0..=len(item_bytes) - len(filter) {
		for j in 0..<len(filter) {
			if ascii_lower(item_bytes[i + j]) != ascii_lower(filter[j]) {
				continue outer
			}
		}
		return true
	}
	return false
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
