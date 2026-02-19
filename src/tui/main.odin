package wayu_tui

import "core:fmt"
import "base:intrinsics"
import "core:mem"
import "core:os"
import "core:strings"

// Main TUI entry point
tui_run :: proc() {
	// Check if we're in a TTY first
	if !is_stdin_tty() || !is_stdout_tty() {
		fmt.eprintln("Error: TUI requires an interactive terminal (TTY)")
		fmt.eprintln("Cannot run TUI when stdin or stdout is not a terminal")
		os.exit(1)
	}

	// Initialize all subsystems
	tui_init()
	defer tui_cleanup()

	// Get initial terminal size
	width, height, ok := get_terminal_size()
	if !ok {
		width, height = 80, 24  // Fallback
	}
	// Create screen buffer
	screen := screen_create(width, height)
	defer screen_destroy(&screen)

	// Initialize state machine
	state := tui_state_init()
	state.terminal_width = width
	state.terminal_height = height
	state.needs_refresh = true  // Force initial render
	defer tui_state_destroy(&state)

	first_frame := true  // Track first frame for full render

	// Main event loop (The Elm Architecture)
	for state.running {
		// Handle terminal resize (volatile load/store for signal handler safety)
		if intrinsics.volatile_load(&terminal_resized) {
			new_width, new_height, _ := get_terminal_size()
			screen_resize(&screen, new_width, new_height)
			state.terminal_width = new_width
			state.terminal_height = new_height
			state.needs_refresh = true
			intrinsics.volatile_store(&terminal_resized, false)
		}

		// Ensure data is loaded for current view (lazy loading)
		tui_ensure_data_loaded(&state, state.current_view)

		// Render current state
		if state.needs_refresh {
			tui_render(&state, &screen)
			screen_flush(&screen, first_frame)  // Force full render on first frame
			state.needs_refresh = false
			first_frame = false
		}

		// Poll for events (non-blocking)
		event := poll_event()
		if event == nil {
			continue  // No input, loop again
		}

		// Update state based on event
		tui_handle_event(&state, event)

		// Tick notification countdown
		tick_notification(&state)
	}

}

// Initialize TUI subsystems
tui_init :: proc() {
	tui_lifecycle_init()  // Enter alt screen, hide cursor, setup signals
	if !enable_raw_mode() {
		fmt.eprintln("Error: Failed to enable raw mode")
		os.exit(1)
	}
}

// Cleanup TUI subsystems
tui_cleanup :: proc() {
	disable_raw_mode()         // Restore cooked mode
	tui_lifecycle_cleanup()    // Exit alt screen, show cursor
}

// Handle single event and update state
tui_handle_event :: proc(state: ^TUIState, event: Event) {
	#partial switch e in event {
	case KeyEvent:
		handle_key_event(state, e)
	case ResizeEvent:
		// Already handled in main loop via terminal_resized flag
	}
}

// Handle keyboard events
handle_key_event :: proc(state: ^TUIState, key: KeyEvent) {
	// Global keys (work in all views, even in filter mode)
	if .Ctrl in key.modifiers && key.char == 'c' {
		state.running = false
		return
	}

	// When add form is active, route ALL input to add form handler
	if state.add_form.active {
		handle_add_form_input(state, key)
		return
	}

	// Handle detail overlay dismissal (and delete confirmation)
	if state.show_detail {
		if state.confirm_delete_pending {
			// Delete confirmation mode: h/l move focus, Enter confirms focused button, Esc always cancels
			if key.key == .Escape {
				clear_detail(state)
			} else if key.key == .Char && (key.char == 'h' || key.char == 'l') {
				state.confirm_delete_focused_delete = !state.confirm_delete_focused_delete
				state.needs_refresh = true
			} else if key.key == .Enter {
				if state.confirm_delete_focused_delete {
					execute_pending_delete(state)
				} else {
					clear_detail(state)
				}
			}
		} else {
			// Normal detail overlay: Esc/Enter/q dismiss
			if key.key == .Escape || key.key == .Enter || (key.key == .Char && key.char == 'q') {
				clear_detail(state)
			}
		}
		return
	}

	// When filter is active, route ALL input to filter handler
	if state.filter_active {
		handle_filter_input(state, key)
		return
	}

	// Allow 'q' to quit from main menu
	if state.current_view == .MAIN_MENU {
		if key.key == .Escape || (key.key == .Char && key.char == 'q') {
			state.running = false
			return
		}
	}

	// Navigation keys
	#partial switch key.key {
	case .Up:
		item_count := get_view_item_count(state)
		tui_state_move_selection(state, -1, item_count)

	case .Down:
		item_count := get_view_item_count(state)
		tui_state_move_selection(state, 1, item_count)

	case .Char:
		// Vim-style navigation
		if key.char == 'k' {
			item_count := get_view_item_count(state)
			tui_state_move_selection(state, -1, item_count)
		} else if key.char == 'j' {
			item_count := get_view_item_count(state)
			tui_state_move_selection(state, 1, item_count)
		} else if key.char == 'l' {
			// Vim-style enter/select
			handle_selection(state)
		} else if key.char == 'h' {
			// Vim-style go back
			if state.current_view != .MAIN_MENU {
				tui_state_go_back(state)
			}
		} else {
			// Pass other character keys to view-specific handler
			handle_view_event(state, key)
		}

	case .Enter:
		handle_selection(state)

	case .Escape:
		if state.current_view != .MAIN_MENU {
			tui_state_go_back(state)
		}
	}
}

