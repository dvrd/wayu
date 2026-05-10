package wayu
import "core:fmt"
import "base:intrinsics"
import "core:mem"
import "core:os"
import "core:strings"
import "core:unicode/utf8"
// Main TUI entry point
tui_run :: proc() {
	// Check if we're in a TTY first
	if !is_stdin_tty() || !is_stdout_tty() {
		fmt.eprintln("Error: TUI requires an interactive terminal (TTY)")
		fmt.eprintln("Cannot run TUI when stdin or stdout is not a terminal")
		os.exit(EXIT_GENERAL)
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
		os.exit(EXIT_OSERR)
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
			// Delete confirmation mode: h/l/Tab toggle focus, Enter confirms focused button, Esc always cancels
			if key.key == .Escape {
				clear_detail(state)
			} else if key.key == .Tab || (key.key == .Char && (key.char == 'h' || key.char == 'l')) {
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

	case .Tab:
		// Route Tab to the current view handler (e.g. plugins tab switcher)
		handle_view_event(state, key)

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
		// Give the plugins view first crack at Enter (registry install).
		// For all other views, fall through to handle_selection.
		if state.current_view == .PLUGINS_VIEW {
			handle_view_event(state, key)
		} else {
			handle_selection(state)
		}

	case .Escape:
		if state.current_view != .MAIN_MENU {
			tui_state_go_back(state)
		}
	}
}

// Handle selection in current view
handle_selection :: proc(state: ^TUIState) {
	// Shared scratch arena for the whole proc. Only one `case` runs per call,
	// so a single 2KB buffer covers every sub-case that previously declared
	// its own [512]byte or [1024]byte arena. The buffer dies with this stack
	// frame once the proc returns. Reduces 5 copies of scratch boilerplate
	// to one declaration. See thoughts/code_review_2026-04-24.md N4.
	scratch_buf: [2048]byte
	scratch: mem.Arena
	mem.arena_init(&scratch, scratch_buf[:])
	scratch_alloc := mem.arena_allocator(&scratch)

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
			.HOOKS_VIEW,
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
		// Show plugin detail or placeholder message
		if state.plugin_tab == PLUGIN_TAB_INSTALLED {
			if state.data_cache[.PLUGINS_VIEW] != nil {
				items := cast(^[dynamic]string)state.data_cache[.PLUGINS_VIEW]
				if state.selected_index >= 0 && state.selected_index < len(items) {
					selected := items[state.selected_index]
					// Parse plugin info: "name | source | status | priority"
					parts := strings.split(selected, " | ", context.temp_allocator)
					if len(parts) >= 1 {
						plugin_name := parts[0]
						line1 := fmt.tprintf("Plugin: %s", plugin_name)
						line2 := "Plugin detail view coming soon"
						lines := []string{line1, line2}
						show_detail_overlay(state, "Plugin Detail", lines)
					}
				}
			}
		} else {
			// Registry tab - show selected plugin info
			if state.plugin_registry_cache != nil {
				items := state.plugin_registry_cache
				idx := state.selected_index
				if len(state.filtered_indices) > 0 {
					if idx >= 0 && idx < len(state.filtered_indices) {
						idx = state.filtered_indices[idx]
					} else {
						return
					}
				}
				if idx >= 0 && idx < len(items^) {
					item := items[idx]
					// Parse: key\x00category\x00shell\x00description
					parts := strings.split(item, "\x00", context.temp_allocator)
					if len(parts) >= 1 {
						plugin_key := parts[0]
						line1 := fmt.tprintf("Plugin: %s", plugin_key)
						line2 := "Press 'i' or Enter to install"
						if len(parts) >= 4 {
							line2 = fmt.tprintf("Description: %s", parts[3])
						}
						lines := []string{line1, line2}
						show_detail_overlay(state, "Plugin Registry", lines)
					}
				}
			}
		}

	case .HOOKS_VIEW:
		// Show hooks view placeholder
		lines := []string{"Hooks view coming soon"}
		show_detail_overlay(state, "Hooks", lines)

	case .SETTINGS_VIEW:
		// Show settings info placeholder
		lines := []string{"Settings view coming soon"}
		show_detail_overlay(state, "Settings", lines)
	}
}

