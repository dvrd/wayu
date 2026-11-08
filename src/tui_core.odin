package wayu
import "core:fmt"
import "base:intrinsics"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/posix"
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
	state.screen = &screen      // busy frames (long operations) paint mid-handler
	defer tui_state_destroy(&state)
	// Record the config files' stamps so only later edits count as external.
	tui_watch_sync(&state)

	// NO_COLOR / --no-color: drop color escapes and use ASCII source tags.
	tui_color_mode = CURRENT_COLOR_PROFILE
	tui_plain_glyphs = CURRENT_COLOR_PROFILE == .ASCII
	tui_theme = tui_detect_theme()  // light/dark background (after the size probe)
	defer {
		tui_color_mode = .TRUECOLOR
		tui_plain_glyphs = false
		tui_theme = .Dark
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

		// stdin hit EOF / EIO (terminal gone without SIGHUP): nothing can
		// ever arrive again, so quit instead of spinning on poll.
		if tui_input_closed {
			state.running = false
			break
		}

		// Expire notifications on wall-clock time, even when idle.
		tick_notification(&state)

		// Reload views whose files were changed by something else
		// (`wayu alias add` in another shell, an editor, hot reload).
		tui_check_external_changes(&state)

		if event == nil {
			continue  // No input, loop again
		}

		// Update state based on event
		confirm_was_open := state.delete_confirm.pending
		form_was_open := state.add_form.active
		tui_handle_event(&state, event)
		destroy_event(event)
		// Keys typed ahead of a delete confirmation or past a submitted form
		// (an unbracketed paste "name\rdy") must not answer the dialog.
		if (!confirm_was_open && state.delete_confirm.pending) || (form_was_open && !state.add_form.active) {
			tui_discard_typeahead()
		}
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
	tui_load_esc_delay()
	tui_stderr_capture_begin()  // replayed if the TUI dies (OKAMI-262)
	tui_lifecycle_init()  // Enter alt screen, hide cursor, SIGWINCH handler
	tui_set_screen_active(true)
}

// Cleanup TUI subsystems
tui_cleanup :: proc() {
	tui_stderr_capture_end(replay = false)
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
	case PasteEvent:
		handle_paste(state, e.text)
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
	// Ctrl+Z: suspend like any terminal program; `fg` resumes and repaints.
	if key.key == .Char && key.modifiers == {.Ctrl} && key.char == 'z' {
		tui_suspend_self()
		return
	}
	// Alt chords (ESC+key) have no bindings: Alt+d must not act as `d`.
	if .Alt in key.modifiers {
		#partial switch key.key {
		case .Char, .Enter, .Tab, .Backspace, .Escape: return
		}
	}

	// Below the minimum size only a "too small" notice is drawn: allow
	// quitting and going back, nothing that acts on invisible rows.
	if tui_too_small(state) {
		if key.key == .Escape || (key.key == .Char && key.char == 'q') {
			if state.current_view == .MAIN_MENU {
				state.running = false
			} else {
				tui_state_go_back(state)
			}
		}
		return
	}

	// Confirmation / detail overlay first: it may sit on top of the add form
	// (replace-existing confirmation).
	if state.detail.shown {
		if state.delete_confirm.pending {
			// Confirmation mode: h/l/Tab toggle focus, Enter activates the
			// focused button, y confirms directly (the button advertises
			// "y DELETE" / "y REPLACE" / ...), n/Esc cancel.
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
			// Normal detail overlay: Esc/Enter/q dismiss; 'i' installs from
			// a registry detail (same as on the row).
			if key.key == .Escape || key.key == .Enter || (key.key == .Char && key.char == 'q') {
				clear_detail(state)
			} else if key.key == .Char && key.char == 'i' && state.current_view == .PLUGINS_VIEW && state.plugin_tab == PLUGIN_TAB_REGISTRY {
				clear_detail(state)
				handle_plugins_event(state, key)
			}
		}
		return
	}

	// When add form is active, route ALL input to add form handler
	if state.add_form.active {
		handle_add_form_input(state, key)
		return
	}

	// When filter is active, route ALL input to filter handler
	if state.filter.active {
		handle_filter_input(state, key)
		return
	}

	// Reload: r, Ctrl+R or F5 drop every cache (and the shell snapshot) so
	// the current view re-reads wayu.toml / plugins.json / the backup dir.
	if key.key == .F5 || (key.key == .Char && (key.char == 'r' || key.char == 'R') && (.Ctrl in key.modifiers || key.char == 'r')) {
		tui_reload_all(state)
		set_notification(state, .INFO, "Reloaded")
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
		handle_selection(state)

	case .Escape:
		if state.current_view != .MAIN_MENU {
			tui_state_go_back(state)
		}
	}
}

// Bracketed paste: insert the text into the focused text field (the add
// form's input or the filter) as typed characters, with CR/LF dropped and
// tabs as spaces. Anywhere else a paste does nothing — pasted letters and
// newlines are never commands (OKAMI-253).
handle_paste :: proc(state: ^TUIState, text: string) {
	in_field := state.add_form.active && state.add_form.field_index < state.add_form.field_count
	in_filter := !state.add_form.active && !state.detail.shown && state.filter.active
	if !in_field && !in_filter do return
	for r in text {
		ch := r
		switch {
		case ch == '\t':                                 ch = ' '
		case ch < 0x20 || ch == 0x7F || ch == utf8.RUNE_ERROR: continue
		case ch >= 0x80 && ch < 0xA0:                    continue
		}
		key := KeyEvent{key = .Char, char = ch}
		if in_field {
			handle_add_form_input(state, key)
		} else {
			handle_filter_input(state, key)
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
		value := row.value
		if state.current_view == .CONSTANTS_VIEW {
			value = list_display_value(row.key, row.value, state.reveal_secrets)
		}
		lines := []string{
			fmt.tprintf("Name: %s", row.key),
			fmt.tprintf("%s: %s", value_label, value),
		}
		show_detail_overlay(state, row.key, lines)

	case .COMPLETIONS_VIEW:
		display, _, ok := selected_row(state)
		if !ok do return
		lines := []string{fmt.tprintf("Script: %s", display)}
		show_detail_overlay(state, display, lines)

	case .BACKUPS_VIEW:
		// Enter on a backup: restore it (with confirmation) when it is a
		// wayu.toml backup — the only file `wayu backup restore` handles —
		// otherwise show where it is so it can be copied back by hand.
		display, row, ok := selected_row(state)
		if !ok do return
		group := row.value if len(row.value) > 0 else display
		if group == WAYU_TOML {
			show_restore_confirmation(state, row.key)
		} else {
			lines := []string{
				fmt.tprintf("File:   %s", backup_key_display(group, context.temp_allocator)),
				fmt.tprintf("Backup: %s", display),
				"",
				"Only wayu.toml backups are restored by wayu;",
				fmt.tprintf("copy this one back by hand: %s", row.key),
			}
			show_detail_overlay(state, "Backup Detail", lines)
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
			detail := make([dynamic]string, context.temp_allocator)
			append(&detail, fmt.tprintf("Plugin:      %s", parts[0]))
			if len(parts) >= 4 {
				append(&detail, fmt.tprintf("Category:    %s", parts[1]))
				append(&detail, fmt.tprintf("Shell:       %s", parts[2]))
				append(&detail, fmt.tprintf("Description: %s", parts[3]))
			}
			if info, found := popular_plugin_find(parts[0]); found {
				append(&detail, fmt.tprintf("Repository:  %s", info.url))
			}
			append(&detail, "")
			append(&detail, "Press i to install")
			show_detail_overlay(state, "Plugin Registry", detail[:])
		}

	case .HOOKS_VIEW:
		show_hook_detail(state)

	case .SETTINGS_VIEW:
		toggle_selected_setting(state)
	}
}

// Run the action a confirmation dialog asked about (DELETE button + Enter,
// or 'y'): delete an entry, replace an existing one, restore a backup,
// prune backups or install a plugin.
execute_pending_delete :: proc(state: ^TUIState) {
	if !state.delete_confirm.pending { return }

	kind := state.delete_confirm.kind
	view := state.delete_confirm.view
	// clear_detail frees delete_confirm.name/value — keep our own copies.
	name := strings.clone(state.delete_confirm.name)
	defer delete(name)

	// Dismiss the overlay (this also frees delete_confirm.name)
	clear_detail(state)

	switch kind {
	case .DELETE:  tui_delete_entry(state, view, name)
	case .REPLACE: execute_add_form(state, confirmed = true)
	case .RESTORE: tui_restore_backup(state, name)
	case .CLEANUP: tui_cleanup_backups(state)
	case .INSTALL: tui_install_registry_plugin(state, name)
	}

	state.full_redraw = true
	state.needs_refresh = true
}

// Remove `name` from the view's table through entry_remove (the CLI's code
// path: same hooks, backups, --dry-run) and report the outcome.
tui_delete_entry :: proc(state: ^TUIState, view: TUIView, name: string) {
	entry: Entry
	#partial switch view {
	case .PATH_VIEW:      entry = EntryPath{path = name}
	case .ALIAS_VIEW:     entry = EntryAlias{name = name}
	case .CONSTANTS_VIEW: entry = EntryConst{name = name}
	case: return
	}
	tui_busy_begin(state, fmt.tprintf("Removing %s…", name))
	outcome, err_msg := entry_remove(entry)
	tui_busy_end(state)
	defer if len(err_msg) > 0 do delete(err_msg)

	label := entry_label(view)
	#partial switch outcome {
	case .DRY_RUN:
		set_notification(state, .INFO, fmt.tprintf("[dry-run] would remove %s: %s", label, name))
	case .REMOVED:
		set_notification(state, .SUCCESS, fmt.tprintf("Removed %s: %s", label, name))
		// Drop the cache; tui_ensure_data_loaded reloads it next frame and
		// re-applies the filter + clamps selection to the shorter list.
		tui_after_write(state, view)
	case:
		set_notification(state, .ERROR, failure_message(err_msg, fmt.tprintf("Failed to delete: %s", name)))
	}
}

