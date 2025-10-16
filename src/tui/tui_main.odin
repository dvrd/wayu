package wayu_tui

import "core:fmt"
import "core:os"

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
		// Handle terminal resize
		if terminal_resized {
			new_width, new_height, _ := get_terminal_size()
			screen_resize(&screen, new_width, new_height)
			state.terminal_width = new_width
			state.terminal_height = new_height
			state.needs_refresh = true
			terminal_resized = false
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
	// Global keys (work in all views)
	if .Ctrl in key.modifiers && key.char == 'c' {
		state.running = false
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
		// TODO: Implement PATH-specific selection (Phase 6)

	case .ALIAS_VIEW:
		// TODO: Implement Alias-specific selection (Phase 6)

	case .CONSTANTS_VIEW:
		// TODO: Implement Constants-specific selection (Phase 6)

	case .COMPLETIONS_VIEW:
		// TODO: Implement Completions-specific selection (Phase 6)

	case .BACKUPS_VIEW:
		// TODO: Implement Backups-specific selection (Phase 6)

	case .PLUGINS_VIEW:
		// TODO: Implement Plugins-specific selection (Phase 6)

	case .SETTINGS_VIEW:
		// TODO: Implement Settings-specific selection (Phase 6)
	}
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
}

// Render main menu (using layout constants)
render_main_menu :: proc(state: ^TUIState, screen: ^Screen) {
	// Draw outer border using calculated dimensions
	border_width, border_height := calculate_border_dimensions(state.terminal_width, state.terminal_height)
	render_box_styled(screen, BORDER_LEFT_WIDTH, BORDER_TOP_HEIGHT, border_width, border_height, TUI_BORDER_FOCUSED)

	// Header (hot pink + bold)
	header_x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT
	render_text_styled(screen, header_x, HEADER_TITLE_LINE + CONTENT_PADDING_TOP, "wayu - Shell Configuration Manager", TUI_PRIMARY, "", true)
	render_text_styled(screen, header_x, HEADER_COUNT_LINE + CONTENT_PADDING_TOP, "Press Esc or q to quit, Ctrl+C to exit", TUI_DIM)

	// Menu items
	menu_items := []string{
		"1. PATH Configuration",
		"2. Aliases",
		"3. Environment Constants",
		"4. Completions",
		"5. Backups",
		"6. Plugins",
		"7. Settings",
	}

	for item, i in menu_items {
		y := calculate_list_item_y(i)
		if i == state.selected_index {
			// Selected: hot pink text + bold (NO background to respect terminal colors)
			text := fmt.tprintf("> %s", item)
			// Note: tprintf() uses temp buffer, do NOT delete
			render_text_styled(screen, header_x, y, text, TUI_PRIMARY, "", true)
		} else {
			// Normal: muted gray text (indented by selection prefix width)
			text := fmt.tprintf("  %s", item)
			// Note: tprintf() uses temp buffer, do NOT delete
			render_text_styled(screen, header_x + SELECTION_PREFIX_WIDTH, y, text, TUI_MUTED)
		}
	}

	// Footer (muted gray)
	footer_y := calculate_footer_y(state.terminal_height)
	render_text_styled(screen, header_x, footer_y, "Use ↑/↓ or j/k to navigate, Enter to select", TUI_MUTED)
}

// Note: View rendering functions are now in tui_views.odin
// render_path_view, render_alias_view, render_constants_view,
// render_completions_view, render_backups_view, render_plugins_view,
// render_settings_view are all implemented in tui_views.odin