// Execute a confirmed delete operation. Called when user presses 'y' on the confirm overlay.
execute_pending_delete :: proc(state: ^TUIState) {
	if !state.confirm_delete_pending { return }

	view := state.confirm_delete_view
	name := state.confirm_delete_name
	item_count := get_view_item_count(state)

	success := false
	err_msg := ""
	switch view {
	case .PATH_VIEW:
		success, err_msg = entry_remove(EntryPath{path = name})
	case .ALIAS_VIEW:
		success, err_msg = entry_remove(EntryAlias{name = name})
	case .CONSTANTS_VIEW:
		success, err_msg = entry_remove(EntryConst{name = name})
	case .MAIN_MENU, .COMPLETIONS_VIEW, .BACKUPS_VIEW, .PLUGINS_VIEW, .HOOKS_VIEW, .SETTINGS_VIEW:
		// No delete for these views
	}
	defer if len(err_msg) > 0 do delete(err_msg)

	// Dismiss the overlay (this also frees confirm_delete_name)
	clear_detail(state)

	if success {
		label: string
		switch view {
		case .PATH_VIEW:     label = "PATH entry"
		case .ALIAS_VIEW:    label = "alias"
		case .CONSTANTS_VIEW: label = "constant"
		case .MAIN_MENU, .COMPLETIONS_VIEW, .BACKUPS_VIEW, .PLUGINS_VIEW, .HOOKS_VIEW, .SETTINGS_VIEW:
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
		render_list_view(state, screen, ListViewConfig{
			view_key     = .PATH_VIEW,
			title        = "PATH CONFIGURATION",
			count_format = "%d entries",
			row_kind     = .Single,
			empty_line_1 = "No PATH entries found",
			footer       = get_footer_data_view(state.terminal_width),
		})

	case .ALIAS_VIEW:
		render_list_view(state, screen, ListViewConfig{
			view_key     = .ALIAS_VIEW,
			title        = "ALIASES",
			count_format = "%d aliases",
			row_kind     = .Table,
			col_label_0  = "ALIAS",
			col_label_1  = "COMMAND",
			empty_line_1 = "No aliases found",
			footer       = get_footer_data_view(state.terminal_width),
		})

	case .CONSTANTS_VIEW:
		render_list_view(state, screen, ListViewConfig{
			view_key     = .CONSTANTS_VIEW,
			title        = "ENVIRONMENT CONSTANTS",
			count_format = "%d constants",
			row_kind     = .Table,
			col_label_0  = "NAME",
			col_label_1  = "VALUE",
			empty_line_1 = "No constants found",
			footer       = get_footer_data_view(state.terminal_width),
		})

	case .COMPLETIONS_VIEW:
		render_list_view(state, screen, ListViewConfig{
			view_key     = .COMPLETIONS_VIEW,
			title        = "COMPLETIONS",
			count_format = "%d completion scripts",
			row_kind     = .Single,
			empty_line_1 = "No completion scripts found",
			empty_line_2 = "Add completions with: wayu completions add <name> <file>",
			footer       = get_footer_readonly_view(state.terminal_width),
		})

	case .BACKUPS_VIEW:
		render_list_view(state, screen, ListViewConfig{
			view_key     = .BACKUPS_VIEW,
			title        = "BACKUPS",
			count_format = "%d backups available",
			row_kind     = .Single,
			empty_line_1 = "No backups found",
			footer       = get_footer_backup_view(state.terminal_width),
		})

	case .PLUGINS_VIEW:
		render_plugins_view(state, screen)

	case .HOOKS_VIEW:
		render_hooks_view(state, screen)

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
	text_x := header_x + MENU_ACCENT_BAR_WIDTH + MENU_ACCENT_GAP
	max_header_width := border_width - (text_x - header_x) - BORDER_RIGHT_WIDTH - 1

	screen_set_cell(screen, header_x, title_y, Cell{char = BOX_HEAVY_VERTICAL, fg = TUI_PRIMARY, bold = true})
	screen_set_cell(screen, header_x, title_y + 1, Cell{char = BOX_HEAVY_VERTICAL, fg = TUI_PRIMARY, bold = true})

	subtitle := "Shell Configuration Manager"
	if is_compact(state.terminal_width) {
		subtitle = "Shell Config Manager"
	}
	if is_narrow(state.terminal_width) {
		subtitle = "Config Manager"
	}
	subtitle_display := truncate_text(subtitle, max_header_width)

	render_text_styled(screen, text_x, title_y, "WAYU", TUI_PRIMARY, "", true)
	render_text_styled(screen, text_x, title_y + 1, subtitle_display, TUI_DIM)

	// Header divider line
	divider_y := LIST_ITEM_START_LINE
	divider_width := max(0, border_width - CONTENT_PADDING_LEFT - 2)  // Inset from both sides
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
		"Hooks",
		"Settings",
	}

	// First item starts after header divider + 1 blank line
	menu_start_y := divider_y + 2

	// How many items fit — must match get_view_visible_height(.MAIN_MENU)
	footer_y       := calculate_footer_y(state.terminal_height)
	available_rows := footer_y - 1 - menu_start_y + 1
	visible_count  := available_rows / MENU_ITEM_SPACING
	if visible_count < 1 { visible_count = 1 }

	// Max width for menu item text
	max_menu_width := max_header_width

	// scroll_offset is managed by tui_state_move_selection via get_view_visible_height
	start := state.scroll_offset
	end   := min(start + visible_count, len(menu_items))

	for i in start..<end {
		item := menu_items[i]
		display := truncate_text(item, max_menu_width)
		y := menu_start_y + ((i - start) * MENU_ITEM_SPACING)

		if i == state.selected_index {
			// Selected: accent bar ┃ + bold primary text
			screen_set_cell(screen, header_x, y, Cell{char = BOX_HEAVY_VERTICAL, fg = TUI_PRIMARY, bold = true})
			render_text_styled(screen, text_x, y, display, TUI_PRIMARY, "", true)
		} else {
			// Normal: no accent bar, muted text at same x
			render_text_styled(screen, text_x, y, display, TUI_MUTED)
		}

		// Divider line after each item (except the last visible one)
		if i < end - 1 {
			sep_y := y + 1
			for dx in 0..<divider_width {
				screen_set_cell(screen, header_x + dx, sep_y, Cell{char = BOX_HORIZONTAL, fg = TUI_DIVIDER})
			}
		}
	}

	// Footer — compact keyboard shortcuts (responsive)
	// Clear the bottom border row between left border and right corner
	// to erase leftover border dashes (─) from render_box_styled.
	footer_text := get_footer_main_menu(state.terminal_width)
	right_x := state.terminal_width - BORDER_RIGHT_WIDTH - 1
	for x in header_x..<right_x {
		screen_set_cell(screen, x, footer_y, Cell{char = ' '})
	}
	max_footer_width := right_x - header_x
	footer_display := truncate_text(footer_text, max_footer_width)
	render_text_styled(screen, header_x, footer_y, footer_display, TUI_DIM)
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
	form := &state.add_form
	// Indices: 0..field_count-1 = input fields, field_count = CANCEL btn, field_count+1 = ADD btn
	cancel_idx := form.field_count
	add_idx    := form.field_count + 1
	total_stops := form.field_count + 2  // fields + 2 buttons

	on_field  := form.field_index < form.field_count
	on_cancel := form.field_index == cancel_idx
	on_add    := form.field_index == add_idx

	#partial switch key.key {
	case .Escape:
		clear_add_form(state)

	case .Tab:
		// Cycle forward through all stops: field0 → field1 → CANCEL → ADD → field0 → ...
		form.field_index = (form.field_index + 1) % total_stops
		state.needs_refresh = true

	case .Backspace:
		// Only applies when a field is focused
		if on_field {
			if form.field_index == 0 {
				if len(form.input_0) > 0 {
					pop(&form.input_0)
					state.needs_refresh = true
				}
			} else {
				if len(form.input_1) > 0 {
					pop(&form.input_1)
					state.needs_refresh = true
				}
			}
		}

	case .Enter:
		if on_cancel {
			clear_add_form(state)
		} else {
			// ADD button or any field: submit
			execute_add_form(state)
		}

	case .Char:
		if .Ctrl not_in key.modifiers {
			if on_field {
				// Field is focused: all characters go into the buffer, including h and l
				if form.field_index == 0 {
					append(&form.input_0, u8(key.char))
				} else {
					append(&form.input_1, u8(key.char))
				}
				state.needs_refresh = true
			} else {
				// Button is focused: h/l cycle stops
				if key.char == 'h' {
					form.field_index = (form.field_index - 1 + total_stops) % total_stops
					state.needs_refresh = true
				} else if key.char == 'l' {
					form.field_index = (form.field_index + 1) % total_stops
					state.needs_refresh = true
				}
			}
			_ = on_add
			_ = on_cancel
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
	err_msg := ""
	switch view {
	case .PATH_VIEW:
		success, err_msg = entry_add(EntryPath{path = val_0})
	case .ALIAS_VIEW:
		success, err_msg = entry_add(EntryAlias{name = val_0, command = val_1})
	case .CONSTANTS_VIEW:
		success, err_msg = entry_add(EntryConst{name = val_0, value = val_1})
	case .MAIN_MENU, .COMPLETIONS_VIEW, .BACKUPS_VIEW, .PLUGINS_VIEW, .HOOKS_VIEW, .SETTINGS_VIEW:
		// unsupported
	}
	defer if len(err_msg) > 0 do delete(err_msg)

	if success {
		label: string
		switch view {
		case .PATH_VIEW:      label = "PATH entry"
		case .ALIAS_VIEW:     label = "alias"
		case .CONSTANTS_VIEW: label = "constant"
		case .MAIN_MENU, .COMPLETIONS_VIEW, .BACKUPS_VIEW, .PLUGINS_VIEW, .HOOKS_VIEW, .SETTINGS_VIEW:
			label = "entry"
		}
		msg := fmt.tprintf("Added %s: %s", label, val_0)
		clear_add_form(state)
		clear_view_cache(state, view)
		set_notification(state, .SUCCESS, msg)
	} else {
		if len(err_msg) > 0 {
			state.add_form.error_message = fmt.tprintf("Error: %s", err_msg)
		} else {
			state.add_form.error_message = fmt.tprintf("Error: failed to add %s", val_0)
		}
		state.needs_refresh = true
	}
}

// Note: View rendering functions are split across per-view files:
//   view_path.odin, view_alias.odin, view_constants.odin,
//   view_completions.odin, view_backups.odin, view_plugins.odin,
//   view_hooks.odin, view_settings.odin
TUIView :: enum {
	MAIN_MENU,
	PATH_VIEW,
	ALIAS_VIEW,
	CONSTANTS_VIEW,
	COMPLETIONS_VIEW,
	BACKUPS_VIEW,
	PLUGINS_VIEW,
	HOOKS_VIEW,
	SETTINGS_VIEW,
}

NotificationKind :: enum {
	NONE,
	SUCCESS,
	ERROR,
}

// Source filter cycles with `s` in data views. Matches on the glyph rune
// that tui_bridge_impl.odin prepends to each cache item:
//   ● = WAYU_ACTIVE, ⚠ = WAYU_INACTIVE, ○ = EXTERNAL.
// Separator lines (`─── External (N) ───`) and other glyph-less rows are
// filtered out whenever SourceFilter != ALL.
SourceFilter :: enum {
	ALL,
	WAYU_ACTIVE,
	WAYU_INACTIVE,
	EXTERNAL,
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
	data_cache:      ^map[TUIView]rawptr,
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
	// Plugin view tab state (0 = Installed, 1 = Registry)
	plugin_tab:            int,
	plugin_registry_cache: ^[dynamic]string,  // static registry rows, loaded once

	// Inline filter state
	filter_active:     bool,
	filter_text:       [dynamic]u8,
	filtered_indices:  [dynamic]int,  // indices into the original cache that match
	// Source filter — cycles ALL → WAYU_ACTIVE → WAYU_INACTIVE → EXTERNAL → ALL
	source_filter:     SourceFilter,
	// Notification state
	notification_kind:    NotificationKind,
	notification_message: string,
	notification_frames:  int,  // frames remaining before auto-dismiss

	// Settings cache (loaded once on demand)
	settings_shell:      string,
	settings_config_dir: string,
	settings_dry_run:    bool,
	settings_version:    string,  // wayu binary version
	settings_toml_path:  string,  // absolute path to wayu.toml
	settings_toml_exists: bool,   // true when that path is a regular file
	settings_backups:    int,     // total backup count across all config files
	settings_plugins:    int,     // enabled plugin count
	settings_loaded:     bool,    // guard — bridge should only load once per view entry
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
		data_cache = new(map[TUIView]rawptr),
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

	// Free plugin registry cache
	clear_registry_cache(state)

	// Free inline filter resources
	delete(state.filter_text)
	delete(state.filtered_indices)

	// Free settings cache strings (cloned by tui_bridge_load_settings)
	if len(state.settings_shell)      > 0 { delete(state.settings_shell) }
	if len(state.settings_config_dir) > 0 { delete(state.settings_config_dir) }
	if len(state.settings_version)    > 0 { delete(state.settings_version) }
	if len(state.settings_toml_path)  > 0 { delete(state.settings_toml_path) }

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
	delete(state.data_cache^)
	free(state.data_cache)
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
	// Invalidate settings cache on entry so backup/plugin counters reflect
	// state changes that happened while the user was in other views.
	if view == .SETTINGS_VIEW {
		state.settings_loaded = false
	}
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

	// Update scroll offset to keep selection visible.
	// Use get_view_visible_height so the scroll window matches the renderer exactly
	// (each view subtracts extra rows for dividers, filter bar, column headers, etc.).
	visible_height := get_view_visible_height(state)

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

// Returns true if `item` belongs to the currently selected source filter.
// SourceFilter.ALL passes everything. Non-ALL filters require the item to
// start with the matching glyph rune — separator lines and any glyph-less
// rows are excluded so the filtered view shows a clean single-source list.
matches_source :: proc(item: string, filter: SourceFilter) -> bool {
	if filter == .ALL { return true }
	if len(item) == 0 { return false }
	switch filter {
	case .WAYU_ACTIVE:   return strings.has_prefix(item, "●")
	case .WAYU_INACTIVE: return strings.has_prefix(item, "⚠")
	case .EXTERNAL:      return strings.has_prefix(item, "○")
	case .ALL:           return true
	}
	return true
}

// Parse a `source:<value>` token out of the raw filter text.
// Recognized values: `all`, `wayu`, `inactive`, `external` (case-sensitive,
// lower-case — TUI text input is already lowered where it matters).
// Returns the filter_text with the source token removed (so free-text
// matching ignores it), plus the parsed SourceFilter if one was found.
// Unknown values are ignored — the token is stripped but source stays ALL.
parse_source_token :: proc(text: string) -> (remainder: string, source: SourceFilter, has_source: bool) {
	idx := strings.index(text, "source:")
	if idx < 0 { return text, .ALL, false }

	// `source:` runs from idx to idx+7; the value runs until the next space.
	value_start := idx + 7
	value_end   := value_start
	for value_end < len(text) && text[value_end] != ' ' {
		value_end += 1
	}
	value := text[value_start:value_end]

	// Build the remainder by stitching before + after, collapsing the gap.
	before := strings.trim_space(text[:idx])
	after  := strings.trim_space(text[value_end:])
	rem: string
	switch {
	case len(before) == 0 && len(after) == 0: rem = ""
	case len(before) == 0: rem = after
	case len(after) == 0:  rem = before
	case: rem = strings.concatenate({before, " ", after}, context.temp_allocator)
	}

	parsed: SourceFilter = .ALL
	ok := true
	switch value {
	case "all":      parsed = .ALL
	case "wayu":     parsed = .WAYU_ACTIVE
	case "inactive": parsed = .WAYU_INACTIVE
	case "external": parsed = .EXTERNAL
	case: ok = false  // unknown value; strip token but keep source filter neutral
	}
	return rem, parsed, ok
}

// Rebuild filtered_indices based on current filter_text, source_filter, and cache.
// An item survives only if it matches BOTH the source filter and the text filter.
// Free-text filter may contain a `source:<value>` token — when present it
// overrides state.source_filter for this pass so users can combine `s` cycling
// with inline typing without fighting each other.
apply_filter :: proc(state: ^TUIState, items: []string) {
	clear(&state.filtered_indices)

	rem_text, parsed_src, has_src := parse_source_token(string(state.filter_text[:]))
	effective_src := state.source_filter
	if has_src { effective_src = parsed_src }
	rem_bytes := transmute([]u8)rem_text

	for item, i in items {
		if !matches_source(item, effective_src) { continue }
		if matches_filter(item, rem_bytes) {
			append(&state.filtered_indices, i)
		}
	}
	if state.selected_index >= len(state.filtered_indices) {
		state.selected_index = max(0, len(state.filtered_indices) - 1)
	}
	state.scroll_offset = 0
}

// Cycle the source filter and re-apply over the given cache.
// Also forces a refresh via filtered_indices even when filter_active is false,
// so the rendering layer switches to the indexed path.
cycle_source_filter :: proc(state: ^TUIState, items: []string) {
	switch state.source_filter {
	case .ALL:           state.source_filter = .WAYU_ACTIVE
	case .WAYU_ACTIVE:   state.source_filter = .WAYU_INACTIVE
	case .WAYU_INACTIVE: state.source_filter = .EXTERNAL
	case .EXTERNAL:      state.source_filter = .ALL
	}
	apply_filter(state, items)
}

// True when any filter (text or source) is active — used by views to decide
// whether to render through filtered_indices or over the raw cache.
has_any_filter :: proc(state: ^TUIState) -> bool {
	return state.filter_active || len(state.filter_text) > 0 || state.source_filter != .ALL
}

// Short label for the current source filter — used in footer/header hints.
source_filter_label :: proc(filter: SourceFilter) -> string {
	switch filter {
	case .ALL:           return "all"
	case .WAYU_ACTIVE:   return "wayu"
	case .WAYU_INACTIVE: return "inactive"
	case .EXTERNAL:      return "external"
	}
	return "all"
}

// Get the current view's cache items as a string slice.
// When on the Plugins Registry tab, returns the registry cache instead of
// the installed-plugins data_cache entry.
get_current_cache :: proc(state: ^TUIState) -> []string {
	if state.current_view == .PLUGINS_VIEW && state.plugin_tab == PLUGIN_TAB_REGISTRY {
		if state.plugin_registry_cache != nil {
			return state.plugin_registry_cache^[:]
		}
		return nil
	}
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

// Note: get_view_item_count() is implemented in views_cache.odin
// ============================================================================
// Plugin operations
// ============================================================================

tui_cleanup_backups :: proc() -> bool {
	config_files := []string{
		fmt.aprintf("%s/path.%s", g_ctx.wayu_config, g_ctx.shell_ext),
		fmt.aprintf("%s/aliases.%s", g_ctx.wayu_config, g_ctx.shell_ext),
		fmt.aprintf("%s/constants.%s", g_ctx.wayu_config, g_ctx.shell_ext),
	}
	defer for file in config_files do delete(file)

	for file in config_files {
		if os.exists(file) {
			cleanup_old_backups(file, 5)
		}
	}
	return true
}

tui_enable_plugin :: proc(name: string) -> bool {
	return _tui_set_plugin_enabled(name, true)
}

tui_disable_plugin :: proc(name: string) -> bool {
	return _tui_set_plugin_enabled(name, false)
}

@(private="file")
_tui_set_plugin_enabled :: proc(name: string, enabled: bool) -> bool {
	config, ok := read_plugin_config_json()
	if !ok { return false }
	defer cleanup_plugin_config_json(&config)

	for &plugin in config.plugins {
		if plugin.name == name {
			plugin.enabled = enabled
			if !write_plugin_config_json(&config) { return false }
			return generate_plugins_file(g_ctx.shell)
		}
	}
	return false
}

tui_install_plugin :: proc(key: string) -> bool {
	info, found := popular_plugin_find(key)
	if !found { return false }

	plugins_dir := get_plugins_dir()
	defer delete(plugins_dir)

	if !os.exists(plugins_dir) {
		if err := os.make_directory(plugins_dir); err != nil {
			return false
		}
	}

	dest := fmt.aprintf("%s/%s", plugins_dir, info.name)
	defer delete(dest)

	if !git_clone(info.url, dest) { return false }

	config, _ := read_plugin_config_json()
	defer cleanup_plugin_config_json(&config)

	_, already_found := find_plugin_json(&config, info.name)
	if !already_found {
		git_info := get_git_info(dest)
		new_plugin := PluginMetadata{
			name           = strings.clone(info.name),
			display_name   = strings.clone(info.name),
			url            = strings.clone(info.url),
			source_type    = .GitHub,
			enabled        = true,
			shell          = info.shell,
			installed_path = strings.clone(dest),
			entry_file     = "",
			use            = make([dynamic]string),
			template       = .Source,
			git            = git_info,
			dependencies   = make([dynamic]string),
			priority       = 100,
			profiles       = make([dynamic]string),
			conflicts      = ConflictInfo{},
		}
		append(&config.plugins, new_plugin)
	}

	if !write_plugin_config_json(&config) { return false }
	return generate_plugins_file(g_ctx.shell)
}

tui_get_path_detail :: proc(path_str: string) -> [dynamic]string {
	lines := make([dynamic]string)
	append(&lines, strings.clone(fmt.tprintf("Path: %s", path_str)))

	if os.exists(path_str) {
		append(&lines, strings.clone("Status: ✓ Directory exists"))
		dir_handle, err := os.open(path_str)
		if err == nil {
			defer os.close(dir_handle)
			infos, read_err := os.read_dir(dir_handle, -1, context.allocator)
			if read_err == nil {
				defer os.file_info_slice_delete(infos, context.allocator)
				append(&lines, strings.clone(fmt.tprintf("Contents: %d items", len(infos))))
			}
		}
	} else {
		append(&lines, strings.clone("Status: ✗ Directory not found"))
	}

	return lines
}

// ============================================================================
// Data loading — populates TUI state caches
// ============================================================================

@(private="file")
should_color_output :: proc() -> bool {
	no_color := os.get_env("NO_COLOR", context.temp_allocator)
	if len(no_color) > 0 { return false }
	return os.is_tty(os.stdout)
}

@(private="file")
get_source_glyph_rune :: proc(source: EntrySource, use_color: bool) -> string {
	if !use_color {
		#partial switch source {
		case .WAYU_ACTIVE:   return "[wayu]"
		case .WAYU_INACTIVE: return "[wayu(i)]"
		case .EXTERNAL:      return "[ext]"
		case .SHADOWED:      return "[diff]"
		}
		return "?"
	}
	#partial switch source {
	case .WAYU_ACTIVE:   return "●"
	case .WAYU_INACTIVE: return "⚠"
	case .EXTERNAL:      return "○"
	case .SHADOWED:      return "♦"
	}
	return "?"
}

tui_load_path :: proc(state: ^TUIState) {
	if state.data_cache[.PATH_VIEW] != nil {
		clear_view_cache(state, .PATH_VIEW)
	}

	items := make([dynamic]string)
	use_color := should_color_output()

	wayu_entries := make(map[string]EntrySource)
	defer delete(wayu_entries)

	toml_file := fmt.aprintf("%s/%s", g_ctx.wayu_config, WAYU_TOML)
	defer delete(toml_file)

	if os.exists(toml_file) {
		config, ok := toml_read_file(toml_file)
		defer {
			for entry in config.path.entries { delete(entry) }
			delete(config.path.entries)
		}
		if ok {
			env_paths := snapshot_path_entries()

			for entry in config.path.entries {
				is_in_env := false
				for env_path in env_paths {
					if env_path == entry {
						is_in_env = true
						break
					}
				}

				source := is_in_env ? EntrySource.WAYU_ACTIVE : EntrySource.WAYU_INACTIVE
				wayu_entries[entry] = source

				glyph := get_source_glyph_rune(source, use_color)
				item := fmt.aprintf("%s %s", glyph, entry)
				append(&items, item)
			}

			if len(env_paths) > len(wayu_entries) {
				external_count := 0
				for env_path in env_paths {
					if wayu_entries[env_path] == nil {
						external_count += 1
					}
				}

				if external_count > 0 {
					sep := fmt.tprintf("─── External (%d) ───", external_count)
					append(&items, sep)

					for env_path in env_paths {
						if wayu_entries[env_path] == nil {
							glyph := get_source_glyph_rune(EntrySource.EXTERNAL, use_color)
							item := fmt.aprintf("%s %s", glyph, env_path)
							append(&items, item)
						}
					}
				}
			}
		}
	} else {
		entries := read_config_entries(&PATH_SPEC)
		defer cleanup_entries(&entries)

		for entry in entries {
			item := strings.clone(entry.name)
			append(&items, item)
		}
	}

	items_ptr := new([dynamic]string)
	items_ptr^ = items
	state.data_cache[.PATH_VIEW] = items_ptr
}

tui_load_alias :: proc(state: ^TUIState) {
	if state.data_cache[.ALIAS_VIEW] != nil {
		clear_view_cache(state, .ALIAS_VIEW)
	}

	items := make([dynamic]string)
	use_color := should_color_output()

	wayu_aliases := make(map[string]bool)
	defer delete(wayu_aliases)

	toml_file := fmt.aprintf("%s/%s", g_ctx.wayu_config, WAYU_TOML)
	defer delete(toml_file)

	if os.exists(toml_file) {
		config, ok := toml_read_file(toml_file)
		defer {
			for alias in config.aliases {
				delete(alias.name)
				delete(alias.command)
				delete(alias.description)
			}
			delete(config.aliases)
		}
		if ok {
			env_aliases := snapshot_aliases()

			for alias in config.aliases {
				wayu_aliases[alias.name] = true

				env_val, exists := env_aliases[alias.name]
				is_active := exists && env_val == alias.command
				source := is_active ? EntrySource.WAYU_ACTIVE : EntrySource.WAYU_INACTIVE

				glyph := get_source_glyph_rune(source, use_color)
				item := fmt.aprintf("%s %s=%s", glyph, alias.name, alias.command)
				append(&items, item)
			}

			external_count := 0
			for env_name in env_aliases {
				if wayu_aliases[env_name] == false {
					external_count += 1
				}
			}

			if external_count > 0 {
				sep := fmt.tprintf("─── External (%d) ───", external_count)
				append(&items, sep)

				for env_name, env_cmd in env_aliases {
					if wayu_aliases[env_name] == false {
						glyph := get_source_glyph_rune(EntrySource.EXTERNAL, use_color)
						item := fmt.aprintf("%s %s=%s", glyph, env_name, env_cmd)
						append(&items, item)
					}
				}
			}
		}
	} else {
		entries := read_config_entries(&ALIAS_SPEC)
		defer cleanup_entries(&entries)

		for entry in entries {
			item := fmt.aprintf("%s=%s", entry.name, entry.value)
			append(&items, item)
		}
	}

	items_ptr := new([dynamic]string)
	items_ptr^ = items
	state.data_cache[.ALIAS_VIEW] = items_ptr
}

tui_load_constants :: proc(state: ^TUIState) {
	if state.data_cache[.CONSTANTS_VIEW] != nil {
		clear_view_cache(state, .CONSTANTS_VIEW)
	}

	items := make([dynamic]string)
	use_color := should_color_output()

	wayu_constants := make(map[string]bool)
	defer delete(wayu_constants)

	toml_file := fmt.aprintf("%s/%s", g_ctx.wayu_config, WAYU_TOML)
	defer delete(toml_file)

	if os.exists(toml_file) {
		config, ok := toml_read_file(toml_file)
		defer {
			for const in config.constants {
				delete(const.name)
				delete(const.value)
				delete(const.description)
			}
			delete(config.constants)
		}
		if ok {
			for const in config.constants {
				wayu_constants[const.name] = true

				env_val_maybe := snapshot_env_var(const.name)
				is_active := env_val_maybe != nil
				source := is_active ? EntrySource.WAYU_ACTIVE : EntrySource.WAYU_INACTIVE

				glyph := get_source_glyph_rune(source, use_color)
				item := fmt.aprintf("%s %s=%s", glyph, const.name, const.value)
				append(&items, item)
			}
		}

		content, file_ok := safe_read_file(toml_file)
		if file_ok {
			defer delete(content)
			lines := strings.split(string(content), "\n")
			defer delete(lines)

			in_env := false
			for line in lines {
				trimmed := strings.trim_space(line)
				if trimmed == "[env]" { in_env = true; continue }
				if strings.has_prefix(trimmed, "[") { in_env = false; continue }
				if !in_env { continue }
				if len(trimmed) == 0 || strings.has_prefix(trimmed, "#") { continue }

				eq_idx := strings.index_byte(trimmed, '=')
				if eq_idx < 1 { continue }

				name := strings.trim_space(trimmed[:eq_idx])
				value := strings.trim_space(trimmed[eq_idx+1:])
				value = strings.trim_prefix(value, `"`)
				value = strings.trim_suffix(value, `"`)
				value = strings.trim_prefix(value, "'")
				value = strings.trim_suffix(value, "'")
				if len(name) == 0 || len(value) == 0 { continue }
				if name in wayu_constants { continue }

				wayu_constants[name] = true
				unescaped := unescape_toml_string(value)
				defer delete(unescaped)
				env_val_maybe := snapshot_env_var(name)
				is_active := env_val_maybe != nil
				source := is_active ? EntrySource.WAYU_ACTIVE : EntrySource.WAYU_INACTIVE
				glyph := get_source_glyph_rune(source, use_color)
				item := fmt.aprintf("%s %s=%s", glyph, name, unescaped)
				append(&items, item)
			}
		}

		external_constants := make([dynamic]string)
		defer delete(external_constants)

		env_list, env_err := os.environ(context.allocator)
		if env_err == nil {
			defer delete(env_list)
			for pair in env_list {
				parts := strings.split(pair, "=", context.allocator)
				defer delete(parts)
				if len(parts) > 0 {
					const_name := parts[0]
					if !(const_name in wayu_constants) {
						append(&external_constants, const_name)
					}
				}
			}
		}

		if len(external_constants) > 0 {
			sep := fmt.tprintf("─── External (%d) ───", len(external_constants))
			append(&items, sep)

			for ext_const_name in external_constants {
				if env_val := snapshot_env_var(ext_const_name); env_val != nil {
					glyph := get_source_glyph_rune(EntrySource.EXTERNAL, use_color)
					item := fmt.aprintf("%s %s=%s", glyph, ext_const_name, env_val.(string))
					append(&items, item)
				}
			}
		}
	} else {
		entries := read_config_entries(&CONSTANTS_SPEC)
		defer cleanup_entries(&entries)

		for entry in entries {
			item := fmt.aprintf("%s=%s", entry.name, entry.value)
			append(&items, item)
		}
	}

	items_ptr := new([dynamic]string)
	items_ptr^ = items
	state.data_cache[.CONSTANTS_VIEW] = items_ptr
}

tui_load_completions :: proc(state: ^TUIState) {
	if state.data_cache[.COMPLETIONS_VIEW] != nil {
		clear_view_cache(state, .COMPLETIONS_VIEW)
	}

	completions_dir := fmt.aprintf("%s/completions", g_ctx.wayu_config)
	defer delete(completions_dir)

	items := make([dynamic]string)

	if !os.exists(completions_dir) {
		items_ptr := new([dynamic]string)
		items_ptr^ = items
		state.data_cache[.COMPLETIONS_VIEW] = items_ptr
		return
	}

	dir_handle, err := os.open(completions_dir)
	if err != nil {
		items_ptr := new([dynamic]string)
		items_ptr^ = items
		state.data_cache[.COMPLETIONS_VIEW] = items_ptr
		return
	}
	defer os.close(dir_handle)

	file_infos, read_err := os.read_dir(dir_handle, -1, context.allocator)
	if read_err != nil {
		items_ptr := new([dynamic]string)
		items_ptr^ = items
		state.data_cache[.COMPLETIONS_VIEW] = items_ptr
		return
	}
	defer os.file_info_slice_delete(file_infos, context.allocator)

	for info in file_infos {
		if strings.has_prefix(info.name, "_") && info.type != .Directory {
			if strings.contains(info.name, ".backup.") { continue }
			item := strings.clone(info.name)
			append(&items, item)
		}
	}

	items_ptr := new([dynamic]string)
	items_ptr^ = items
	state.data_cache[.COMPLETIONS_VIEW] = items_ptr
}

tui_load_backups :: proc(state: ^TUIState) {
	if state.data_cache[.BACKUPS_VIEW] != nil {
		clear_view_cache(state, .BACKUPS_VIEW)
	}

	items := make([dynamic]string)

	backups_dir := fmt.aprintf("%s/backup", g_ctx.wayu_config)
	defer delete(backups_dir)

	if !os.exists(backups_dir) {
		items_ptr := new([dynamic]string)
		items_ptr^ = items
		state.data_cache[.BACKUPS_VIEW] = items_ptr
		return
	}

	dir_handle, err := os.open(backups_dir)
	if err != nil {
		items_ptr := new([dynamic]string)
		items_ptr^ = items
		state.data_cache[.BACKUPS_VIEW] = items_ptr
		return
	}
	defer os.close(dir_handle)

	infos, read_err := os.read_dir(dir_handle, -1, context.allocator)
	if read_err != nil {
		items_ptr := new([dynamic]string)
		items_ptr^ = items
		state.data_cache[.BACKUPS_VIEW] = items_ptr
		return
	}
	defer os.file_info_slice_delete(infos, context.allocator)

	for info in infos {
		if info.type == .Directory { continue }

		name := info.name
		if !strings.contains(name, ".backup.") { continue }

		is_config := (strings.has_prefix(name, "path.") ||
		              strings.has_prefix(name, "aliases.") ||
		              strings.has_prefix(name, "constants."))

		if is_config {
			item := strings.clone(name)
			append(&items, item)
		}
	}

	items_ptr := new([dynamic]string)
	items_ptr^ = items
	state.data_cache[.BACKUPS_VIEW] = items_ptr
}

tui_load_plugins :: proc(state: ^TUIState) {
	if state.data_cache[.PLUGINS_VIEW] != nil {
		clear_view_cache(state, .PLUGINS_VIEW)
	}

	config, ok := read_plugin_config_json()
	if !ok {
		items_ptr := new([dynamic]string)
		items_ptr^ = make([dynamic]string)
		state.data_cache[.PLUGINS_VIEW] = items_ptr
		return
	}
	defer cleanup_plugin_config_json(&config)

	items := make([dynamic]string)
	for plugin in config.plugins {
		status := "○ Disabled"
		if plugin.enabled { status = "✓ Active" }
		item := strings.clone(fmt.tprintf("%s | %s | priority:%d", plugin.name, status, plugin.priority))
		append(&items, item)
	}

	items_ptr := new([dynamic]string)
	items_ptr^ = items
	state.data_cache[.PLUGINS_VIEW] = items_ptr
}

tui_load_settings :: proc(state: ^TUIState) {
	if state.settings_loaded { return }

	if len(state.settings_shell)      > 0 { delete(state.settings_shell) }
	if len(state.settings_config_dir) > 0 { delete(state.settings_config_dir) }
	if len(state.settings_version)    > 0 { delete(state.settings_version) }
	if len(state.settings_toml_path)  > 0 { delete(state.settings_toml_path) }

	state.settings_shell      = strings.clone(get_shell_name(g_ctx.shell))
	state.settings_config_dir = strings.clone(g_ctx.wayu_config)
	state.settings_dry_run    = g_ctx.dry_run
	state.settings_version    = strings.clone(VERSION)

	toml_full := fmt.aprintf("%s/%s", g_ctx.wayu_config, WAYU_TOML)
	state.settings_toml_path   = toml_full
	state.settings_toml_exists = os.exists(toml_full)

	total_backups := 0
	backup_targets := []string{g_ctx.path_file, g_ctx.alias_file, g_ctx.constants_file}
	for f in backup_targets {
		full := fmt.aprintf("%s/%s", g_ctx.wayu_config, f)
		defer delete(full)
		backups := list_backups_for_file(full)
		total_backups += len(backups)
		for b in backups {
			delete(b.original_file)
			delete(b.backup_file)
		}
		delete(backups)
	}
	state.settings_backups = total_backups

	enabled_plugins := 0
	config, cfg_ok := read_plugin_config_json()
	if cfg_ok {
		for plugin in config.plugins {
			if plugin.enabled { enabled_plugins += 1 }
		}
		cleanup_plugin_config_json(&config)
	}
	state.settings_plugins = enabled_plugins

	state.settings_loaded = true
}

tui_load_registry :: proc(state: ^TUIState) {
	if state.plugin_registry_cache != nil { return }

	installed_names := make(map[string]bool)
	defer delete(installed_names)
	config, _ := read_plugin_config_json()
	defer cleanup_plugin_config_json(&config)
	for plugin in config.plugins {
		installed_names[plugin.name] = true
	}

	items := make([dynamic]string)
	for entry in POPULAR_PLUGINS {
		if installed_names[entry.info.name] { continue }
		item := strings.clone(fmt.tprintf("%s\x00%s\x00%s\x00%s",
			entry.key,
			entry.category,
			shell_compat_to_string(entry.info.shell),
			entry.info.description))
		append(&items, item)
	}

	ptr := new([dynamic]string)
	ptr^ = items
	state.plugin_registry_cache = ptr
}

tui_ensure_data_loaded :: proc(state: ^TUIState, view: TUIView) {
	switch view {
	case .PATH_VIEW:
		if state.data_cache[view] == nil do tui_load_path(state)
	case .ALIAS_VIEW:
		if state.data_cache[view] == nil do tui_load_alias(state)
	case .CONSTANTS_VIEW:
		if state.data_cache[view] == nil do tui_load_constants(state)
	case .COMPLETIONS_VIEW:
		if state.data_cache[view] == nil do tui_load_completions(state)
	case .BACKUPS_VIEW:
		if state.data_cache[view] == nil do tui_load_backups(state)
	case .PLUGINS_VIEW:
		if state.data_cache[view] == nil do tui_load_plugins(state)
		tui_load_registry(state)
	case .MAIN_MENU, .HOOKS_VIEW, .SETTINGS_VIEW:
	}
}
// Flush screen with differential rendering
screen_flush :: proc(screen: ^Screen, force_full_render := false) {
	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	// Track what ANSI state the terminal is currently in so we can
	// emit only the minimal escape sequences needed.
	active_fg:   string
	active_bg:   string
	active_bold: bool
	active_dim:  bool

	for y in 0..<screen.height {
		for x in 0..<screen.width {
			curr := screen.buffer[y][x]
			prev := screen.prev_buffer[y][x]

			// Skip unchanged cells (KEY OPTIMIZATION)
			// But force render on first frame
			if !force_full_render && curr == prev do continue

			// Debug assertion: no ANSI escape bytes in cell buffer
			when ODIN_DEBUG {
				assert(curr.char != 0x1b, "ANSI escape in screen cell — see thoughts/scroll_bug_spec.md")
			}

			// Move cursor if needed (minimize cursor movement)
			if x != screen.cursor_x || y != screen.cursor_y {
				fmt.sbprintf(&builder, "\x1b[%d;%dH", y+1, x+1)
				screen.cursor_x = x
				screen.cursor_y = y
				// After a cursor jump we don't know what terminal state is,
				// so reset our tracking to force re-emission of attributes.
				active_fg   = ""
				active_bg   = ""
				active_bold = false
				active_dim  = false
			}

			// Reset all attributes if the cell has none but terminal has some
			needs_reset := false
			if (active_bold && !curr.bold) || (active_dim && !curr.dim) ||
			   (active_fg != "" && curr.fg == "") || (active_bg != "" && curr.bg == "") {
				needs_reset = true
			}

			if needs_reset {
				fmt.sbprintf(&builder, "\x1b[0m")
				active_fg   = ""
				active_bg   = ""
				active_bold = false
				active_dim  = false
			}

			// Apply bold if needed
			if curr.bold && !active_bold {
				fmt.sbprintf(&builder, "\x1b[1m")
				active_bold = true
			}

			// Apply dim if needed
			if curr.dim && !active_dim {
				fmt.sbprintf(&builder, "\x1b[2m")
				active_dim = true
			}

			// Apply foreground color if needed
			if curr.fg != "" && curr.fg != active_fg {
				fmt.sbprintf(&builder, "%s", curr.fg)
				active_fg = curr.fg
			}

			// Apply background color if needed
			if curr.bg != "" && curr.bg != active_bg {
				fmt.sbprintf(&builder, "%s", curr.bg)
				active_bg = curr.bg
			}

			// Write character
			fmt.sbprintf(&builder, "%c", curr.char)
			screen.cursor_x += 1
		}
	}

	// Reset attributes at end of frame
	if active_fg != "" || active_bg != "" || active_bold || active_dim {
		fmt.sbprintf(&builder, "\x1b[0m")
	}

	// Single write to terminal (batch for performance)
	output := strings.to_string(builder)
	if len(output) > 0 {
		// Write raw bytes directly to stdout for reliability
		os.write(os.stdout, transmute([]u8)output)
	}

	// Copy current to previous for next frame
	for y in 0..<screen.height {
		copy(screen.prev_buffer[y], screen.buffer[y])
	}
}

// Render text at position.
// ANSI escape bytes (0x1b) are silently skipped — color belongs in Cell.fg,
// not the char stream. See thoughts/scroll_bug_spec.md for why this matters.
render_text :: proc(screen: ^Screen, x, y: int, text: string) {
	current_x := x
	for ch in text {
		if current_x >= screen.width do break
		if ch == 0x1b do continue

		screen_set_cell(screen, current_x, y, Cell{char = ch})
		current_x += 1
	}
}

// Render box at position
tui_render_box :: proc(screen: ^Screen, x, y, width, height: int) {
	if width < 2 || height < 2 do return

	// Top border
	screen_set_cell(screen, x, y, Cell{char = '┌'})
	for i in 1..<width-1 {
		screen_set_cell(screen, x+i, y, Cell{char = '─'})
	}
	screen_set_cell(screen, x+width-1, y, Cell{char = '┐'})

	// Sides
	for j in 1..<height-1 {
		screen_set_cell(screen, x, y+j, Cell{char = '│'})
		screen_set_cell(screen, x+width-1, y+j, Cell{char = '│'})
	}

	// Bottom border
	screen_set_cell(screen, x, y+height-1, Cell{char = '└'})
	for i in 1..<width-1 {
		screen_set_cell(screen, x+i, y+height-1, Cell{char = '─'})
	}
	screen_set_cell(screen, x+width-1, y+height-1, Cell{char = '┘'})
}

// ============================================================================
// Styled Rendering Functions (Phase 1: Color System Foundation)
// ============================================================================

// Render text with color and formatting
// fg: Foreground color (ANSI escape code string)
// bg: Background color (ANSI escape code string)
// bold: Apply bold formatting
render_text_styled :: proc(screen: ^Screen, x, y: int, text: string, fg: string = "", bg: string = "", bold := false) {
	current_x := x
	for ch in text {
		if current_x >= screen.width do break
		// ESC bytes must never reach Cell.char — they inflate logical cursor_x
		// and drift the diff renderer. See thoughts/scroll_bug_spec.md.
		if ch == 0x1b do continue

		screen_set_cell(screen, current_x, y, Cell{
			char = ch,
			fg = fg,
			bg = bg,
			bold = bold,
		})
		current_x += 1
	}
}

// Render box with colored borders
// fg: Border color (defaults to TUI_BORDER_NORMAL)
render_box_styled :: proc(screen: ^Screen, x, y, width, height: int, fg: string = TUI_BORDER_NORMAL) {
	if width < 2 || height < 2 do return

	// Top border (rounded corners)
	screen_set_cell(screen, x, y, Cell{char = BOX_ROUND_TOP_LEFT, fg = fg})
	for i in 1..<width-1 {
		screen_set_cell(screen, x+i, y, Cell{char = BOX_HORIZONTAL, fg = fg})
	}
	screen_set_cell(screen, x+width-1, y, Cell{char = BOX_ROUND_TOP_RIGHT, fg = fg})

	// Sides
	for j in 1..<height-1 {
		screen_set_cell(screen, x, y+j, Cell{char = BOX_VERTICAL, fg = fg})
		screen_set_cell(screen, x+width-1, y+j, Cell{char = BOX_VERTICAL, fg = fg})
	}

	// Bottom border (rounded corners)
	screen_set_cell(screen, x, y+height-1, Cell{char = BOX_ROUND_BOTTOM_LEFT, fg = fg})
	for i in 1..<width-1 {
		screen_set_cell(screen, x+i, y+height-1, Cell{char = BOX_HORIZONTAL, fg = fg})
	}
	screen_set_cell(screen, x+width-1, y+height-1, Cell{char = BOX_ROUND_BOTTOM_RIGHT, fg = fg})
}

// ============================================================================
// Notification Rendering
// ============================================================================

// Render notification bar below the main content box
render_notification :: proc(state: ^TUIState, screen: ^Screen) {
	if state.notification_kind == .NONE {
		return
	}

	y := calculate_notification_y(state.terminal_height)
	if y < 0 || y >= screen.height {
		return
	}

	// Choose color and prefix based on notification kind
	color: string
	prefix: string
	if state.notification_kind == .SUCCESS {
		color = TUI_SUCCESS
		prefix = " ✓ "
	} else {
		color = TUI_ERROR
		prefix = " ✗ "
	}

	// Build display text
	text := fmt.tprintf("%s%s", prefix, state.notification_message)

	// Truncate to screen width (rune-aware to avoid splitting multi-byte chars)
	max_width := screen.width - BORDER_LEFT_WIDTH - CONTENT_PADDING_LEFT
	display := text
	rune_count := 0
	byte_end := 0
	for ch in display {
		if rune_count >= max_width do break
		rune_count += 1
		byte_end += utf8.rune_size(ch)
	}
	if rune_count >= max_width {
		display = display[:byte_end]
	}

	x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT
	render_text_styled(screen, x, y, display, color, "", true)
}