// Human word for a data view's entries ("PATH entry", "alias", "constant").
entry_label :: proc(view: TUIView) -> string {
	#partial switch view {
	case .PATH_VIEW:      return "PATH entry"
	case .ALIAS_VIEW:     return "alias"
	case .CONSTANTS_VIEW: return "constant"
	}
	return "entry"
}

// Render current state to screen
tui_render :: proc(state: ^TUIState, screen: ^Screen) {
	// Clear screen
	screen_clear(screen)

	if tui_too_small(state) {
		render_too_small(state, screen)
		return
	}

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
			footer       = get_footer_constants_view(state.terminal_width, state.reveal_secrets),
			mask_secrets = !state.reveal_secrets,
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

	// Persistent reminder that nothing is written in this session.
	render_dry_run_badge(state, screen)

	// Render notification bar (below content box)
	render_notification(state, screen)

	// Add form overlay, then the detail / confirmation overlay above it (a
	// replace-existing confirmation is asked on top of the form).
	render_add_form_overlay(state, screen)
	render_detail_overlay(state, screen)

	// Progress of a long operation (shell, git, hooks) on top of everything.
	render_busy_overlay(state, screen)
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
			screen_mark_focus(screen, text_x, y)
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

// Handle keyboard input when add form modal is active.
// Fields are single-line editors: printable keys insert at the cursor;
// Left/Right/Home/End (Ctrl+A/E) move; Backspace/Delete, Ctrl+U (to start),
// Ctrl+K (to end) and Ctrl+W (word before the cursor) delete.
handle_add_form_input :: proc(state: ^TUIState, key: KeyEvent) {
	form := &state.add_form
	// Indices: 0..field_count-1 = input fields, field_count = CANCEL btn, field_count+1 = ADD btn
	cancel_idx := form.field_count
	total_stops := form.field_count + 2  // fields + 2 buttons

	on_field  := form.field_index < form.field_count
	on_cancel := form.field_index == cancel_idx

	buf    := &form.input_0 if form.field_index == 0 else &form.input_1
	cursor := &form.cursor_0 if form.field_index == 0 else &form.cursor_1
	if on_field do cursor^ = clamp(cursor^, 0, len(buf))

	#partial switch key.key {
	case .Escape:
		clear_add_form(state)

	case .Tab:
		// Cycle forward through all stops: field0 → field1 → CANCEL → ADD → field0 → ...
		form.field_index = (form.field_index + 1) % total_stops
		state.needs_refresh = true

	case .Up, .Down:
		// Move between stops like Shift+Tab / Tab.
		delta := -1 if key.key == .Up else 1
		form.field_index = (form.field_index + delta + total_stops) % total_stops
		state.needs_refresh = true

	case .Backspace:
		if on_field && line_edit_backspace(buf, cursor) do state.needs_refresh = true

	case .Delete:
		if on_field && line_edit_delete(buf, cursor) do state.needs_refresh = true

	case .Left, .Right, .Home, .End:
		if !on_field do return
		#partial switch key.key {
		case .Left:  line_edit_left(buf, cursor)
		case .Right: line_edit_right(buf, cursor)
		case .Home:  cursor^ = 0
		case .End:   cursor^ = len(buf)
		}
		state.needs_refresh = true

	case .Enter:
		if on_cancel {
			clear_add_form(state)
		} else {
			// ADD button or any field: submit
			execute_add_form(state)
		}

	case .Char:
		if .Ctrl in key.modifiers {
			if !on_field do return
			switch key.char {
			case 'a': cursor^ = 0
			case 'e': cursor^ = len(buf)
			case 'b': line_edit_left(buf, cursor)
			case 'f': line_edit_right(buf, cursor)
			case 'u':
				remove_range(buf, 0, cursor^)
				cursor^ = 0
			case 'k':
				resize(buf, cursor^)
			case 'w':
				line_edit_delete_word(buf, cursor)
			case 'h':
				line_edit_backspace(buf, cursor)
			case:
				return
			}
			state.needs_refresh = true
			return
		}
		if on_field {
			// Field is focused: all characters go into the buffer, including h and l
			line_edit_insert(buf, cursor, key.char)
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
	}
}

// ---- single-line editor helpers (cursor = byte offset on a rune boundary) --

line_edit_insert :: proc(buf: ^[dynamic]u8, cursor: ^int, r: rune) {
	bytes, n := utf8.encode_rune(r)
	at := clamp(cursor^, 0, len(buf))
	inject_at(buf, at, ..bytes[:n])
	cursor^ = at + n
}

line_edit_backspace :: proc(buf: ^[dynamic]u8, cursor: ^int) -> bool {
	at := clamp(cursor^, 0, len(buf))
	if at == 0 do return false
	_, size := utf8.decode_last_rune(buf[:at])
	size = clamp(size, 1, at)
	remove_range(buf, at - size, at)
	cursor^ = at - size
	return true
}

line_edit_delete :: proc(buf: ^[dynamic]u8, cursor: ^int) -> bool {
	at := clamp(cursor^, 0, len(buf))
	if at >= len(buf) do return false
	_, size := utf8.decode_rune(buf[at:])
	remove_range(buf, at, at + clamp(size, 1, len(buf) - at))
	return true
}

line_edit_left :: proc(buf: ^[dynamic]u8, cursor: ^int) {
	at := clamp(cursor^, 0, len(buf))
	if at == 0 do return
	_, size := utf8.decode_last_rune(buf[:at])
	cursor^ = at - clamp(size, 1, at)
}

line_edit_right :: proc(buf: ^[dynamic]u8, cursor: ^int) {
	at := clamp(cursor^, 0, len(buf))
	if at >= len(buf) do return
	_, size := utf8.decode_rune(buf[at:])
	cursor^ = at + clamp(size, 1, len(buf) - at)
}

// Ctrl+W: delete the whitespace before the cursor, then the word before it.
line_edit_delete_word :: proc(buf: ^[dynamic]u8, cursor: ^int) {
	at := clamp(cursor^, 0, len(buf))
	start := at
	for start > 0 && (buf[start - 1] == ' ' || buf[start - 1] == '\t') do start -= 1
	for start > 0 && buf[start - 1] != ' ' && buf[start - 1] != '\t' do start -= 1
	remove_range(buf, start, at)
	cursor^ = start
}

