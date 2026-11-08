package wayu
import "core:fmt"
import "base:intrinsics"
import "core:os"
import "core:strings"
import "core:unicode/utf8"
import "core:time"
// Main TUI entry point
tui_run :: proc() {
	// Check if we're in a TTY first
	if !is_stdin_tty() || !is_stdout_tty() {
		fmt.eprintln("Error: TUI requires an interactive terminal (TTY)")
		fmt.eprintln("Cannot run TUI when stdin or stdout is not a terminal")
		os.exit(EXIT_GENERAL)
	}

	// Restore the terminal before printing any assert/panic message.
	context.assertion_failure_proc = tui_assertion_failure_proc

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
	state.full_redraw = true    // First frame paints every cell
	defer tui_state_destroy(&state)

	// NO_COLOR / --no-color: drop color escapes and use ASCII source tags.
	tui_color_mode = CURRENT_COLOR_PROFILE
	tui_plain_glyphs = CURRENT_COLOR_PROFILE == .ASCII
	defer {
		tui_color_mode = .TRUECOLOR
		tui_plain_glyphs = false
	}

	// CLI print helpers (print_success/print_error/...) would scribble over
	// the alternate screen when entry_add/entry_remove report progress.
	// Silence them while the TUI owns the terminal; the last error is
	// captured for notifications.
	print_quiet = true
	defer {
		print_quiet = false
		clear_print_capture()
	}

	// Main event loop (The Elm Architecture)
	for state.running {
		// Nothing allocated with the temp allocator may outlive an iteration
		// (persistent strings are heap-cloned), so reset the arena every pass.
		defer free_all(context.temp_allocator)

		// Handle terminal resize (volatile load/store for signal handler safety)
		if intrinsics.volatile_load(&terminal_resized) {
			intrinsics.volatile_store(&terminal_resized, false)
			if new_width, new_height, size_ok := get_terminal_size(); size_ok {
				screen_resize(&screen, new_width, new_height)
				state.terminal_width = new_width
				state.terminal_height = new_height
			}
			// Old cell contents no longer line up with the terminal's reflowed
			// screen: repaint everything and keep the selection visible.
			tui_clamp_selection(&state)
			state.full_redraw = true
			state.needs_refresh = true
		}

		// Ensure data is loaded for current view (lazy loading)
		tui_ensure_data_loaded(&state, state.current_view)

		// Render current state
		if state.needs_refresh || state.full_redraw {
			tui_render(&state, &screen)
			screen_flush(&screen, state.full_redraw)
			state.needs_refresh = false
			state.full_redraw = false
		}

		// Poll for events (non-blocking, ~50ms timeout)
		event := poll_event()

		// Expire notifications on wall-clock time, even when idle.
		tick_notification(&state)

		if event == nil {
			continue  // No input, loop again
		}

		// Update state based on event
		tui_handle_event(&state, event)
	}
}

// Initialize TUI subsystems.
// Raw mode is entered BEFORE the alternate screen so a failure exits with the
// terminal untouched (os.exit skips deferred cleanup).
tui_init :: proc() {
	if !tui_enable_raw_mode() {
		fmt.eprintln("Error: Failed to enable raw mode")
		os.exit(EXIT_OSERR)
	}
	tui_install_signal_handlers()
	tui_lifecycle_init()  // Enter alt screen, hide cursor, SIGWINCH handler
	tui_set_screen_active(true)
}