// Handle selection in current view
handle_selection :: proc(state: ^TUIState) {
	switch state.current_view {
	case .MAIN_MENU:
		// Navigate to selected view
		menu_items := []TUIView{
			.PATH_VIEW,
			.ALIAS_VIEW,
			.CONSTANTS_VIEW,
			.COMPLETIONS_VIEW,
			.BACKUPS_VIEW,
			.PLUGINS_VIEW,
			.SETTINGS_VIEW,
		}
		if state.selected_index >= 0 && state.selected_index < len(menu_items) {
			tui_state_goto_view(state, menu_items[state.selected_index])
		}

	case .PATH_VIEW:
		if state.data_cache[.PATH_VIEW] != nil {
			items := cast(^[dynamic]string)state.data_cache[.PATH_VIEW]
			if state.selected_index >= 0 && state.selected_index < len(items) {
				selected := items[state.selected_index]
				detail_lines := tui_get_path_detail(selected)
				// Convert dynamic array to slice for show_detail_overlay
				show_detail_overlay(state, selected, detail_lines[:])
				// Free the returned dynamic array (show_detail_overlay clones)
				for line in detail_lines {
					delete(line)
				}
				delete(detail_lines)
			}
		}

	case .ALIAS_VIEW:
		if state.data_cache[.ALIAS_VIEW] != nil {
			items := cast(^[dynamic]string)state.data_cache[.ALIAS_VIEW]
			if state.selected_index >= 0 && state.selected_index < len(items) {
				selected := items[state.selected_index]
				// Scratch arena for split + detail strings — show_detail_overlay clones,
				// so everything here can be freed in bulk when scope ends.
				scratch_buf: [1024]byte
				scratch: mem.Arena
				mem.arena_init(&scratch, scratch_buf[:])
				scratch_alloc := mem.arena_allocator(&scratch)

				parts := strings.split(selected, "=", scratch_alloc)
				if len(parts) >= 2 {
					joined_cmd := strings.join(parts[1:], "=", scratch_alloc)
					line1 := fmt.aprintf("Name: %s", parts[0], allocator = scratch_alloc)
					line2 := fmt.aprintf("Command: %s", joined_cmd, allocator = scratch_alloc)
					lines := []string{line1, line2}
					show_detail_overlay(state, parts[0], lines)
				} else {
					lines := []string{selected}
					show_detail_overlay(state, "Alias", lines)
				}
			}
		}

	case .CONSTANTS_VIEW:
		if state.data_cache[.CONSTANTS_VIEW] != nil {
			items := cast(^[dynamic]string)state.data_cache[.CONSTANTS_VIEW]
			if state.selected_index >= 0 && state.selected_index < len(items) {
				selected := items[state.selected_index]
				// Scratch arena for split + detail strings — show_detail_overlay clones,
				// so everything here can be freed in bulk when scope ends.
				scratch_buf: [1024]byte
				scratch: mem.Arena
				mem.arena_init(&scratch, scratch_buf[:])
				scratch_alloc := mem.arena_allocator(&scratch)

				parts := strings.split(selected, "=", scratch_alloc)
				if len(parts) >= 2 {
					value := strings.join(parts[1:], "=", scratch_alloc)
					line1 := fmt.aprintf("Name: %s", parts[0], allocator = scratch_alloc)
					line2 := fmt.aprintf("Value: %s", value, allocator = scratch_alloc)
					lines := []string{line1, line2}
					show_detail_overlay(state, parts[0], lines)
				} else {
					lines := []string{selected}
					show_detail_overlay(state, "Constant", lines)
				}
			}
		}

	case .COMPLETIONS_VIEW:
		if state.data_cache[.COMPLETIONS_VIEW] != nil {
			items := cast(^[dynamic]string)state.data_cache[.COMPLETIONS_VIEW]
			if state.selected_index >= 0 && state.selected_index < len(items) {
				selected := items[state.selected_index]
				// Scratch arena — only one string here but arena protects against future additions.
				scratch_buf: [512]byte
				scratch: mem.Arena
				mem.arena_init(&scratch, scratch_buf[:])
				scratch_alloc := mem.arena_allocator(&scratch)

				line1 := fmt.aprintf("Script: %s", selected, allocator = scratch_alloc)
				lines := []string{line1}
				show_detail_overlay(state, selected, lines)
			}
		}

	case .BACKUPS_VIEW:
		if state.data_cache[.BACKUPS_VIEW] != nil {
			items := cast(^[dynamic]string)state.data_cache[.BACKUPS_VIEW]
			if state.selected_index >= 0 && state.selected_index < len(items) {
				selected := items[state.selected_index]
				// Scratch arena for split + detail strings — show_detail_overlay clones,
				// so everything here can be freed in bulk when scope ends.
				scratch_buf: [512]byte
				scratch: mem.Arena
				mem.arena_init(&scratch, scratch_buf[:])
				scratch_alloc := mem.arena_allocator(&scratch)

				// Parse backup filename: e.g. "path.zsh.backup.2024-03-15_14-30-00"
				parts := strings.split(selected, ".backup.", scratch_alloc)
				if len(parts) >= 2 {
					line1 := fmt.aprintf("Config: %s", parts[0], allocator = scratch_alloc)
					line2 := fmt.aprintf("Timestamp: %s", parts[1], allocator = scratch_alloc)
					lines := []string{line1, line2}
					show_detail_overlay(state, "Backup Detail", lines)
				} else {
					lines := []string{selected}
					show_detail_overlay(state, "Backup", lines)
				}
			}
		}

	case .PLUGINS_VIEW:
		// No detail for plugins yet

	case .SETTINGS_VIEW:
		// No detail for settings
	}
}