// Submit the add / edit form through the CLI's code paths (entry_add /
// entry_remove: same validation, hooks, backups and --dry-run).
//   PATH:  `name=path` names the [paths] key like `wayu path add`; the path
//          must resolve and exist (else the form shows the CLI's reason).
//   alias / constant: adding a name that already exists asks to replace it
//          (`confirmed` = the user said yes); an edit that renames the
//          entry removes the old name after the new one is written.
execute_add_form :: proc(state: ^TUIState, confirmed := false) {
	form := &state.add_form
	if !form.active do return
	val_0 := string(form.input_0[:])
	val_1 := string(form.input_1[:])

	// Validate: first field must be non-empty
	if len(strings.trim_space(val_0)) == 0 {
		set_add_form_error(state, fmt.tprintf("Error: %s cannot be empty", form.label_0))
		state.needs_refresh = true
		return
	}
	// For two-field forms, second field must also be non-empty
	if form.field_count == 2 && len(val_1) == 0 {
		set_add_form_error(state, fmt.tprintf("Error: %s cannot be empty", form.label_1))
		state.needs_refresh = true
		return
	}

	view := form.view
	editing := len(form.edit_key) > 0
	label := entry_label(view)

	if view == .PATH_VIEW {
		name_hint, raw_path, _ := parse_path_arg(val_0)
		outcome: EntryOutcome
		err_msg: string
		tui_busy_begin(state, fmt.tprintf("Saving %s…", raw_path))
		if editing {
			outcome, err_msg = entry_replace_path(form.edit_key, raw_path)
		} else {
			outcome, err_msg = entry_add(EntryPath{path = raw_path, name = name_hint})
		}
		tui_busy_end(state)
		defer if len(err_msg) > 0 do delete(err_msg)
		finish_add_form(state, view, outcome, err_msg, raw_path, "", editing)
		return
	}
	if view != .ALIAS_VIEW && view != .CONSTANTS_VIEW do return

	renamed := editing && val_0 != form.edit_key
	replacing := editing && !renamed
	if !editing || renamed {
		if current, found := tui_current_value(view, val_0); found {
			if current == val_1 {
				finish_add_form(state, view, .UNCHANGED, "", val_0, val_1, editing)
				return
			}
			if !confirmed {
				show_replace_confirmation(state, view, val_0, current, val_1)
				return
			}
			replacing = true
		}
	}

	entry: Entry = EntryAlias{name = val_0, command = val_1}
	if view == .CONSTANTS_VIEW do entry = EntryConst{name = val_0, value = val_1}

	tui_busy_begin(state, fmt.tprintf("Saving %s…", val_0))
	outcome, err_msg := entry_add(entry)
	defer if len(err_msg) > 0 do delete(err_msg)

	// Rename: the new name is in, now drop the old one.
	rename_err := ""
	if renamed && (outcome == .ADDED || outcome == .UPDATED || outcome == .DRY_RUN) {
		old: Entry = EntryAlias{name = form.edit_key}
		if view == .CONSTANTS_VIEW do old = EntryConst{name = form.edit_key}
		rm_outcome, rm_err := entry_remove(old)
		if rm_outcome == .FAILED {
			rename_err = fmt.tprintf("%s %s written, but the old %s could not be removed: %s",
				label, val_0, form.edit_key, failure_message(rm_err, "unknown error"))
		}
		if len(rm_err) > 0 do delete(rm_err)
	}
	tui_busy_end(state)

	if outcome == .ADDED && replacing do outcome = .UPDATED
	finish_add_form(state, view, outcome, err_msg, val_0, val_1, editing, replacing)
	if len(rename_err) > 0 do set_notification(state, .ERROR, rename_err)
}

// Report an add/edit outcome: failures keep the form open with the reason;
// anything else closes it and shows what happened (a dry run as a preview).
@(private = "file")
finish_add_form :: proc(state: ^TUIState, view: TUIView, outcome: EntryOutcome, err_msg, name, value: string, editing: bool, replacing := false) {
	label := entry_label(view)
	if outcome == .FAILED {
		set_add_form_error(state, fmt.tprintf("Error: %s", failure_message(err_msg, fmt.tprintf("failed to add %s", name))))
		state.full_redraw = true
		state.needs_refresh = true
		return
	}

	shown := mask_secret_value(name, value) if view == .CONSTANTS_VIEW else value
	kind := NotificationKind.SUCCESS
	msg: string
	#partial switch outcome {
	case .DRY_RUN:
		kind = .INFO
		verb := "update" if editing || replacing else "add"
		if view == .PATH_VIEW {
			msg = fmt.tprintf("[dry-run] would %s %s: %s", verb, label, name)
		} else {
			msg = fmt.tprintf("[dry-run] would %s %s: %s = %q", verb, label, name, shown)
		}
	case .ADDED:
		msg = fmt.tprintf("Added %s: %s", label, name)
	case .UPDATED:
		msg = fmt.tprintf("Updated %s: %s", label, name)
	case .UNCHANGED:
		kind = .INFO
		msg = fmt.tprintf("Already present, nothing changed: %s", name)
	case:
		msg = fmt.tprintf("%s: %s", label, name)
	}
	clear_add_form(state)
	if outcome == .ADDED || outcome == .UPDATED {
		tui_after_write(state, view)
	}
	set_notification(state, kind, msg)
	state.full_redraw = true
}

// Current wayu.toml value of alias / constant `name` (read fresh from disk,
// not from the possibly stale view cache). Result is temp-allocated.
tui_current_value :: proc(view: TUIView, name: string) -> (value: string, found: bool) {
	toml_file := fmt.tprintf("%s/%s", wayu.config, WAYU_TOML)
	config, ok := toml_read_file_lenient(toml_file)
	defer cleanup_toml_config(&config)
	if !ok do return "", false
	if view == .ALIAS_VIEW {
		for a in config.aliases do if a.name == name do return strings.clone(a.command, context.temp_allocator), true
	} else {
		for c in config.constants do if c.name == name do return strings.clone(c.value, context.temp_allocator), true
	}
	return "", false
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
	INFO,  // neutral: dry-run previews, "nothing changed", reloads
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
	cursor_0:      int,       // byte offset of the cursor in input_0 (rune boundary)
	cursor_1:      int,
	edit_key:      string,    // owned; non-empty = editing this existing entry ('e')
	error_message: string,    // owned (heap) — set via set_add_form_error
}

// Detail overlay state (the delete-confirm dialog reuses this surface).
DetailOverlay :: struct {
	title: string,
	lines: [dynamic]string,
	shown: bool,
}

// What a confirmation dialog will do when the user says yes.
ConfirmKind :: enum u8 {
	DELETE,   // remove entry `name` from `view`
	REPLACE,  // overwrite an existing alias/constant with the add form's values
	RESTORE,  // restore wayu.toml from backup file `name`
	CLEANUP,  // prune every backup group to BACKUP_KEEP_COUNT
	INSTALL,  // install registry plugin `name`
}

// Confirmation state — when pending, the detail overlay acts as a confirm
// dialog (delete, replace, restore, cleanup, install).
DeleteConfirm :: struct {
	name:    string,   // heap-cloned subject (entry name, backup path, plugin key); freed on clear
	view:    TUIView,
	kind:    ConfirmKind,
	pending: bool,
	focused: bool,     // true = action button focused, false = CANCEL focused
}

// A long operation in progress (shell snapshot, git clone, hooks): drawn as
// a spinner overlay; Esc / Ctrl+C cancel the running child process.
BusyState :: struct {
	message:    string,     // owned; "" = idle
	frame:      int,
	last_paint: time.Tick,
	cancelled:  bool,
}

// Size + mtime of a watched file; exists=false when missing.
FileStamp :: struct {
	mtime:  i64,
	size:   i64,
	exists: bool,
}

// Files whose external changes reload the views that show them.
WatchState :: struct {
	toml:       FileStamp,  // wayu.toml → PATH, aliases, constants, settings
	plugins:    FileStamp,  // plugins.json → plugins
	backup_dir: FileStamp,  // backup/ → backups, settings
	hooks:      FileStamp,  // hooks.conf → hooks
	last_check: time.Tick,
}

// Hooks view cache: the hooks.conf rows, loaded on view entry / reload.
HooksCache :: struct {
	rows:   [dynamic]HookRow,
	loaded: bool,
}