// Cleanup TUI subsystems
tui_cleanup :: proc() {
	tui_lifecycle_cleanup()    // Exit alt screen, show cursor
	tui_set_screen_active(false)
	tui_disable_raw_mode()     // Restore cooked mode
	tui_uninstall_signal_handlers()
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
	if state.detail.shown {
		if state.delete_confirm.pending {
			// Delete confirmation mode: h/l/Tab toggle focus, Enter confirms focused button,
			// y confirms directly (the button label advertises "y DELETE"), n/Esc cancel.
			is_char := key.key == .Char && .Ctrl not_in key.modifiers
			if key.key == .Escape || (is_char && (key.char == 'n' || key.char == 'N')) {
				clear_detail(state)
			} else if is_char && (key.char == 'y' || key.char == 'Y') {
				execute_pending_delete(state)
			} else if key.key == .Tab || (is_char && (key.char == 'h' || key.char == 'l')) {
				state.delete_confirm.focused = !state.delete_confirm.focused
				state.needs_refresh = true
			} else if key.key == .Enter {
				if state.delete_confirm.focused {
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
	if state.filter.active {
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
		// Control chords (other than the navigation aliases Ctrl+N/P/J/K)
		// must not trigger single-letter actions: Ctrl+D is not 'd'.
		if .Ctrl in key.modifiers {
			item_count := get_view_item_count(state)
			switch key.char {
			case 'n', 'j': tui_state_move_selection(state, 1, item_count)
			case 'p', 'k': tui_state_move_selection(state, -1, item_count)
			}
			return
		}
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
	// Detail lines are cloned by show_detail_overlay, so scratch strings can
	// live in the temp allocator (reset every frame by tui_run).
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
		_, row, ok := selected_row(state)
		if !ok || row.kind == .Separator do return
		detail_lines := tui_get_path_detail(row.key)
		defer {
			for line in detail_lines { delete(line) }
			delete(detail_lines)
		}
		show_detail_overlay(state, row.key, detail_lines[:])

	case .ALIAS_VIEW, .CONSTANTS_VIEW:
		_, row, ok := selected_row(state)
		if !ok || row.kind == .Separator do return
		value_label := "Command" if state.current_view == .ALIAS_VIEW else "Value"
		lines := []string{
			fmt.tprintf("Name: %s", row.key),
			fmt.tprintf("%s: %s", value_label, row.value),
		}
		show_detail_overlay(state, row.key, lines)

	case .COMPLETIONS_VIEW:
		display, _, ok := selected_row(state)
		if !ok do return
		lines := []string{fmt.tprintf("Script: %s", display)}
		show_detail_overlay(state, display, lines)

	case .BACKUPS_VIEW:
		display, _, ok := selected_row(state)
		if !ok do return
		// Parse backup filename: e.g. "path.zsh.backup.2024-03-15_14-30-00"
		sep := strings.index(display, ".backup.")
		if sep >= 0 {
			lines := []string{
				fmt.tprintf("Config: %s", display[:sep]),
				fmt.tprintf("Timestamp: %s", display[sep + len(".backup."):]),
			}
			show_detail_overlay(state, "Backup Detail", lines)
		} else {
			lines := []string{display}
			show_detail_overlay(state, "Backup", lines)
		}

	case .PLUGINS_VIEW:
		display, row, ok := selected_row(state)
		if !ok do return
		if state.plugin_tab == PLUGIN_TAB_INSTALLED {
			// Installed-plugin rows are "name | status | priority:N".
			parts := strings.split(display, " | ", context.temp_allocator)
			detail := make([dynamic]string, context.temp_allocator)
			append(&detail, fmt.tprintf("Plugin:   %s", row.key))
			if len(parts) >= 2 do append(&detail, fmt.tprintf("Status:   %s", strings.trim_space(parts[1])))
			if len(parts) >= 3 do append(&detail, fmt.tprintf("Priority: %s", strings.trim_prefix(strings.trim_space(parts[2]), "priority:")))
			show_detail_overlay(state, "Plugin Detail", detail[:])
		} else {
			// Registry row: key\x00category\x00shell\x00description
			parts := strings.split(display, "\x00", context.temp_allocator)
			line2 := "Press 'i' or Enter to install"
			if len(parts) >= 4 {
				line2 = fmt.tprintf("Description: %s", parts[3])
			}
			lines := []string{fmt.tprintf("Plugin: %s", parts[0]), line2}
			show_detail_overlay(state, "Plugin Registry", lines)
		}

	case .HOOKS_VIEW:
		// Hooks view renders all configured hooks inline; no detail overlay.

	case .SETTINGS_VIEW:
		// Settings view renders all values inline; no detail overlay.
	}
}

// Execute a confirmed delete operation (DELETE button + Enter, or 'y').
execute_pending_delete :: proc(state: ^TUIState) {
	if !state.delete_confirm.pending { return }

	view := state.delete_confirm.view
	// clear_detail frees delete_confirm.name — keep our own copy.
	name := strings.clone(state.delete_confirm.name)
	defer delete(name)

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

	// Dismiss the overlay (this also frees delete_confirm.name)
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
		set_notification(state, .SUCCESS, fmt.tprintf("Removed %s: %s", label, name))

		// Drop the cache; tui_ensure_data_loaded reloads it next frame and
		// re-applies the filter + clamps selection to the shorter list.
		clear_view_cache(state, view)
	} else {
		set_notification(state, .ERROR, failure_message(err_msg, fmt.tprintf("Failed to delete: %s", name)))
	}

	state.full_redraw = true
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
		state.filter.active = false
		// Don't clear filter_text or filtered_indices — keep the filtered view
		state.needs_refresh = true

	case .Backspace:
		// Remove last character (whole UTF-8 rune) from filter
		if rune_buffer_pop(&state.filter.text) {
			apply_filter(state, get_current_cache(state), get_current_meta(state))
			state.needs_refresh = true
		}

	// Item count is len(filter.indices) while filtering — zero matches means
	// navigation is a no-op rather than walking the unfiltered list.
	case .Up:
		tui_state_move_selection(state, -1, get_view_item_count(state))

	case .Down:
		tui_state_move_selection(state, 1, get_view_item_count(state))

	case .Char:
		if .Ctrl in key.modifiers {
			// Ctrl+K/Ctrl+P up, Ctrl+J/Ctrl+N down. Ctrl+J is LF: ICRNL is off in
			// TUI raw mode, so Enter arrives as CR and LF stays distinguishable.
			switch key.char {
			case 'k', 'p': tui_state_move_selection(state, -1, get_view_item_count(state))
			case 'j', 'n': tui_state_move_selection(state, 1, get_view_item_count(state))
			}
		} else {
			// Printable character: add to filter
			rune_buffer_push(&state.filter.text, key.char)
			apply_filter(state, get_current_cache(state), get_current_meta(state))
			state.needs_refresh = true
		}
	}
}

// Append `r` UTF-8 encoded to a byte buffer.
rune_buffer_push :: proc(buf: ^[dynamic]u8, r: rune) {
	bytes, n := utf8.encode_rune(r)
	append(buf, ..bytes[:n])
}

// Remove the last UTF-8 rune from a byte buffer. Returns false when empty.
rune_buffer_pop :: proc(buf: ^[dynamic]u8) -> bool {
	if len(buf) == 0 do return false
	_, size := utf8.decode_last_rune(buf[:])
	resize(buf, len(buf) - clamp(size, 1, len(buf)))
	return true
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
			buf := &form.input_0 if form.field_index == 0 else &form.input_1
			if rune_buffer_pop(buf) {
				state.needs_refresh = true
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
				buf := &form.input_0 if form.field_index == 0 else &form.input_1
				rune_buffer_push(buf, key.char)
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
		set_add_form_error(state, fmt.tprintf("Error: %s cannot be empty", state.add_form.label_0))
		state.needs_refresh = true
		return
	}
	// For two-field forms, second field must also be non-empty
	if state.add_form.field_count == 2 && len(val_1) == 0 {
		set_add_form_error(state, fmt.tprintf("Error: %s cannot be empty", state.add_form.label_1))
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
		state.full_redraw = true
	} else {
		set_add_form_error(state, fmt.tprintf("Error: %s", failure_message(err_msg, fmt.tprintf("failed to add %s", val_0))))
		state.full_redraw = true
		state.needs_refresh = true
	}
}

// Pick the most specific failure text: the returned error, else the last
// print_error captured while the TUI silenced CLI output, else `fallback`.
// Result lives in the temp allocator.
failure_message :: proc(err_msg: string, fallback: string) -> string {
	captured := take_print_capture()
	defer if len(captured) > 0 do delete(captured)
	if len(err_msg) > 0 do return err_msg
	if len(captured) > 0 do return strings.clone(captured, context.temp_allocator)
	return fallback
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

// Source filter cycles with `s` in data views. Matches on RowMeta.source
// (never on rendered glyph text, which changes under NO_COLOR).
// Separator rows and source-less rows are filtered out whenever
// SourceFilter != ALL.
SourceFilter :: enum {
	ALL,
	WAYU_ACTIVE,
	WAYU_INACTIVE,
	EXTERNAL,
}

// Where a cached row comes from. NONE = view has no source concept
// (completions, backups, plugins, non-TOML fallback).
RowSource :: enum u8 {
	NONE,
	WAYU_ACTIVE,
	WAYU_INACTIVE,
	EXTERNAL,
	SHADOWED,
}

RowKind :: enum u8 {
	Entry,
	Separator,
}

// Structured data kept alongside each display row of a data-view cache.
// Actions (delete, detail, enable/disable) read key/value from here instead of
// re-parsing the display text, so glyphs or formatting can never leak into the
// name passed to entry_remove.
RowMeta :: struct {
	key:    string,  // owned — path, alias/constant name, plugin name, file name
	value:  string,  // owned — alias command / constant value ("" otherwise)
	source: RowSource,
	kind:   RowKind,
}

row_source_from_entry :: proc(source: EntrySource) -> RowSource {
	switch source {
	case .WAYU_ACTIVE:   return .WAYU_ACTIVE
	case .WAYU_INACTIVE: return .WAYU_INACTIVE
	case .EXTERNAL:      return .EXTERNAL
	case .SHADOWED:      return .SHADOWED
	}
	return .NONE
}

// When true, source glyphs render as ASCII tags ("[wayu]") instead of Unicode
// symbols. Set by tui_run from the active color profile (NO_COLOR/--no-color).
tui_plain_glyphs: bool

// Glyph text for a row source ("" for NONE).
source_glyph :: proc(source: RowSource) -> string {
	if tui_plain_glyphs {
		switch source {
		case .NONE:          return ""
		case .WAYU_ACTIVE:   return "[wayu]"
		case .WAYU_INACTIVE: return "[wayu(i)]"
		case .EXTERNAL:      return "[ext]"
		case .SHADOWED:      return "[diff]"
		}
		return ""
	}
	switch source {
	case .NONE:          return ""
	case .WAYU_ACTIVE:   return "●"
	case .WAYU_INACTIVE: return "⚠"
	case .EXTERNAL:      return "○"
	case .SHADOWED:      return "♦"
	}
	return ""
}

// Foreground color for a row source glyph.
source_glyph_color :: proc(source: RowSource) -> string {
	switch source {
	case .NONE:          return TUI_MUTED
	case .WAYU_ACTIVE:   return TUI_SOURCE_WAYU_ACTIVE
	case .WAYU_INACTIVE: return TUI_SOURCE_WAYU_INACTIVE
	case .EXTERNAL:      return TUI_SOURCE_EXTERNAL
	case .SHADOWED:      return TUI_SOURCE_SHADOWED
	}
	return TUI_MUTED
}

// Append one display row + its metadata. `display` ownership transfers to the
// cache; key/value are cloned.
cache_push :: proc(
	items: ^[dynamic]string,
	meta: ^[dynamic]RowMeta,
	display: string,
	key: string,
	value: string = "",
	source: RowSource = .NONE,
	kind: RowKind = .Entry,
) {
	append(items, display)
	append(meta, RowMeta{
		key    = strings.clone(key),
		value  = strings.clone(value),
		source = source,
		kind   = kind,
	})
}

// Free every RowMeta in `meta` and the array itself.
row_meta_destroy :: proc(meta: ^[dynamic]RowMeta) {
	for m in meta {
		delete(m.key)
		delete(m.value)
	}
	delete(meta^)
	meta^ = nil
}

// Install a freshly-loaded cache for `view` (takes ownership of both arrays).
tui_store_cache :: proc(state: ^TUIState, view: TUIView, items: [dynamic]string, meta: [dynamic]RowMeta) {
	clear_view_cache(state, view)
	items_ptr := new([dynamic]string)
	items_ptr^ = items
	state.data_cache[view] = items_ptr
	state.row_meta[view] = meta
}

// Map the on-screen selection to an index into the current view's cache.
// With any filter active the selection counts over filter.indices; with zero
// matches (or an out-of-range selection) there is nothing to act on.
resolve_selection :: proc(state: ^TUIState, cache_len: int) -> (index: int, ok: bool) {
	idx := state.selected_index
	if has_any_filter(state) {
		if idx < 0 || idx >= len(state.filter.indices) do return -1, false
		idx = state.filter.indices[idx]
	}
	if idx < 0 || idx >= cache_len do return -1, false
	return idx, true
}

// Selected row (display + metadata) of the current data view.
// ok=false when the cache isn't loaded, the filter has no matches, or the
// selection is out of range.
selected_row :: proc(state: ^TUIState) -> (display: string, meta: RowMeta, ok: bool) {
	items := get_current_cache(state)
	idx, found := resolve_selection(state, len(items))
	if !found do return "", {}, false
	all_meta := get_current_meta(state)
	if idx < len(all_meta) {
		meta = all_meta[idx]
	} else {
		meta = RowMeta{key = items[idx]}
	}
	return items[idx], meta, true
}

// Keep selection and scroll inside the current item count / viewport.
tui_clamp_selection :: proc(state: ^TUIState) {
	count := get_view_item_count(state)
	if count <= 0 {
		state.selected_index = 0
		state.scroll_offset = 0
		return
	}
	state.selected_index = clamp(state.selected_index, 0, count - 1)
	vh := max(1, get_view_visible_height(state))
	if state.selected_index < state.scroll_offset {
		state.scroll_offset = state.selected_index
	}
	if state.selected_index >= state.scroll_offset + vh {
		state.scroll_offset = state.selected_index - vh + 1
	}
	state.scroll_offset = clamp(state.scroll_offset, 0, max(0, count - vh))
}

// Recompute filter.indices against the (possibly reloaded) cache and clamp
// selection. Must run after any cache reload so stale indices never index
// past the new cache.
tui_refresh_filter :: proc(state: ^TUIState) {
	if has_any_filter(state) {
		sel := state.selected_index
		apply_filter(state, get_current_cache(state), get_current_meta(state))
		state.selected_index = sel
	}
	tui_clamp_selection(state)
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
	error_message: string,    // owned (heap) — set via set_add_form_error
}

// Detail overlay state (the delete-confirm dialog reuses this surface).
DetailOverlay :: struct {
	title: string,
	lines: [dynamic]string,
	shown: bool,
}

// Delete-confirmation state — when pending, the detail overlay acts as a confirm dialog.
DeleteConfirm :: struct {
	name:    string,   // heap-cloned name to delete (freed on clear)
	view:    TUIView,
	pending: bool,
	focused: bool,     // true = DELETE button focused, false = CANCEL focused
}

// Inline filter state.
FilterState :: struct {
	text:    [dynamic]u8,
	indices: [dynamic]int,  // indices into the original cache that match
	active:  bool,
}

// Transient notification banner state.
Notification :: struct {
	message:    string,
	kind:       NotificationKind,
	expires_at: time.Tick,  // wall-clock deadline (ticks even without input)
}

// Settings view cache (loaded once on demand).
SettingsCache :: struct {
	shell:       string,
	config_dir:  string,
	version:     string,  // wayu binary version
	toml_path:   string,  // absolute path to wayu.toml
	backups:     int,     // total backup count across all config files
	plugins:     int,     // enabled plugin count
	dry_run:     bool,
	toml_exists: bool,    // true when that path is a regular file
	loaded:      bool,    // guard — bridge should only load once per view entry
}

TUIState :: struct {
	data_cache:    ^map[TUIView]rawptr,
	// Structured metadata parallel to each data_cache display array.
	row_meta:      [TUIView][dynamic]RowMeta,
	// Per-view cursor memory — remembers selection when navigating away
	saved_cursors: map[TUIView]ViewCursor,
	// Add form state — modal overlay for adding new entries
	add_form:      AddForm,
	// Static plugin registry rows, loaded once
	plugin_registry_cache: ^[dynamic]string,
	// Grouped subsystem state
	detail:         DetailOverlay,
	delete_confirm: DeleteConfirm,
	filter:         FilterState,
	notify:         Notification,
	settings:       SettingsCache,
	// View navigation
	current_view:   TUIView,
	previous_view:  TUIView,
	// Source filter — cycles ALL → WAYU_ACTIVE → WAYU_INACTIVE → EXTERNAL → ALL
	source_filter:  SourceFilter,
	selected_index:  int,
	scroll_offset:   int,
	terminal_width:  int,
	terminal_height: int,
	plugin_tab:      int,  // 0 = Installed, 1 = Registry
	needs_refresh:   bool,
	// Repaint every cell (and clear the terminal) on the next flush — set
	// after resizes and mutations, which may have scribbled over the screen.
	full_redraw:     bool,
	running:         bool,
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
	delete(state.detail.lines)

	// Free notification resources
	clear_notification(state)

	// Free plugin registry cache
	clear_registry_cache(state)

	// Free add form resources
	set_add_form_error(state, "")
	delete(state.add_form.input_0)
	delete(state.add_form.input_1)

	// Free inline filter resources
	delete(state.filter.text)
	delete(state.filter.indices)

	// Free settings cache strings (cloned by tui_bridge_load_settings)
	if len(state.settings.shell)      > 0 { delete(state.settings.shell) }
	if len(state.settings.config_dir) > 0 { delete(state.settings.config_dir) }
	if len(state.settings.version)    > 0 { delete(state.settings.version) }
	if len(state.settings.toml_path)  > 0 { delete(state.settings.toml_path) }

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

	for &meta in state.row_meta {
		row_meta_destroy(&meta)
	}
}

// Clear detail overlay and free its resources (also clears any pending delete)
clear_detail :: proc(state: ^TUIState) {
	state.detail.shown = false
	if len(state.detail.title) > 0 {
		delete(state.detail.title)
	}
	state.detail.title = ""
	for line in state.detail.lines {
		delete(line)
	}
	clear(&state.detail.lines)
	// Clear pending delete confirmation
	if state.delete_confirm.pending {
		if len(state.delete_confirm.name) > 0 {
			delete(state.delete_confirm.name)
		}
		state.delete_confirm.name = ""
		state.delete_confirm.pending = false
	}
	state.needs_refresh = true
}

// Show a delete confirmation overlay for the given item
show_delete_confirmation :: proc(state: ^TUIState, view: TUIView, display_name: string, delete_key: string) {
	clear_detail(state)
	state.detail.shown = true
	state.detail.title = strings.clone("DELETE CONFIRMATION")
	append(&state.detail.lines, strings.clone(display_name))
	append(&state.detail.lines, strings.clone(""))
	append(&state.detail.lines, strings.clone("This action cannot be undone."))
	append(&state.detail.lines, strings.clone("A backup will be created automatically."))
	state.delete_confirm.pending = true
	state.delete_confirm.view = view
	state.delete_confirm.name = strings.clone(delete_key)
	state.delete_confirm.focused = false  // start focused on CANCEL (safe default)
	state.needs_refresh = true
}

// Clear add form and free its input buffers
clear_add_form :: proc(state: ^TUIState) {
	state.add_form.active        = false
	set_add_form_error(state, "")
	clear(&state.add_form.input_0)
	clear(&state.add_form.input_1)
	state.needs_refresh = true
}

// Replace the add-form error with an owned copy of `msg` ("" clears it).
// Must be heap-owned: the temp allocator is reset every frame.
set_add_form_error :: proc(state: ^TUIState, msg: string) {
	if len(state.add_form.error_message) > 0 {
		delete(state.add_form.error_message)
	}
	state.add_form.error_message = strings.clone(msg) if len(msg) > 0 else ""
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
	state.detail.shown = true
	state.detail.title = strings.clone(title)
	for line in lines {
		append(&state.detail.lines, strings.clone(line))
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
		state.settings.loaded = false
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
	state.filter.active = true
	clear(&state.filter.text)
	clear(&state.filter.indices)
	state.selected_index = 0
	state.scroll_offset = 0
}

// Deactivate inline filter mode (text AND source filter — otherwise a source
// filter set in one view would make the next view render "No matches").
deactivate_filter :: proc(state: ^TUIState) {
	state.filter.active = false
	clear(&state.filter.text)
	clear(&state.filter.indices)
	state.source_filter = .ALL
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

// Returns true if a row with `source` belongs to the selected source filter.
// SourceFilter.ALL passes everything. Non-ALL filters require an exact source
// match — separators and source-less rows (NONE) are excluded so the filtered
// view shows a clean single-source list.
matches_source :: proc(source: RowSource, filter: SourceFilter) -> bool {
	switch filter {
	case .ALL:           return true
	case .WAYU_ACTIVE:   return source == .WAYU_ACTIVE
	case .WAYU_INACTIVE: return source == .WAYU_INACTIVE
	case .EXTERNAL:      return source == .EXTERNAL
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
// `meta` is parallel to `items` (may be nil/shorter: missing rows count as
// source NONE). Separator rows only survive the unfiltered ALL view.
apply_filter :: proc(state: ^TUIState, items: []string, meta: []RowMeta = nil) {
	clear(&state.filter.indices)

	rem_text, parsed_src, has_src := parse_source_token(string(state.filter.text[:]))
	effective_src := state.source_filter
	if has_src { effective_src = parsed_src }
	rem_bytes := transmute([]u8)rem_text

	for item, i in items {
		source := RowSource.NONE
		is_separator := false
		if i < len(meta) {
			source = meta[i].source
			is_separator = meta[i].kind == .Separator
		}
		if is_separator && (effective_src != .ALL || len(rem_bytes) > 0) { continue }
		if !matches_source(source, effective_src) { continue }
		if matches_filter(item, rem_bytes) {
			append(&state.filter.indices, i)
		}
	}
	if state.selected_index >= len(state.filter.indices) {
		state.selected_index = max(0, len(state.filter.indices) - 1)
	}
	state.scroll_offset = 0
}

// Cycle the source filter and re-apply over the given cache.
// Also forces a refresh via filtered_indices even when filter_active is false,
// so the rendering layer switches to the indexed path.
cycle_source_filter :: proc(state: ^TUIState, items: []string, meta: []RowMeta = nil) {
	switch state.source_filter {
	case .ALL:           state.source_filter = .WAYU_ACTIVE
	case .WAYU_ACTIVE:   state.source_filter = .WAYU_INACTIVE
	case .WAYU_INACTIVE: state.source_filter = .EXTERNAL
	case .EXTERNAL:      state.source_filter = .ALL
	}
	apply_filter(state, items, meta)
}

// True when any filter (text or source) is active — used by views to decide
// whether to render through filtered_indices or over the raw cache.
has_any_filter :: proc(state: ^TUIState) -> bool {
	return state.filter.active || len(state.filter.text) > 0 || state.source_filter != .ALL
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

// Metadata parallel to get_current_cache (nil for the registry tab, which
// stores its own \x00-delimited rows).
get_current_meta :: proc(state: ^TUIState) -> []RowMeta {
	if state.current_view == .PLUGINS_VIEW && state.plugin_tab == PLUGIN_TAB_REGISTRY {
		return nil
	}
	return state.row_meta[state.current_view][:]
}

// ============================================================================
// Notification helpers
// ============================================================================

NOTIFICATION_DURATION_SUCCESS :: 3 * time.Second
NOTIFICATION_DURATION_ERROR   :: 4 * time.Second

// Set a notification message with auto-dismiss countdown
set_notification :: proc(state: ^TUIState, kind: NotificationKind, message: string) {
	clear_notification(state)
	state.notify.kind = kind
	state.notify.message = strings.clone(message)
	duration := NOTIFICATION_DURATION_SUCCESS if kind == .SUCCESS else NOTIFICATION_DURATION_ERROR
	state.notify.expires_at = time.tick_add(time.tick_now(), duration)
	state.needs_refresh = true
}

// Clear the current notification and free its message
clear_notification :: proc(state: ^TUIState) {
	if len(state.notify.message) > 0 {
		delete(state.notify.message)
	}
	state.notify.message = ""
	state.notify.kind = .NONE
	state.notify.expires_at = {}
}

// Clear the notification once its deadline passes. Called every loop
// iteration (including poll timeouts), so expiry doesn't wait for a keypress.
tick_notification :: proc(state: ^TUIState, now := time.Tick{}) {
	if state.notify.kind == .NONE { return }
	current := now if now != {} else time.tick_now()
	if time.tick_diff(state.notify.expires_at, current) >= 0 {
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
		fmt.aprintf("%s/path.%s", wayu.data, wayu.shell_ext),
		fmt.aprintf("%s/aliases.%s", wayu.data, wayu.shell_ext),
		fmt.aprintf("%s/constants.%s", wayu.data, wayu.shell_ext),
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
	if !config_lock_acquire() { return false }
	defer config_lock_release()

	config, ok := read_plugin_config_json()
	defer cleanup_plugin_config_json(&config)
	if !ok { return false }

	for &plugin in config.plugins {
		if plugin.name == name {
			plugin.enabled = enabled
			if !tui_commit_plugin_config(&config) { return false }
			return generate_plugins_file(wayu.shell)
		}
	}
	return false
}

// Back up plugins.json, then write `config`. A TUI mutation must never
// replace the file without a restorable copy.
@(private="file")
tui_commit_plugin_config :: proc(config: ^PluginConfigJSON) -> bool {
	config_file := get_plugins_json_config_file()
	defer delete(config_file)
	if !create_backup_tui(config_file) { return false }
	return write_plugin_config_json(config)
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

	if !config_lock_acquire() { return false }
	defer config_lock_release()

	// Read (and validate) plugins.json BEFORE touching anything: if it can't
	// be parsed, writing our in-memory copy back would replace every other
	// plugin entry with just this one.
	config, cfg_ok := read_plugin_config_json()
	defer cleanup_plugin_config_json(&config)
	if !cfg_ok { return false }

	hook_pre_plugin_install(info.name)

	if !git_clone(info.url, dest) { return false }

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

	if !tui_commit_plugin_config(&config) { return false }
	if !generate_plugins_file(wayu.shell) { return false }

	hook_post_plugin_install(info.name)
	return true
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

// Every loader builds a display array plus a parallel RowMeta array and hands
// both to tui_store_cache. Display rows never carry glyphs — renderers derive
// the glyph from RowMeta.source — so filtering and actions see clean text.

// Owned separator display row: "─── External (N) ───".
@(private="file")
external_separator :: proc(count: int) -> string {
	return fmt.aprintf("─── External (%d) ───", count)
}

tui_load_path :: proc(state: ^TUIState) {
	items := make([dynamic]string)
	meta  := make([dynamic]RowMeta)

	toml_file := fmt.aprintf("%s/%s", wayu.config, WAYU_TOML)
	defer delete(toml_file)

	if os.exists(toml_file) {
		config, ok := toml_read_file(toml_file)
		defer {
			for entry in config.path.entries { delete(entry) }
			delete(config.path.entries)
		}
		if ok {
			// Cached by env_snapshot — not owned here.
			env_paths := snapshot_path_entries()

			wayu_entries := make(map[string]bool)
			defer delete(wayu_entries)

			for entry in config.path.entries {
				is_in_env := false
				for env_path in env_paths {
					if env_path == entry {
						is_in_env = true
						break
					}
				}
				wayu_entries[entry] = true
				source := RowSource.WAYU_ACTIVE if is_in_env else RowSource.WAYU_INACTIVE
				cache_push(&items, &meta, strings.clone(entry), entry, "", source)
			}

			external_count := 0
			for env_path in env_paths {
				if _, in_wayu := wayu_entries[env_path]; !in_wayu {
					external_count += 1
				}
			}
			if external_count > 0 {
				sep := external_separator(external_count)
				cache_push(&items, &meta, sep, sep, "", .NONE, .Separator)
				for env_path in env_paths {
					if _, in_wayu := wayu_entries[env_path]; !in_wayu {
						cache_push(&items, &meta, strings.clone(env_path), env_path, "", .EXTERNAL)
					}
				}
			}
		}
	} else {
		entries := read_config_entries(&PATH_SPEC)
		defer cleanup_entries(&entries)

		for entry in entries {
			cache_push(&items, &meta, strings.clone(entry.name), entry.name)
		}
	}

	tui_store_cache(state, .PATH_VIEW, items, meta)
}

tui_load_alias :: proc(state: ^TUIState) {
	items := make([dynamic]string)
	meta  := make([dynamic]RowMeta)

	toml_file := fmt.aprintf("%s/%s", wayu.config, WAYU_TOML)
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

			wayu_aliases := make(map[string]bool)
			defer delete(wayu_aliases)

			for alias in config.aliases {
				wayu_aliases[alias.name] = true

				env_val, exists := env_aliases[alias.name]
				is_active := exists && env_val == alias.command
				source := RowSource.WAYU_ACTIVE if is_active else RowSource.WAYU_INACTIVE

				display := fmt.aprintf("%s=%s", alias.name, alias.command)
				cache_push(&items, &meta, display, alias.name, alias.command, source)
			}

			external_count := 0
			for env_name in env_aliases {
				if _, in_wayu := wayu_aliases[env_name]; !in_wayu {
					external_count += 1
				}
			}

			if external_count > 0 {
				sep := external_separator(external_count)
				cache_push(&items, &meta, sep, sep, "", .NONE, .Separator)

				for env_name, env_cmd in env_aliases {
					if _, in_wayu := wayu_aliases[env_name]; !in_wayu {
						display := fmt.aprintf("%s=%s", env_name, env_cmd)
						cache_push(&items, &meta, display, env_name, env_cmd, .EXTERNAL)
					}
				}
			}
		}
	} else {
		entries := read_config_entries(&ALIAS_SPEC)
		defer cleanup_entries(&entries)

		for entry in entries {
			display := fmt.aprintf("%s=%s", entry.name, entry.value)
			cache_push(&items, &meta, display, entry.name, entry.value)
		}
	}

	tui_store_cache(state, .ALIAS_VIEW, items, meta)
}

tui_load_constants :: proc(state: ^TUIState) {
	items := make([dynamic]string)
	meta  := make([dynamic]RowMeta)

	toml_file := fmt.aprintf("%s/%s", wayu.config, WAYU_TOML)
	defer delete(toml_file)

	if os.exists(toml_file) {
		wayu_constants := make(map[string]bool)
		defer delete(wayu_constants)

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

				is_active := snapshot_env_var(const.name) != nil
				source := RowSource.WAYU_ACTIVE if is_active else RowSource.WAYU_INACTIVE

				display := fmt.aprintf("%s=%s", const.name, const.value)
				cache_push(&items, &meta, display, const.name, const.value, source)
			}
		}

		content, file_ok := safe_read_file(toml_file)
		// Freed at the end of this branch, not of the `if file_ok` block:
		// wayu_constants keys below point into `content` and are looked up
		// again by the external-env pass.
		defer if file_ok do delete(content)
		if file_ok {
			lines := strings.split(string(content), "\n")
			defer delete(lines)

			in_env := false
			for line in lines {
				trimmed := strings.trim_space(line)
				if toml_line_is_section(trimmed, "env") { in_env = true; continue }
				if strings.has_prefix(trimmed, "[") { in_env = false; continue }
				if !in_env { continue }

				// Shared parser: strips inline comment + one matching quote pair,
				// so values like `--format='%h'` keep their trailing quote.
				name, unescaped, kv_ok := toml_parse_kv_line(trimmed)
				if !kv_ok { continue }
				defer delete(unescaped)
				if name in wayu_constants { continue }

				// Key must outlive this loop iteration (map stores the slice).
				// `name` points into `content`, which lives until proc exit.
				wayu_constants[name] = true
				is_active := snapshot_env_var(name) != nil
				source := RowSource.WAYU_ACTIVE if is_active else RowSource.WAYU_INACTIVE
				display := fmt.aprintf("%s=%s", name, unescaped)
				cache_push(&items, &meta, display, name, unescaped, source)
			}
		}

		external_constants := make([dynamic]string)
		defer {
			for name in external_constants { delete(name) }
			delete(external_constants)
		}

		env_list, env_err := os.environ(context.allocator)
		if env_err == nil {
			defer {
				for pair in env_list { delete(pair) }
				delete(env_list)
			}
			for pair in env_list {
				eq := strings.index_byte(pair, '=')
				const_name := pair[:eq] if eq >= 0 else pair
				if len(const_name) == 0 { continue }
				if !(const_name in wayu_constants) {
					// Mark as seen: os.environ can list a name twice (Odin's
					// posix _environ repeats environ[0]); the clone outlives the map.
					name_copy := strings.clone(const_name)
					append(&external_constants, name_copy)
					wayu_constants[name_copy] = true
				}
			}
		}

		if len(external_constants) > 0 {
			sep := external_separator(len(external_constants))
			cache_push(&items, &meta, sep, sep, "", .NONE, .Separator)

			for ext_const_name in external_constants {
				if env_val, has := snapshot_env_var(ext_const_name).?; has {
					display := fmt.aprintf("%s=%s", ext_const_name, env_val)
					cache_push(&items, &meta, display, ext_const_name, env_val, .EXTERNAL)
				}
			}
		}
	} else {
		entries := read_config_entries(&CONSTANTS_SPEC)
		defer cleanup_entries(&entries)

		for entry in entries {
			display := fmt.aprintf("%s=%s", entry.name, entry.value)
			cache_push(&items, &meta, display, entry.name, entry.value)
		}
	}

	tui_store_cache(state, .CONSTANTS_VIEW, items, meta)
}

// List regular files in `dir` that satisfy `keep`, as a plain (source NONE) cache.
@(private="file")
load_dir_listing :: proc(state: ^TUIState, view: TUIView, dir: string, keep: proc(name: string) -> bool) {
	items := make([dynamic]string)
	meta  := make([dynamic]RowMeta)
	defer tui_store_cache(state, view, items, meta)

	if !os.exists(dir) do return

	dir_handle, err := os.open(dir)
	if err != nil do return
	defer os.close(dir_handle)

	infos, read_err := os.read_dir(dir_handle, -1, context.allocator)
	if read_err != nil do return
	defer os.file_info_slice_delete(infos, context.allocator)

	for info in infos {
		if info.type == .Directory { continue }
		if !keep(info.name) { continue }
		cache_push(&items, &meta, strings.clone(info.name), info.name)
	}
}

tui_load_completions :: proc(state: ^TUIState) {
	completions_dir := fmt.aprintf("%s/completions", wayu.data)
	defer delete(completions_dir)

	load_dir_listing(state, .COMPLETIONS_VIEW, completions_dir, proc(name: string) -> bool {
		return strings.has_prefix(name, "_") && !strings.contains(name, ".backup.")
	})
}

tui_load_backups :: proc(state: ^TUIState) {
	backups_dir := fmt.aprintf("%s/backup", wayu.data)
	defer delete(backups_dir)

	load_dir_listing(state, .BACKUPS_VIEW, backups_dir, proc(name: string) -> bool {
		if !strings.contains(name, ".backup.") { return false }
		return strings.has_prefix(name, "path.") ||
		       strings.has_prefix(name, "aliases.") ||
		       strings.has_prefix(name, "constants.")
	})
}

tui_load_plugins :: proc(state: ^TUIState) {
	items := make([dynamic]string)
	meta  := make([dynamic]RowMeta)
	defer tui_store_cache(state, .PLUGINS_VIEW, items, meta)

	config, ok := read_plugin_config_json()
	if !ok do return
	defer cleanup_plugin_config_json(&config)

	for plugin in config.plugins {
		status := "✓ Active" if plugin.enabled else "○ Disabled"
		display := fmt.aprintf("%s | %s | priority:%d", plugin.name, status, plugin.priority)
		cache_push(&items, &meta, display, plugin.name, status)
	}
}

tui_load_settings :: proc(state: ^TUIState) {
	if state.settings.loaded { return }

	if len(state.settings.shell)      > 0 { delete(state.settings.shell) }
	if len(state.settings.config_dir) > 0 { delete(state.settings.config_dir) }
	if len(state.settings.version)    > 0 { delete(state.settings.version) }
	if len(state.settings.toml_path)  > 0 { delete(state.settings.toml_path) }

	state.settings.shell      = strings.clone(get_shell_name(wayu.shell))
	state.settings.config_dir = strings.clone(wayu.config)
	state.settings.dry_run    = wayu.dry_run
	state.settings.version    = strings.clone(VERSION)

	toml_full := fmt.aprintf("%s/%s", wayu.config, WAYU_TOML)
	state.settings.toml_path   = toml_full
	state.settings.toml_exists = os.exists(toml_full)

	total_backups := 0
	backup_targets := []string{wayu.path_file, wayu.alias_file, wayu.constants_file}
	for f in backup_targets {
		full := fmt.aprintf("%s/%s", wayu.data, f)
		defer delete(full)
		backups := list_backups_for_file(full)
		total_backups += len(backups)
		for b in backups {
			delete(b.original_file)
			delete(b.backup_file)
		}
		delete(backups)
	}
	state.settings.backups = total_backups

	enabled_plugins := 0
	config, cfg_ok := read_plugin_config_json()
	if cfg_ok {
		for plugin in config.plugins {
			if plugin.enabled { enabled_plugins += 1 }
		}
		cleanup_plugin_config_json(&config)
	}
	state.settings.plugins = enabled_plugins

	state.settings.loaded = true
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
	loaded := false
	if state.data_cache[view] == nil {
		loaded = true
		switch view {
		case .PATH_VIEW:        tui_load_path(state)
		case .ALIAS_VIEW:       tui_load_alias(state)
		case .CONSTANTS_VIEW:   tui_load_constants(state)
		case .COMPLETIONS_VIEW: tui_load_completions(state)
		case .BACKUPS_VIEW:     tui_load_backups(state)
		case .PLUGINS_VIEW:     tui_load_plugins(state)
		case .MAIN_MENU, .HOOKS_VIEW, .SETTINGS_VIEW:
			loaded = false
		}
	}
	if view == .PLUGINS_VIEW && state.plugin_registry_cache == nil {
		tui_load_registry(state)
		loaded = true
	}
	// A (re)load invalidates filter.indices and may shrink the list: rebuild
	// the filter and clamp selection/scroll before anything indexes the cache.
	if loaded && view == state.current_view {
		tui_refresh_filter(state)
		state.needs_refresh = true
	}
}
// Flush screen with differential rendering.
// force_full_render clears the terminal and repaints every cell — used for the
// first frame, after resizes, and after mutations that may have written to
// the terminal behind our back.
screen_flush :: proc(screen: ^Screen, force_full_render := false) {
	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	if force_full_render {
		strings.write_string(&builder, "\x1b[0m\x1b[2J")
		// Terminal cursor position is unknown: force a move before the first cell.
		screen.cursor_x = -1
		screen.cursor_y = -1
	}

	use_color := tui_color_mode != .ASCII

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

			// Right half of a wide glyph: the lead cell already covered it.
			if curr.char == CELL_CONTINUATION do continue

			// Debug assertion: no ANSI escape bytes in cell buffer
			when ODIN_DEBUG {
				assert(curr.char != 0x1b, "ANSI escape in screen cell — see thoughts/scroll_bug_spec.md")
			}

			fg := curr.fg if use_color else ""
			bg := curr.bg if use_color else ""

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
			   (active_fg != "" && fg == "") || (active_bg != "" && bg == "") {
				needs_reset = true
			}

			if needs_reset {
				strings.write_string(&builder, "\x1b[0m")
				active_fg   = ""
				active_bg   = ""
				active_bold = false
				active_dim  = false
			}

			// Apply bold if needed
			if curr.bold && !active_bold {
				strings.write_string(&builder, "\x1b[1m")
				active_bold = true
			}

			// Apply dim if needed
			if curr.dim && !active_dim {
				strings.write_string(&builder, "\x1b[2m")
				active_dim = true
			}

			// Apply foreground color if needed (adapted to the color profile)
			if fg != "" && fg != active_fg {
				write_tui_color(&builder, fg)
				active_fg = fg
			}

			// Apply background color if needed
			if bg != "" && bg != active_bg {
				write_tui_color(&builder, bg)
				active_bg = bg
			}

			// Write character; wide glyphs advance the terminal cursor by two.
			ch := curr.char
			if ch < 0x20 do ch = ' '
			strings.write_rune(&builder, ch)
			screen.cursor_x += max(1, get_rune_width(ch))
		}
	}

	// Reset attributes at end of frame
	if active_fg != "" || active_bg != "" || active_bold || active_dim {
		strings.write_string(&builder, "\x1b[0m")
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
// Wide runes (CJK, emoji) occupy two cells; zero-width runes are dropped.
render_text :: proc(screen: ^Screen, x, y: int, text: string) {
	render_text_styled(screen, x, y, text)
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
	style := Cell{fg = fg, bg = bg, bold = bold}
	for ch in text {
		if current_x >= screen.width do break
		// ESC bytes must never reach Cell.char — they inflate logical cursor_x
		// and drift the diff renderer. See thoughts/scroll_bug_spec.md.
		if ch == 0x1b do continue
		if get_rune_width(ch) == 0 do continue

		w := screen_put_rune(screen, current_x, y, ch, style)
		if w == 0 do break  // wide rune doesn't fit before the right edge
		current_x += w
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
	if state.notify.kind == .NONE {
		return
	}

	y := calculate_notification_y(state.terminal_height)
	if y < 0 || y >= screen.height {
		return
	}

	// Choose color and prefix based on notification kind
	color: string
	prefix: string
	if state.notify.kind == .SUCCESS {
		color = TUI_SUCCESS
		prefix = " ✓ "
	} else {
		color = TUI_ERROR
		prefix = " ✗ "
	}

	// Build display text, truncated to the visible width (wide-char aware)
	text := fmt.tprintf("%s%s", prefix, state.notify.message)
	max_width := screen.width - BORDER_LEFT_WIDTH - CONTENT_PADDING_LEFT
	display := truncate_text(text, max_width)

	x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT
	render_text_styled(screen, x, y, display, color, "", true)
}