// Execute a confirmed delete operation. Called when user presses 'y' on the confirm overlay.
execute_pending_delete :: proc(state: ^TUIState) {
	if !state.confirm_delete_pending { return }

	view := state.confirm_delete_view
	name := state.confirm_delete_name
	item_count := get_view_item_count(state)

	success := false
	switch view {
	case .PATH_VIEW:
		success = tui_delete_path(name)
	case .ALIAS_VIEW:
		success = tui_delete_alias(name)
	case .CONSTANTS_VIEW:
		success = tui_delete_constant(name)
	case .MAIN_MENU, .COMPLETIONS_VIEW, .BACKUPS_VIEW, .PLUGINS_VIEW, .SETTINGS_VIEW:
		// No delete for these views
	}

	// Dismiss the overlay (this also frees confirm_delete_name)
	clear_detail(state)

	if success {
		label: string
		switch view {
		case .PATH_VIEW:     label = "PATH entry"
		case .ALIAS_VIEW:    label = "alias"
		case .CONSTANTS_VIEW: label = "constant"
		case .MAIN_MENU, .COMPLETIONS_VIEW, .BACKUPS_VIEW, .PLUGINS_VIEW, .SETTINGS_VIEW:
			label = "entry"
		}
		msg := fmt.tprintf("Removed %s: %s", label, name)
		set_notification(state, .SUCCESS, msg)

		// Clear cache to force reload
		clear_view_cache(state, view)

		// Preserve cursor position: only adjust if was on last item
		if state.selected_index >= item_count - 1 {
			state.selected_index = max(0, item_count - 2)
		}
		if state.selected_index < state.scroll_offset {
			state.scroll_offset = state.selected_index
		}
	} else {
		err_msg := ""
		if g_get_last_error != nil {
			err_msg = g_get_last_error()
		}
		if len(err_msg) > 0 {
			set_notification(state, .ERROR, err_msg)
		} else {
			set_notification(state, .ERROR, fmt.tprintf("Failed to delete: %s", name))
		}
	}

	state.needs_refresh = true
}

// Render current state to screen
tui_render :: proc(state: ^TUIState, screen: ^Screen) {
	// Clear screen
	screen_clear(screen)

	// Render based on current view
	switch state.current_view {
	case .MAIN_MENU:
		render_main_menu(state, screen)

	case .PATH_VIEW:
		render_path_view(state, screen)

	case .ALIAS_VIEW:
		render_alias_view(state, screen)

	case .CONSTANTS_VIEW:
		render_constants_view(state, screen)

	case .COMPLETIONS_VIEW:
		render_completions_view(state, screen)

	case .BACKUPS_VIEW:
		render_backups_view(state, screen)

	case .PLUGINS_VIEW:
		render_plugins_view(state, screen)

	case .SETTINGS_VIEW:
		render_settings_view(state, screen)
	}

	// Render notification bar (below content box)
	render_notification(state, screen)

	// Render detail overlay on top if active
	render_detail_overlay(state, screen)

	// Render add form overlay on top of everything if active
	render_add_form_overlay(state, screen)
}