// One hooks.conf entry for the hooks view.
HookRow :: struct {
	key:     string,  // static hook name (pre_path_add, ...)
	command: string,  // owned; "" = not configured
	invalid: string,  // static placeholder token when the hook is refused
	hook:    HookType,
	disabled: bool,   // commented out by the TUI (HOOK_DISABLED_PREFIX)
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
	color:       string,  // static: active color profile name
	editor:      string,  // owned: $VISUAL / $EDITOR used by `wayu ... edit`
	keep:        int,     // backups kept per file
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
	hooks:          HooksCache,
	busy:           BusyState,
	watch:          WatchState,
	// Screen being drawn (set by tui_run; nil in unit tests). Long
	// operations paint a progress frame mid-handler through it.
	screen:         ^Screen,
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
	// Constants view shows secret-looking values unmasked (`v` toggles;
	// reset whenever the view changes, so reveal never outlives the view).
	reveal_secrets:  bool,
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
	settings_free_strings(&state.settings)
	hooks_cache_clear(&state.hooks)
	delete(state.hooks.rows)
	if len(state.busy.message) > 0 do delete(state.busy.message)
	if len(state.add_form.edit_key) > 0 do delete(state.add_form.edit_key)

	// Free saved cursors map
	delete(state.saved_cursors)

	// Free cached data properly - must free strings, dynamic arrays, then pointers
	for _, value in state.data_cache {
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
	// Clear pending confirmation
	if state.delete_confirm.pending {
		if len(state.delete_confirm.name) > 0 {
			delete(state.delete_confirm.name)
		}
		state.delete_confirm.name = ""
		state.delete_confirm.pending = false
		state.delete_confirm.kind = .DELETE
	}
	state.needs_refresh = true
}

// Open a confirmation dialog: `lines` explain it, `subject` (cloned) is what
// the action applies to. Focus starts on CANCEL (safe default).
show_confirmation :: proc(state: ^TUIState, kind: ConfirmKind, view: TUIView, title: string, lines: []string, subject: string) {
	clear_detail(state)
	state.detail.shown = true
	state.detail.title = strings.clone(title)
	for line in lines do append(&state.detail.lines, strings.clone(line))
	state.delete_confirm.pending = true
	state.delete_confirm.kind = kind
	state.delete_confirm.view = view
	state.delete_confirm.name = strings.clone(subject)
	state.delete_confirm.focused = false
	state.needs_refresh = true
}

// Show a delete confirmation overlay for the given item
show_delete_confirmation :: proc(state: ^TUIState, view: TUIView, display_name: string, delete_key: string) {
	undo := "A backup is created first (u restores it)." if !wayu.dry_run else "Dry run: nothing will be written."
	show_confirmation(state, .DELETE, view, "DELETE CONFIRMATION",
		{display_name, "", "Removes it from wayu.toml.", undo}, delete_key)
}

// Ask before an add overwrites an existing alias / constant.
show_replace_confirmation :: proc(state: ^TUIState, view: TUIView, name, current, value: string) {
	cur, val := current, value
	if view == .CONSTANTS_VIEW && !state.reveal_secrets {
		cur = mask_secret_value(name, current)
		val = mask_secret_value(name, value)
	}
	title := "REPLACE ALIAS" if view == .ALIAS_VIEW else "REPLACE CONSTANT"
	show_confirmation(state, .REPLACE, view, title, {
		fmt.tprintf("%s %s already exists.", "Alias" if view == .ALIAS_VIEW else "Constant", name),
		"",
		fmt.tprintf("Current: %s", cur),
		fmt.tprintf("New:     %s", val),
	}, name)
}

// Ask before restoring wayu.toml from `backup_path`.
show_restore_confirmation :: proc(state: ^TUIState, backup_path: string) {
	show_confirmation(state, .RESTORE, .BACKUPS_VIEW, "RESTORE wayu.toml", {
		fmt.tprintf("From: %s", get_base_name(backup_path)),
		"",
		"Reverts paths, aliases AND constants.",
		"The current wayu.toml is backed up first.",
	}, backup_path)
}

// Label of the action button of the pending confirmation.
confirm_action_label :: proc(kind: ConfirmKind, compact: bool) -> string {
	switch kind {
	case .DELETE:  return "y DEL" if compact else "y DELETE"
	case .REPLACE: return "y REPL" if compact else "y REPLACE"
	case .RESTORE: return "y REST" if compact else "y RESTORE"
	case .CLEANUP: return "y CLEAN" if compact else "y CLEAN UP"
	case .INSTALL: return "y INST" if compact else "y INSTALL"
	}
	return "y OK"
}

// Clear add form and free its input buffers
clear_add_form :: proc(state: ^TUIState) {
	state.add_form.active        = false
	set_add_form_error(state, "")
	clear(&state.add_form.input_0)
	clear(&state.add_form.input_1)
	state.add_form.cursor_0 = 0
	state.add_form.cursor_1 = 0
	if len(state.add_form.edit_key) > 0 do delete(state.add_form.edit_key)
	state.add_form.edit_key = ""
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

// Open the form prefilled with an existing entry ('e'). Submitting updates
// it in place (a PATH keeps its key and position; a renamed alias/constant
// replaces the old name).
show_edit_form :: proc(state: ^TUIState, view: TUIView, key, value: string) {
	show_add_form(state, view)
	if !state.add_form.active do return
	state.add_form.edit_key = strings.clone(key)
	append(&state.add_form.input_0, ..transmute([]u8)key)
	state.add_form.cursor_0 = len(state.add_form.input_0)
	if state.add_form.field_count == 2 {
		append(&state.add_form.input_1, ..transmute([]u8)value)
		state.add_form.cursor_1 = len(state.add_form.input_1)
		state.add_form.field_index = 1  // usually the value is what changes
	}
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
	state.reveal_secrets = false
	// Invalidate settings cache on entry so backup/plugin counters reflect
	// state changes that happened while the user was in other views.
	if view == .SETTINGS_VIEW {
		state.settings.loaded = false
	}
	if view == .HOOKS_VIEW {
		state.hooks.loaded = false
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
	state.reveal_secrets = false
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
	visible_height := max(1, get_view_visible_height(state))

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
	duration := NOTIFICATION_DURATION_ERROR if kind == .ERROR else NOTIFICATION_DURATION_SUCCESS
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
// Long operations: progress overlay + cancel
// ============================================================================
//
// Shell snapshots, git clones and hooks run as child processes through
// run_command_timeout. Between tui_busy_begin and tui_busy_end the TUI paints
// a spinner frame first (so a slow child never leaves a stale screen), then
// subprocess_cancel_check repaints it and watches stdin: Ctrl+C or Esc kill
// the child. Other keys typed meanwhile are dropped.

// State the cancel check reports to (run_command_timeout's callback takes no
// arguments).
@(private = "file")
tui_busy_target: rawptr  // ^TUIState

BUSY_FRAME_INTERVAL :: 120 * time.Millisecond

tui_busy_begin :: proc(state: ^TUIState, message: string) {
	if len(state.busy.message) > 0 do delete(state.busy.message)
	state.busy.message = strings.clone(message)
	state.busy.cancelled = false
	state.busy.frame = 0
	// No screen (unit tests): nothing to paint and no terminal to read.
	if state.screen == nil do return
	tui_busy_target = rawptr(state)
	subprocess_cancel_check = tui_busy_poll
	tui_busy_paint(state)
}

// End the operation; true when the user cancelled it.
tui_busy_end :: proc(state: ^TUIState) -> (cancelled: bool) {
	subprocess_cancel_check = nil
	tui_busy_target = nil
	if len(state.busy.message) > 0 do delete(state.busy.message)
	state.busy.message = ""
	cancelled = state.busy.cancelled
	state.busy.cancelled = false
	// A child may have written to the terminal: repaint every cell.
	state.full_redraw = true
	state.needs_refresh = true
	return
}

@(private = "file")
tui_busy_paint :: proc(state: ^TUIState) {
	if state.screen == nil do return
	tui_render(state, state.screen)
	screen_flush(state.screen, false)
	state.busy.last_paint = time.tick_now()
}

// subprocess_cancel_check while busy: advance the spinner, and cancel on
// Ctrl+C or a lone Esc.
@(private = "file")
tui_busy_poll :: proc() -> bool {
	state := (^TUIState)(tui_busy_target)
	if state == nil do return false
	if state.busy.cancelled do return true

	fds := [1]posix.pollfd{{fd = posix.STDIN_FILENO, events = {.IN}}}
	if posix.poll(raw_data(fds[:]), 1, 0) > 0 && .IN in fds[0].revents {
		buf: [64]u8
		n := posix.read(posix.STDIN_FILENO, raw_data(buf[:]), len(buf))
		if n > 0 {
			got := buf[:n]
			if (n == 1 && got[0] == 0x1b) || slice.contains(got, 0x03) {
				state.busy.cancelled = true
				return true
			}
		}
	}
	if time.tick_since(state.busy.last_paint) >= BUSY_FRAME_INTERVAL {
		state.busy.frame += 1
		tui_busy_paint(state)
	}
	return false
}

// Centered "spinner message — Esc cancel" box while busy.
render_busy_overlay :: proc(state: ^TUIState, screen: ^Screen) {
	if len(state.busy.message) == 0 do return
	frames_unicode := []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}
	frames_ascii := []string{"|", "/", "-", "\\"}
	frames := frames_ascii if tui_plain_glyphs else frames_unicode
	spin := frames[state.busy.frame % len(frames)]

	width := min(state.terminal_width - 4, 60)
	if width < 12 do return
	height := 5
	x := (state.terminal_width - width) / 2
	y := max(0, (state.terminal_height - height) / 2)
	for dy in 1..<height - 1 {
		for dx in 1..<width - 1 do screen_set_cell(screen, x + dx, y + dy, Cell{char = ' '})
	}
	render_box_styled(screen, x, y, width, height, TUI_BORDER_FOCUSED)
	line := fmt.tprintf("%s %s", spin, state.busy.message)
	render_text_styled(screen, x + 2, y + 1, truncate_text(line, width - 4), TUI_PRIMARY, "", true)
	render_text_styled(screen, x + 2, y + 3, truncate_text("Esc / Ctrl+C cancel", width - 4), TUI_DIM)
}

// ============================================================================
// Reloading: external edits, the r key, and after our own writes
// ============================================================================

WATCH_INTERVAL :: 500 * time.Millisecond

@(private = "file")
file_stamp :: proc(path: string) -> FileStamp {
	info, err := os.stat(path, context.temp_allocator)
	if err != nil do return {}
	return FileStamp{mtime = time.to_unix_nanoseconds(info.modification_time), size = info.size, exists = true}
}

@(private = "file")
watch_paths :: proc() -> (toml, plugins, backup_dir, hooks: string) {
	toml       = fmt.tprintf("%s/%s", wayu.config, WAYU_TOML)
	plugins    = fmt.tprintf("%s/plugins.json", wayu.config)
	backup_dir = fmt.tprintf("%s/backup", wayu.data)
	hooks      = fmt.tprintf("%s/%s", wayu.config, HOOK_CONFIG_FILE)
	return
}

// Record the current stamps: what the TUI itself just wrote is not an
// external change.
tui_watch_sync :: proc(state: ^TUIState) {
	t, p, b, h := watch_paths()
	state.watch.toml = file_stamp(t)
	state.watch.plugins = file_stamp(p)
	state.watch.backup_dir = file_stamp(b)
	state.watch.hooks = file_stamp(h)
	state.watch.last_check = time.tick_now()
}

// Every WATCH_INTERVAL: drop the caches of views whose files changed since
// the last check (tui_ensure_data_loaded reloads them). Returns true when
// something was reloaded.
tui_check_external_changes :: proc(state: ^TUIState, force := false) -> bool {
	if !force && time.tick_since(state.watch.last_check) < WATCH_INTERVAL do return false
	// Never under an open dialog: its rows must stay what the user sees.
	if state.add_form.active || state.detail.shown do return false
	t, p, b, h := watch_paths()
	toml, plugins, backup_dir, hooks := file_stamp(t), file_stamp(p), file_stamp(b), file_stamp(h)
	state.watch.last_check = time.tick_now()

	changed := false
	if toml != state.watch.toml {
		state.watch.toml = toml
		for v in ([]TUIView{.PATH_VIEW, .ALIAS_VIEW, .CONSTANTS_VIEW}) do clear_view_cache(state, v)
		state.settings.loaded = false
		changed = true
	}
	if plugins != state.watch.plugins {
		state.watch.plugins = plugins
		clear_view_cache(state, .PLUGINS_VIEW)
		clear_registry_cache(state)
		state.settings.loaded = false
		changed = true
	}
	if backup_dir != state.watch.backup_dir {
		state.watch.backup_dir = backup_dir
		clear_view_cache(state, .BACKUPS_VIEW)
		state.settings.loaded = false
		changed = true
	}
	if hooks != state.watch.hooks {
		state.watch.hooks = hooks
		state.hooks.loaded = false
		changed = true
	}
	if changed do state.needs_refresh = true
	return changed
}

// Drop every cache, including the shell snapshot (external PATH/aliases/env
// as the TUI's own environment sees them), so each view re-reads its files.
tui_reload_all :: proc(state: ^TUIState) {
	for v in TUIView do clear_view_cache(state, v)
	clear_registry_cache(state)
	state.settings.loaded = false
	state.hooks.loaded = false
	cleanup_env_snapshot()
	clear_toml_content_cache()
	tui_watch_sync(state)
	state.full_redraw = true
	state.needs_refresh = true
}

// After a TUI write: reload `view` and the views a write also changes
// (backups, settings), and record the new stamps.
tui_after_write :: proc(state: ^TUIState, view: TUIView) {
	clear_view_cache(state, view)
	clear_view_cache(state, .BACKUPS_VIEW)
	state.settings.loaded = false
	tui_watch_sync(state)
}

// ============================================================================
// Backups: restore, cleanup
// ============================================================================

// Restore wayu.toml from `backup_path` (the CLI's restore_from_backup: the
// current file is backed up first, obsolete-schema / invalid backups are
// refused, init files regenerated).
tui_restore_backup :: proc(state: ^TUIState, backup_path: string) {
	name := get_base_name(backup_path)
	if wayu.dry_run {
		set_notification(state, .INFO, fmt.tprintf("[dry-run] would restore wayu.toml from %s", name))
		return
	}
	toml_file := fmt.tprintf("%s/%s", wayu.config, WAYU_TOML)
	if !config_lock_acquire() {
		set_notification(state, .ERROR, "Could not lock the wayu config (another wayu is writing)")
		return
	}
	ok := restore_from_backup(toml_file, backup_path)
	config_lock_release()
	if !ok {
		set_notification(state, .ERROR, failure_message("", fmt.tprintf("Failed to restore from %s", name)))
		return
	}
	for v in ([]TUIView{.PATH_VIEW, .ALIAS_VIEW, .CONSTANTS_VIEW}) do clear_view_cache(state, v)
	tui_after_write(state, .BACKUPS_VIEW)
	set_notification(state, .SUCCESS, fmt.tprintf("Restored wayu.toml from %s", name))
}

// 'u' in a data view: restore the newest wayu.toml backup (with confirmation).
tui_offer_undo :: proc(state: ^TUIState) {
	toml_file := fmt.tprintf("%s/%s", wayu.config, WAYU_TOML)
	backups := list_backups_for_file(toml_file)
	defer free_backup_infos(backups)
	idx := select_backup(backups, "")
	if idx < 0 {
		set_notification(state, .ERROR, "No wayu.toml backup to restore")
		return
	}
	show_restore_confirmation(state, backups[idx].backup_file)
}

// Backups beyond BACKUP_KEEP_COUNT, over every group the backup dir holds.
tui_excess_backups :: proc() -> int {
	keys := backup_list_groups()
	defer delete_backup_keys(keys)
	total := 0
	for key in keys {
		backups := list_backups_for_key(key, key)
		total += max(len(backups) - BACKUP_KEEP_COUNT, 0)
		free_backup_infos(backups)
	}
	return total
}

// 'c' in the Backups view: ask, then prune like `wayu backup rm --yes`.
tui_offer_cleanup :: proc(state: ^TUIState) {
	excess := tui_excess_backups()
	if excess == 0 {
		set_notification(state, .INFO, fmt.tprintf("No old backups to clean up (keeping %d per file)", BACKUP_KEEP_COUNT))
		return
	}
	show_confirmation(state, .CLEANUP, .BACKUPS_VIEW, "CLEAN UP BACKUPS", {
		fmt.tprintf("Remove %d old backup(s)?", excess),
		"",
		fmt.tprintf("The newest %d of each file are kept.", BACKUP_KEEP_COUNT),
	}, "")
}

// Prune every backup group to the newest BACKUP_KEEP_COUNT (shared with
// `wayu backup rm`: cleanup_old_backups_key).
tui_cleanup_backups :: proc(state: ^TUIState) {
	excess := tui_excess_backups()
	if wayu.dry_run {
		set_notification(state, .INFO, fmt.tprintf("[dry-run] would remove %d old backup(s)", excess))
		return
	}
	keys := backup_list_groups()
	defer delete_backup_keys(keys)
	removed := 0
	for key in keys do removed += cleanup_old_backups_key(key, BACKUP_KEEP_COUNT)
	if removed > 0 {
		set_notification(state, .SUCCESS, fmt.tprintf("Removed %d old backup(s)", removed))
	} else {
		set_notification(state, .INFO, "No old backups to clean up")
	}
	tui_after_write(state, .BACKUPS_VIEW)
}

// ============================================================================
// Plugin operations
// ============================================================================

// Enable / disable / toggle (nil) an installed plugin. Returns the new state.
tui_set_plugin_enabled :: proc(state: ^TUIState, name: string, enable: Maybe(bool) = nil) {
	if !config_lock_acquire() {
		set_notification(state, .ERROR, "Could not lock the wayu config (another wayu is writing)")
		return
	}
	defer config_lock_release()

	config, ok := read_plugin_config_json()
	defer cleanup_plugin_config_json(&config)
	if !ok {
		set_notification(state, .ERROR, failure_message("", "plugins.json could not be read"))
		return
	}
	for &plugin in config.plugins {
		if plugin.name != name do continue
		target := enable.? or_else !plugin.enabled
		verb := "Enabled" if target else "Disabled"
		if plugin.enabled == target {
			set_notification(state, .INFO, fmt.tprintf("%s is already %s", name, "enabled" if target else "disabled"))
			return
		}
		if wayu.dry_run {
			set_notification(state, .INFO, fmt.tprintf("[dry-run] would %s %s", "enable" if target else "disable", name))
			return
		}
		plugin.enabled = target
		if !tui_commit_plugin_config(&config) || !generate_plugins_file(wayu.shell) {
			set_notification(state, .ERROR, failure_message("", fmt.tprintf("Failed to %s %s", "enable" if target else "disable", name)))
			return
		}
		clear_view_cache(state, .PLUGINS_VIEW)
		tui_after_write(state, .PLUGINS_VIEW)
		set_notification(state, .SUCCESS, fmt.tprintf("%s %s", verb, name))
		return
	}
	set_notification(state, .ERROR, fmt.tprintf("Plugin not found: %s", name))
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

// Ask before installing registry plugin `key` (it clones from the network).
tui_offer_install :: proc(state: ^TUIState, key: string) {
	info, found := popular_plugin_find(key)
	if !found {
		set_notification(state, .ERROR, fmt.tprintf("Unknown plugin: %s", key))
		return
	}
	show_confirmation(state, .INSTALL, .PLUGINS_VIEW, "INSTALL PLUGIN", {
		fmt.tprintf("Install %s?", info.name),
		"",
		fmt.tprintf("Clones %s", info.url),
		"and adds it to plugins.json (enabled).",
	}, key)
}

// Install a registry plugin (confirmed) with a progress frame; Esc cancels
// the clone.
tui_install_registry_plugin :: proc(state: ^TUIState, key: string) {
	if wayu.dry_run {
		set_notification(state, .INFO, fmt.tprintf("[dry-run] would install %s", key))
		return
	}
	tui_busy_begin(state, fmt.tprintf("Installing %s…", key))
	ok, err := tui_install_plugin(key)
	cancelled := tui_busy_end(state)
	defer if len(err) > 0 do delete(err)
	if ok {
		// Reload installed list and invalidate registry so the
		// installed plugin is filtered out on next registry load
		clear_view_cache(state, .PLUGINS_VIEW)
		clear_registry_cache(state)
		tui_after_write(state, .PLUGINS_VIEW)
		set_notification(state, .SUCCESS, fmt.tprintf("Installed %s", key))
	} else if cancelled {
		set_notification(state, .INFO, fmt.tprintf("Cancelled: %s was not installed", key))
	} else {
		set_notification(state, .ERROR, failure_message(err, fmt.tprintf("Failed to install %s", key)))
	}
}

// Install registry plugin `key`: clone, check it loads something, record
// it in plugins.json (backed up first) and regenerate the loader. Never
// writes under --dry-run. err (owned when non-empty) says why it failed.
tui_install_plugin :: proc(key: string) -> (ok: bool, err: string) {
	info, found := popular_plugin_find(key)
	if !found { return false, fmt.aprintf("Unknown plugin: %s", key) }
	if wayu.dry_run { return false, strings.clone("dry run: nothing installed") }

	plugins_dir := get_plugins_dir()
	defer delete(plugins_dir)

	if !os.exists(plugins_dir) {
		if mk_err := os.make_directory(plugins_dir); mk_err != nil {
			return false, fmt.aprintf("Could not create %s", plugins_dir)
		}
	}

	dest := fmt.aprintf("%s/%s", plugins_dir, info.name)
	defer delete(dest)

	if !config_lock_acquire() { return false, strings.clone("Could not lock the wayu config") }
	defer config_lock_release()

	// Read (and validate) plugins.json BEFORE touching anything: if it can't
	// be parsed, writing our in-memory copy back would replace every other
	// plugin entry with just this one.
	config, cfg_ok := read_plugin_config_json()
	defer cleanup_plugin_config_json(&config)
	if !cfg_ok { return false, strings.clone("plugins.json could not be read") }
	// Invalid hooks.conf: refuse before cloning/writing (CLI exits 78).
	if msg, bad := hook_config_error(); bad { return false, strings.clone(msg) }

	hook_pre_plugin_install(info.name)

	existed_before := os.exists(dest)
	cloned, clone_err := git_clone(info.url, dest)
	if !cloned {
		if !existed_before && os.exists(dest) { remove_cloned_plugin_dir(dest, plugins_dir) }
		if len(clone_err) > 0 { return false, clone_err }
		delete(clone_err)
		return false, fmt.aprintf("Could not clone %s", info.url)
	}
	delete(clone_err)
	// Same rule as `plugin add`: never install a plugin that loads nothing.
	if !plugin_compat_loads_any(info.shell, plugin_loadable_shells(info.name, dest, nil)) {
		if !existed_before { remove_cloned_plugin_dir(dest, plugins_dir) }
		return false, fmt.aprintf("%s has nothing to load for this shell", info.name)
	}

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

	if !tui_commit_plugin_config(&config) { return false, strings.clone("Could not write plugins.json") }
	if !generate_plugins_file(wayu.shell) { return false, strings.clone("Could not regenerate the plugin loader") }

	hook_post_plugin_install(info.name)
	return true, ""
}

// ============================================================================
// Terminal too small / dry-run badge
// ============================================================================

tui_too_small :: proc(state: ^TUIState) -> bool {
	return state.terminal_width < MIN_TERMINAL_WIDTH || state.terminal_height < MIN_TERMINAL_HEIGHT
}

// Below MIN_TERMINAL_WIDTH x MIN_TERMINAL_HEIGHT the views can't show a
// row: say so instead of drawing an empty, misleading layout.
render_too_small :: proc(state: ^TUIState, screen: ^Screen) {
	lines := []string{
		"Terminal too small",
		fmt.tprintf("%dx%d, need %dx%d", state.terminal_width, state.terminal_height, MIN_TERMINAL_WIDTH, MIN_TERMINAL_HEIGHT),
		"q / Esc to leave",
	}
	top := max(0, (state.terminal_height - len(lines)) / 2)
	for line, i in lines {
		if top + i >= screen.height do break
		text := truncate_text(line, screen.width)
		x := max(0, (screen.width - visual_width(text)) / 2)
		render_text_styled(screen, x, top + i, text, TUI_PRIMARY if i == 0 else TUI_DIM, "", i == 0)
	}
}

// " DRY RUN " on the top border while --dry-run is on.
render_dry_run_badge :: proc(state: ^TUIState, screen: ^Screen) {
	if !wayu.dry_run do return
	badge := " DRY RUN "
	// The box's top-right corner sits at column width - BORDER_HORIZONTAL_TOTAL.
	x := state.terminal_width - BORDER_HORIZONTAL_TOTAL - 2 - len(badge)
	if x <= BORDER_LEFT_WIDTH + 2 do return
	render_text_styled(screen, x, BORDER_TOP_HEIGHT, badge, TUI_WARNING, "", true)
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
		config, ok := toml_read_file_lenient(toml_file)
		defer cleanup_toml_config(&config)
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
		config, ok := toml_read_file_lenient(toml_file)
		defer cleanup_toml_config(&config)
		if ok {
			// The first snapshot runs the user's interactive shell (rc files
			// and all): show progress, allow Esc, and repaint afterwards.
			if !ENV_SNAPSHOT_CACHE.aliases_initialized {
				tui_busy_begin(state, "Reading aliases from your shell…")
			}
			env_aliases := snapshot_aliases()
			if len(state.busy.message) > 0 do tui_busy_end(state)

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

				// Map order is random: list externals by name so rows (and
				// the selection) stay put across reloads.
				ext_names := make([dynamic]string, context.temp_allocator)
				for env_name in env_aliases {
					if _, in_wayu := wayu_aliases[env_name]; !in_wayu do append(&ext_names, env_name)
				}
				slice.sort(ext_names[:])
				for env_name in ext_names {
					env_cmd := env_aliases[env_name]
					display := fmt.aprintf("%s=%s", env_name, env_cmd)
					cache_push(&items, &meta, display, env_name, env_cmd, .EXTERNAL)
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

		config, ok := toml_read_file_lenient(toml_file)
		defer cleanup_toml_config(&config)
		if ok {
			for const in config.constants {
				wayu_constants[const.name] = true

				is_active := snapshot_env_var(const.name) != nil
				source := RowSource.WAYU_ACTIVE if is_active else RowSource.WAYU_INACTIVE

				display := fmt.aprintf("%s=%s", const.name, mask_secret_value(const.name, const.value))
				cache_push(&items, &meta, display, const.name, const.value, source)
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
					display := fmt.aprintf("%s=%s", ext_const_name, mask_secret_value(ext_const_name, env_val))
					cache_push(&items, &meta, display, ext_const_name, env_val, .EXTERNAL)
				}
			}
		}
	} else {
		entries := read_config_entries(&CONSTANTS_SPEC)
		defer cleanup_entries(&entries)

		for entry in entries {
			display := fmt.aprintf("%s=%s", entry.name, mask_secret_value(entry.name, entry.value))
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

// Every backup in backup/ (wayu.toml first, then the other groups `wayu
// backup list` shows: plugins.json, the rc file, init files…), newest first.
// Row key = backup file path, value = its group (backup key).
tui_load_backups :: proc(state: ^TUIState) {
	items := make([dynamic]string)
	meta  := make([dynamic]RowMeta)
	defer tui_store_cache(state, .BACKUPS_VIEW, items, meta)

	keys := backup_list_groups()
	defer delete_backup_keys(keys)
	for key in keys {
		backups := list_backups_for_key(key, key)
		defer free_backup_infos(backups)
		for b in backups {
			cache_push(&items, &meta, strings.clone(get_base_name(b.backup_file)), b.backup_file, key)
		}
	}
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

@(private = "file")
settings_free_strings :: proc(st: ^SettingsCache) {
	if len(st.shell)      > 0 { delete(st.shell) }
	if len(st.config_dir) > 0 { delete(st.config_dir) }
	if len(st.version)    > 0 { delete(st.version) }
	if len(st.toml_path)  > 0 { delete(st.toml_path) }
	if len(st.editor)     > 0 { delete(st.editor) }
	st.shell, st.config_dir, st.version, st.toml_path, st.editor = "", "", "", "", ""
}

tui_load_settings :: proc(state: ^TUIState) {
	if state.settings.loaded { return }

	settings_free_strings(&state.settings)

	state.settings.shell      = strings.clone(get_shell_name(wayu.shell))
	state.settings.config_dir = strings.clone(wayu.config)
	state.settings.dry_run    = wayu.dry_run
	state.settings.version    = strings.clone(VERSION)
	state.settings.keep       = BACKUP_KEEP_COUNT
	state.settings.color      = color_profile_label(CURRENT_COLOR_PROFILE)

	editor := os.get_env("VISUAL", context.temp_allocator)
	if len(editor) == 0 do editor = os.get_env("EDITOR", context.temp_allocator)
	state.settings.editor = strings.clone(editor if len(editor) > 0 else "(not set)")

	toml_full := fmt.aprintf("%s/%s", wayu.config, WAYU_TOML)
	state.settings.toml_path   = toml_full
	state.settings.toml_exists = os.exists(toml_full)

	// Every backup group, like the Backups view and `wayu backup list`.
	total_backups := 0
	keys := backup_list_groups()
	for key in keys {
		backups := list_backups_for_key(key, key)
		total_backups += len(backups)
		free_backup_infos(backups)
	}
	delete_backup_keys(keys)
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

// Short name of a color profile for the Settings view (static).
color_profile_label :: proc(profile: ColorProfile) -> string {
	switch profile {
	case .ASCII:     return "off (NO_COLOR / --no-color)"
	case .ANSI:      return "16 colors"
	case .ANSI256:   return "256 colors"
	case .TRUECOLOR: return "truecolor"
	}
	return "unknown"
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
	if view == .HOOKS_VIEW && !state.hooks.loaded {
		tui_load_hooks(state)
		loaded = true
	}
	if view == .SETTINGS_VIEW && !state.settings.loaded {
		tui_load_settings(state)
		loaded = true
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

			fg := tui_theme_color(curr.fg) if use_color else ""
			bg := tui_theme_color(curr.bg) if use_color else ""

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
			if curr.comb != 0 do strings.write_rune(&builder, curr.comb)  // zero columns
			screen.cursor_x += max(1, get_rune_width(ch))
		}
	}

	// Reset attributes at end of frame
	if active_fg != "" || active_bg != "" || active_bold || active_dim {
		strings.write_string(&builder, "\x1b[0m")
	}

	// Park the hidden cursor on the selected row (screen readers track it).
	if screen.has_focus && (screen.cursor_x != screen.focus_x || screen.cursor_y != screen.focus_y) {
		fmt.sbprintf(&builder, "\x1b[%d;%dH", screen.focus_y + 1, screen.focus_x + 1)
		screen.cursor_x, screen.cursor_y = screen.focus_x, screen.focus_y
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
// Wide runes (CJK, emoji) occupy two cells; a combining mark joins the
// previous cell; other zero-width runes (VS16, ZWJ) are dropped.
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
	last_x := -1  // lead cell of the last glyph written (for combining marks)
	style := Cell{fg = fg, bg = bg, bold = bold}
	for ch in text {
		if current_x >= screen.width do break
		// ESC bytes must never reach Cell.char — they inflate logical cursor_x
		// and drift the diff renderer. See thoughts/scroll_bug_spec.md.
		if ch == 0x1b do continue
		if get_rune_width(ch) == 0 {
			screen_attach_combining(screen, last_x, y, ch)
			continue
		}

		w := screen_put_rune(screen, current_x, y, ch, style)
		if w == 0 do break  // wide rune doesn't fit before the right edge
		last_x = current_x
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
	#partial switch state.notify.kind {
	case .SUCCESS:
		color = TUI_SUCCESS
		prefix = " ✓ "
	case .INFO:
		color = TUI_INFO
		prefix = " ℹ "
	case:
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

// ============================================================================
// Hooks view: every hook event, its command, enable/disable, test-run
// ============================================================================

// hooks.conf keys in display order, with the event each one runs on.
HOOK_KEYS :: [?]struct { key: string, hook: HookType }{
	{"pre_path_add", .PRE_PATH_ADD},
	{"post_path_add", .POST_PATH_ADD},
	{"pre_path_remove", .PRE_PATH_REMOVE},
	{"post_path_remove", .POST_PATH_REMOVE},
	{"pre_alias_add", .PRE_ALIAS_ADD},
	{"post_alias_add", .POST_ALIAS_ADD},
	{"pre_alias_remove", .PRE_ALIAS_REMOVE},
	{"post_alias_remove", .POST_ALIAS_REMOVE},
	{"pre_constant_add", .PRE_CONSTANT_ADD},
	{"post_constant_add", .POST_CONSTANT_ADD},
	{"pre_constant_remove", .PRE_CONSTANT_REMOVE},
	{"post_constant_remove", .POST_CONSTANT_REMOVE},
	{"pre_plugin_install", .PRE_PLUGIN_INSTALL},
	{"post_plugin_install", .POST_PLUGIN_INSTALL},
	{"pre_export", .PRE_EXPORT},
	{"post_export", .POST_EXPORT},
}

// Prefix the TUI writes in front of a hooks.conf line it disables (the
// loader skips comments, so the hook stops running; enabling strips it).
HOOK_DISABLED_PREFIX :: "# disabled: "

hooks_cache_clear :: proc(cache: ^HooksCache) {
	for r in cache.rows do delete(r.command)
	clear(&cache.rows)
	cache.loaded = false
}

// Split a hooks.conf `key = value` line the way load_hook_config does
// (one surrounding quote pair removed). ok=false when it isn't one.
@(private = "file")
hook_line_split :: proc(line: string) -> (key, value: string, ok: bool) {
	eq := strings.index_byte(line, '=')
	if eq <= 0 do return "", "", false
	key = strings.trim_space(line[:eq])
	value = strings.trim_space(line[eq + 1:])
	if len(value) >= 2 && value[0] == value[len(value) - 1] && (value[0] == '"' || value[0] == '\'') {
		value = value[1:len(value) - 1]
	}
	return key, value, true
}

// Load the hooks view rows: active hooks through load_hook_config (the same
// reader every wayu operation uses), plus lines the TUI disabled.
tui_load_hooks :: proc(state: ^TUIState) {
	hooks_cache_clear(&state.hooks)
	config := load_hook_config()
	defer free_hook_config(config)

	disabled := make(map[string]string, allocator = context.temp_allocator)
	path := fmt.tprintf("%s/%s", wayu.config, HOOK_CONFIG_FILE)
	if data, err := os.read_entire_file(path, context.temp_allocator); err == nil {
		for line in strings.split_lines(string(data), context.temp_allocator) {
			t := strings.trim_space(line)
			if !strings.has_prefix(t, HOOK_DISABLED_PREFIX) do continue
			if key, value, ok := hook_line_split(t[len(HOOK_DISABLED_PREFIX):]); ok do disabled[key] = value
		}
	}

	for k in HOOK_KEYS {
		cmd := hook_config_command(&config, k.hook)
		row := HookRow{key = k.key, hook = k.hook}
		if len(cmd) > 0 {
			row.command = strings.clone(cmd)
			row.invalid = hook_double_quoted_placeholder(cmd)
		} else if d, has := disabled[k.key]; has {
			row.command = strings.clone(d)
			row.disabled = true
		}
		append(&state.hooks.rows, row)
	}
	state.hooks.loaded = true
}

// The command load_hook_config read for `hook` ("" when not configured).
@(private = "file")
hook_config_command :: proc(config: ^HookConfig, hook: HookType) -> string {
	switch hook {
	case .PRE_PATH_ADD:         return config.pre_path_add
	case .POST_PATH_ADD:        return config.post_path_add
	case .PRE_PATH_REMOVE:      return config.pre_path_remove
	case .POST_PATH_REMOVE:     return config.post_path_remove
	case .PRE_ALIAS_ADD:        return config.pre_alias_add
	case .POST_ALIAS_ADD:       return config.post_alias_add
	case .PRE_ALIAS_REMOVE:     return config.pre_alias_remove
	case .POST_ALIAS_REMOVE:    return config.post_alias_remove
	case .PRE_CONSTANT_ADD:     return config.pre_constant_add
	case .POST_CONSTANT_ADD:    return config.post_constant_add
	case .PRE_CONSTANT_REMOVE:  return config.pre_constant_remove
	case .POST_CONSTANT_REMOVE: return config.post_constant_remove
	case .PRE_EXPORT:           return config.pre_export
	case .POST_EXPORT:          return config.post_export
	case .PRE_PLUGIN_INSTALL:   return config.pre_plugin_install
	case .POST_PLUGIN_INSTALL:  return config.post_plugin_install
	}
	return ""
}

// Selected hooks row (nil when the list is empty / not loaded).
selected_hook :: proc(state: ^TUIState) -> ^HookRow {
	if state.selected_index < 0 || state.selected_index >= len(state.hooks.rows) do return nil
	return &state.hooks.rows[state.selected_index]
}

// Enter in the hooks view: what the hook runs and when.
show_hook_detail :: proc(state: ^TUIState) {
	row := selected_hook(state)
	if row == nil do return
	lines := make([dynamic]string, context.temp_allocator)
	status := "not configured"
	if row.disabled do status = "disabled (space enables)"
	else if len(row.invalid) > 0 do status = fmt.tprintf("INVALID: %s inside \"...\" is refused", row.invalid)
	else if len(row.command) > 0 do status = "enabled"
	append(&lines, fmt.tprintf("Status:  %s", status))
	if len(row.command) > 0 {
		append(&lines, fmt.tprintf("Command: %s", row.command))
	} else {
		append(&lines, fmt.tprintf("Add `%s = <command>` with: wayu hooks edit", row.key))
	}
	append(&lines, "")
	append(&lines, "{path} {name} {value} are passed quoted (WAYU_HOOK_*).")
	append(&lines, "t runs it once with sample values; space enables/disables.")
	show_detail_overlay(state, row.key, lines[:])
}

// space in the hooks view: comment the hook's line out (HOOK_DISABLED_PREFIX)
// or back in. hooks.conf is backed up first.
tui_toggle_hook :: proc(state: ^TUIState) {
	row := selected_hook(state)
	if row == nil || len(row.command) == 0 {
		set_notification(state, .INFO, "Not configured: add it with `wayu hooks edit`")
		return
	}
	enable := row.disabled
	if wayu.dry_run {
		set_notification(state, .INFO, fmt.tprintf("[dry-run] would %s %s", "enable" if enable else "disable", row.key))
		return
	}
	path := fmt.tprintf("%s/%s", wayu.config, HOOK_CONFIG_FILE)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		set_notification(state, .ERROR, fmt.tprintf("Could not read %s", path))
		return
	}
	b := strings.builder_make(context.temp_allocator)
	changed := 0
	lines := strings.split(string(data), "\n", context.temp_allocator)
	for line, i in lines {
		t := strings.trim_space(line)
		out := line
		if enable && strings.has_prefix(t, HOOK_DISABLED_PREFIX) {
			if key, _, ok := hook_line_split(t[len(HOOK_DISABLED_PREFIX):]); ok && key == row.key {
				out = t[len(HOOK_DISABLED_PREFIX):]
				changed += 1
			}
		} else if !enable && !strings.has_prefix(t, "#") {
			if key, _, ok := hook_line_split(t); ok && key == row.key {
				out = strings.concatenate({HOOK_DISABLED_PREFIX, t}, context.temp_allocator)
				changed += 1
			}
		}
		strings.write_string(&b, out)
		if i < len(lines) - 1 do strings.write_byte(&b, '\n')
	}
	if changed == 0 {
		set_notification(state, .ERROR, fmt.tprintf("%s not found in %s", row.key, path))
		return
	}
	if !create_backup_tui(path) || !safe_write_file(path, transmute([]u8)strings.to_string(b)) {
		set_notification(state, .ERROR, fmt.tprintf("Could not write %s", path))
		return
	}
	set_notification(state, .SUCCESS, fmt.tprintf("%s %s", "Enabled" if enable else "Disabled", row.key))
	state.hooks.loaded = false
	tui_watch_sync(state)
}

// 't' in the hooks view: run the selected hook once, like wayu would, with
// sample placeholder values; show its exit status and output.
tui_test_hook :: proc(state: ^TUIState) {
	row := selected_hook(state)
	if row == nil || len(row.command) == 0 {
		set_notification(state, .INFO, "Not configured: nothing to run")
		return
	}
	if len(row.invalid) > 0 {
		set_notification(state, .ERROR, fmt.tprintf("%s is invalid (%s inside \"...\") and never runs", row.key, row.invalid))
		return
	}
	cmd := hook_render_command(row.command)
	defer delete(cmd)
	if wayu.dry_run {
		set_notification(state, .INFO, fmt.tprintf("[dry-run] would run: %s", row.command))
		return
	}

	_ = os.set_env(HOOK_ENV_PATH, "/tmp/wayu-hook-test")
	_ = os.set_env(HOOK_ENV_NAME, "wayu_hook_test")
	_ = os.set_env(HOOK_ENV_VALUE, "test value")
	defer {
		_ = os.unset_env(HOOK_ENV_PATH)
		_ = os.unset_env(HOOK_ENV_NAME)
		_ = os.unset_env(HOOK_ENV_VALUE)
	}
	tui_busy_begin(state, fmt.tprintf("Running %s…", row.key))
	r := run_command_timeout({"sh", "-c", cmd}, HOOK_TUI_TIMEOUT_MS)
	tui_busy_end(state)
	defer command_result_destroy(&r)

	status := "exit 0"
	if r.cancelled do status = "cancelled"
	else if r.timed_out do status = fmt.tprintf("timed out after %ds", HOOK_TUI_TIMEOUT_MS / 1000)
	else if !r.ok do status = "failed (non-zero exit)"
	lines := make([dynamic]string, context.temp_allocator)
	append(&lines, fmt.tprintf("Result:  %s", status))
	append(&lines, fmt.tprintf("Command: %s", row.command))
	append(&lines, "Sample:  {path}=/tmp/wayu-hook-test {name}=wayu_hook_test")
	MAX_OUTPUT_LINES :: 6
	shown := 0
	for out in ([]string{r.stdout, r.stderr}) {
		for line in strings.split_lines(out, context.temp_allocator) {
			if len(line) == 0 || shown >= MAX_OUTPUT_LINES do continue
			if shown == 0 do append(&lines, "")
			append(&lines, line)
			shown += 1
		}
	}
	show_detail_overlay(state, fmt.tprintf("TEST %s", row.key), lines[:])
}

// ============================================================================
// Settings view rows (Enter toggles the session settings)
// ============================================================================

SettingId :: enum {
	VERSION, SHELL, CONFIG_DIR, TOML, BACKUPS, KEEP, PLUGINS, EDITOR, COLOR, DRY_RUN,
}

SETTING_ROWS :: [?]SettingId{.VERSION, .SHELL, .CONFIG_DIR, .TOML, .BACKUPS, .KEEP, .PLUGINS, .EDITOR, .COLOR, .DRY_RUN}

// Label + value of a settings row (temp-allocated) and whether Enter changes it.
setting_row :: proc(state: ^TUIState, id: SettingId) -> (label, value: string, toggles: bool) {
	st := &state.settings
	switch id {
	case .VERSION:    return "Version", st.version, false
	case .SHELL:      return "Shell", st.shell, false
	case .CONFIG_DIR: return "Config dir", st.config_dir, false
	case .TOML:       return "wayu.toml", st.toml_path if st.toml_exists else "missing", false
	case .BACKUPS:    return "Backups", fmt.tprintf("%d (Backups view)", st.backups), false
	case .KEEP:       return "Backups kept", fmt.tprintf("%d per file", st.keep), false
	case .PLUGINS:    return "Plugins", fmt.tprintf("%d enabled", st.plugins), false
	case .EDITOR:     return "Editor", st.editor, false
	case .COLOR:      return "Colors", "off (this session)" if tui_color_mode == .ASCII else fmt.tprintf("%s", st.color), true
	case .DRY_RUN:    return "Dry run", "on — nothing is written (this session)" if wayu.dry_run else "off", true
	}
	return "", "", false
}

// Enter in Settings: toggle dry-run or colors for this session (wayu.toml is
// not changed; restart wayu to get the defaults back).
toggle_selected_setting :: proc(state: ^TUIState) {
	rows := SETTING_ROWS
	if state.selected_index < 0 || state.selected_index >= len(rows) do return
	#partial switch rows[state.selected_index] {
	case .DRY_RUN:
		wayu.dry_run = !wayu.dry_run
		state.settings.dry_run = wayu.dry_run
		set_notification(state, .INFO, "Dry run on: changes are previewed, not written" if wayu.dry_run else "Dry run off: changes are written")
	case .COLOR:
		if tui_color_mode == .ASCII {
			tui_color_mode = CURRENT_COLOR_PROFILE if CURRENT_COLOR_PROFILE != .ASCII else .ANSI256
		} else {
			tui_color_mode = .ASCII
		}
		set_notification(state, .INFO, "Colors on" if tui_color_mode != .ASCII else "Colors off")
	case:
		set_notification(state, .INFO, "Read-only")
	}
	state.full_redraw = true
	state.needs_refresh = true
}