// Render main menu — dashboard-style with accent bars and dividers
render_main_menu :: proc(state: ^TUIState, screen: ^Screen) {
	// Draw outer border using calculated dimensions
	border_width, border_height := calculate_border_dimensions(state.terminal_width, state.terminal_height)
	render_box_styled(screen, BORDER_LEFT_WIDTH, BORDER_TOP_HEIGHT, border_width, border_height, TUI_BORDER_FOCUSED)

	// Content area x position
	header_x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT

	// Header with accent bar (Dribbble dashboard style)
	title_y := HEADER_TITLE_LINE + CONTENT_PADDING_TOP
	// Accent bar ┃ before title
	screen_set_cell(screen, header_x, title_y, Cell{char = BOX_HEAVY_VERTICAL, fg = TUI_PRIMARY, bold = true})
	screen_set_cell(screen, header_x, title_y + 1, Cell{char = BOX_HEAVY_VERTICAL, fg = TUI_PRIMARY, bold = true})
	render_text_styled(screen, header_x + MENU_ACCENT_BAR_WIDTH + MENU_ACCENT_GAP, title_y, "WAYU", TUI_PRIMARY, "", true)
	render_text_styled(screen, header_x + MENU_ACCENT_BAR_WIDTH + MENU_ACCENT_GAP, title_y + 1, "Shell Configuration Manager", TUI_DIM)

	// Header divider line
	divider_y := LIST_ITEM_START_LINE
	divider_width := border_width - CONTENT_PADDING_LEFT - 2  // Inset from both sides
	for dx in 0..<divider_width {
		screen_set_cell(screen, header_x + dx, divider_y, Cell{char = BOX_HORIZONTAL, fg = TUI_DIVIDER})
	}

	// Menu items with dividers between them
	menu_items := []string{
		"PATH Configuration",
		"Aliases",
		"Environment Constants",
		"Completions",
		"Backups",
		"Plugins",
		"Settings",
	}

	// First item starts after header divider + 1 blank line
	menu_start_y := divider_y + 2
	text_x := header_x + MENU_ACCENT_BAR_WIDTH + MENU_ACCENT_GAP

	for item, i in menu_items {
		y := menu_start_y + (i * MENU_ITEM_SPACING)

		if i == state.selected_index {
			// Selected: accent bar ┃ + bold primary text
			screen_set_cell(screen, header_x, y, Cell{char = BOX_HEAVY_VERTICAL, fg = TUI_PRIMARY, bold = true})
			render_text_styled(screen, text_x, y, item, TUI_PRIMARY, "", true)
		} else {
			// Normal: no accent bar, muted text at same x
			render_text_styled(screen, text_x, y, item, TUI_MUTED)
		}

		// Divider line after each item (except the last)
		if i < len(menu_items) - 1 {
			sep_y := y + 1
			for dx in 0..<divider_width {
				screen_set_cell(screen, header_x + dx, sep_y, Cell{char = BOX_HORIZONTAL, fg = TUI_DIVIDER})
			}
		}
	}

	// Footer — compact keyboard shortcuts
	footer_y := calculate_footer_y(state.terminal_height)
	render_text_styled(screen, header_x, footer_y, "j/k Navigate   l Select   q Quit", TUI_DIM)
}

// Handle keyboard input when filter mode is active
handle_filter_input :: proc(state: ^TUIState, key: KeyEvent) {
	#partial switch key.key {
	case .Escape:
		// Cancel filter, return to normal mode
		deactivate_filter(state)
		state.needs_refresh = true

	case .Enter:
		// Accept filter result and exit filter mode
		// Keep the current selection position
		state.filter_active = false
		// Don't clear filter_text or filtered_indices — keep the filtered view
		state.needs_refresh = true

	case .Backspace:
		// Remove last character from filter
		if len(state.filter_text) > 0 {
			pop(&state.filter_text)
			cache := get_current_cache(state)
			if cache != nil {
				apply_filter(state, cache)
			}
			state.needs_refresh = true
		}

	case .Up:
		// Navigate within filtered results
		item_count := len(state.filtered_indices)
		if item_count == 0 {
			item_count = get_view_item_count(state)
		}
		tui_state_move_selection(state, -1, item_count)

	case .Down:
		// Navigate within filtered results
		item_count := len(state.filtered_indices)
		if item_count == 0 {
			item_count = get_view_item_count(state)
		}
		tui_state_move_selection(state, 1, item_count)

	case .Char:
		if key.char == 'k' && .Ctrl in key.modifiers {
			// Ctrl+K: navigate up in filter mode
			item_count := len(state.filtered_indices)
			if item_count == 0 {
				item_count = get_view_item_count(state)
			}
			tui_state_move_selection(state, -1, item_count)
		} else if key.char == 'j' && .Ctrl in key.modifiers {
			// Ctrl+J: navigate down in filter mode
			item_count := len(state.filtered_indices)
			if item_count == 0 {
				item_count = get_view_item_count(state)
			}
			tui_state_move_selection(state, 1, item_count)
		} else if .Ctrl not_in key.modifiers {
			// Printable character: add to filter
			append(&state.filter_text, u8(key.char))
			cache := get_current_cache(state)
			if cache != nil {
				apply_filter(state, cache)
			}
			state.needs_refresh = true
		}
	}
}

// Handle keyboard input when add form modal is active
handle_add_form_input :: proc(state: ^TUIState, key: KeyEvent) {
	#partial switch key.key {
	case .Escape:
		clear_add_form(state)

	case .Tab:
		// Cycle fields only when there are two fields
		if state.add_form.field_count == 2 {
			if state.add_form.field_index == 0 {
				state.add_form.field_index = 1
			} else {
				state.add_form.field_index = 0
			}
			state.needs_refresh = true
		}

	case .Backspace:
		if state.add_form.field_index == 0 {
			if len(state.add_form.input_0) > 0 {
				pop(&state.add_form.input_0)
				state.needs_refresh = true
			}
		} else {
			if len(state.add_form.input_1) > 0 {
				pop(&state.add_form.input_1)
				state.needs_refresh = true
			}
		}

	case .Enter:
		execute_add_form(state)

	case .Char:
		// Only accept printable characters (no Ctrl combos)
		if .Ctrl not_in key.modifiers {
			if state.add_form.field_index == 0 {
				append(&state.add_form.input_0, u8(key.char))
			} else {
				append(&state.add_form.input_1, u8(key.char))
			}
			state.needs_refresh = true
		}
	}
}

// Execute the add form: validate, call bridge, update state
execute_add_form :: proc(state: ^TUIState) {
	val_0 := string(state.add_form.input_0[:])
	val_1 := string(state.add_form.input_1[:])

	// Validate: first field must be non-empty
	if len(val_0) == 0 {
		state.add_form.error_message = fmt.tprintf("Error: %s cannot be empty", state.add_form.label_0)
		state.needs_refresh = true
		return
	}
	// For two-field forms, second field must also be non-empty
	if state.add_form.field_count == 2 && len(val_1) == 0 {
		state.add_form.error_message = fmt.tprintf("Error: %s cannot be empty", state.add_form.label_1)
		state.needs_refresh = true
		return
	}

	view := state.add_form.view
	success := false
	switch view {
	case .PATH_VIEW:
		success = tui_add_path(val_0)
	case .ALIAS_VIEW:
		success = tui_add_alias(val_0, val_1)
	case .CONSTANTS_VIEW:
		success = tui_add_constant(val_0, val_1)
	case .MAIN_MENU, .COMPLETIONS_VIEW, .BACKUPS_VIEW, .PLUGINS_VIEW, .SETTINGS_VIEW:
		// unsupported
	}

	if success {
		label: string
		switch view {
		case .PATH_VIEW:      label = "PATH entry"
		case .ALIAS_VIEW:     label = "alias"
		case .CONSTANTS_VIEW: label = "constant"
		case .MAIN_MENU, .COMPLETIONS_VIEW, .BACKUPS_VIEW, .PLUGINS_VIEW, .SETTINGS_VIEW:
			label = "entry"
		}
		msg := fmt.tprintf("Added %s: %s", label, val_0)
		clear_add_form(state)
		clear_view_cache(state, view)
		set_notification(state, .SUCCESS, msg)
	} else {
		err_msg := ""
		if g_get_last_error != nil {
			err_msg = g_get_last_error()
		}
		if len(err_msg) > 0 {
			state.add_form.error_message = fmt.tprintf("Error: %s", err_msg)
		} else {
			state.add_form.error_message = fmt.tprintf("Error: failed to add %s", val_0)
		}
		state.needs_refresh = true
	}
}

// Note: View rendering functions are now in tui_views.odin
// render_path_view, render_alias_view, render_constants_view,
// render_completions_view, render_backups_view, render_plugins_view,
// render_settings_view are all implemented in tui_views.odin
