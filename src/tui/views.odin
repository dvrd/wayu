// tui_views.odin - TUI view rendering for all wayu configuration types
//
// This module implements the 8 TUI views:
// - Main Menu (navigation hub)
// - PATH View (list PATH entries)
// - Alias View (list aliases with definitions)
// - Constants View (list environment variables)
// - Completions View (list completion scripts)
// - Backups View (list backups with timestamps)
// - Plugins View (placeholder)
// - Settings View (configuration display)
//
// Note: This module does NOT import the main wayu package to avoid circular dependencies.
// Data loading is handled by bridge functions in main.odin that populate the state.data_cache.

package wayu_tui

import "core:fmt"
import "core:strings"

// ============================================================================
// PATH View
// ============================================================================

// Render PATH configuration view with scrollable list (using layout constants)
render_path_view :: proc(state: ^TUIState, screen: ^Screen) {
	// Draw outer border using calculated dimensions
	border_width, border_height := calculate_border_dimensions(state.terminal_width, state.terminal_height)
	render_box_styled(screen, BORDER_LEFT_WIDTH, BORDER_TOP_HEIGHT, border_width, border_height, TUI_BORDER_FOCUSED)

	// Data should be loaded by bridge layer
	if state.data_cache[.PATH_VIEW] == nil {
		header_x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT
		render_text_styled(screen, header_x, HEADER_TITLE_LINE + CONTENT_PADDING_TOP, "📂 PATH Configuration", TUI_PRIMARY, "", true)
		render_text_styled(screen, header_x, HEADER_TITLE_LINE + CONTENT_PADDING_TOP + 2, "Loading...", TUI_DIM)
		state.needs_refresh = true
		return
	}

	items := cast(^[dynamic]string)state.data_cache[.PATH_VIEW]

	// Header (hot pink + bold)
	header_x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT
	render_text_styled(screen, header_x, HEADER_TITLE_LINE + CONTENT_PADDING_TOP, "📂 PATH Configuration", TUI_PRIMARY, "", true)
	count_text := fmt.tprintf("%d entries", len(items))
	// Note: tprintf() uses temp buffer, do NOT delete
	render_text_styled(screen, header_x, HEADER_COUNT_LINE + CONTENT_PADDING_TOP, count_text, TUI_DIM)

	if len(items) == 0 {
		render_text_styled(screen, header_x, LIST_ITEM_START_LINE + 1, "No PATH entries found", TUI_DIM)
	} else {
		// List items with scrolling
		visible_height := calculate_visible_height(state.terminal_height)
		start := state.scroll_offset
		end := min(start + visible_height, len(items))

		for i in start..<end {
			y := calculate_list_item_y(i - start)
			entry := items[i]

			if i == state.selected_index {
				// Selected item: hot pink text + bold (NO background)
				text := fmt.tprintf("> %s", entry)
				// Note: tprintf() uses temp buffer, do NOT delete
				render_text_styled(screen, header_x, y, text, TUI_PRIMARY, "", true)
			} else {
				// Normal item: muted gray text (indented by selection prefix width)
				text := fmt.tprintf("  %s", entry)
				// Note: tprintf() uses temp buffer, do NOT delete
				render_text_styled(screen, header_x + SELECTION_PREFIX_WIDTH, y, text, TUI_MUTED)
			}
		}

		// Show scroll indicator if needed (dim gray)
		if len(items) > visible_height {
			scroll_info := fmt.tprintf("Showing %d-%d of %d", start+1, end, len(items))
			// Note: tprintf() uses temp buffer, do NOT delete
			scroll_y := LIST_ITEM_START_LINE + visible_height
			render_text_styled(screen, header_x, scroll_y, scroll_info, TUI_DIM)
		}
	}

	// Footer with shortcuts (muted gray)
	footer_y := calculate_footer_y(state.terminal_height)
	render_text_styled(screen, header_x, footer_y, "d=Delete  Esc=Back  ↑/↓ or j/k=Navigate", TUI_MUTED)
}

// ============================================================================
// Alias View
// ============================================================================

// Render alias view with name=command format (PHASE 1: COLORED + BORDERED)
render_alias_view :: proc(state: ^TUIState, screen: ^Screen) {
	// Draw outer border
	border_width := min(state.terminal_width - 2, 80)
	border_height := state.terminal_height - 2
	render_box_styled(screen, 1, 1, border_width, border_height, TUI_BORDER_FOCUSED)

	if state.data_cache[.ALIAS_VIEW] == nil {
		render_text_styled(screen, 3, 2, "🔑 Aliases", TUI_PRIMARY, "", true)
		render_text_styled(screen, 3, 4, "Loading...", TUI_DIM)
		state.needs_refresh = true
		return
	}

	items := cast(^[dynamic]string)state.data_cache[.ALIAS_VIEW]

	// Header (hot pink + bold)
	render_text_styled(screen, 3, 2, "🔑 Aliases", TUI_PRIMARY, "", true)
	count_text := fmt.tprintf("%d aliases", len(items))
	// Note: tprintf() uses temp buffer, do NOT delete
	render_text_styled(screen, 3, 3, count_text, TUI_DIM)

	if len(items) == 0 {
		render_text_styled(screen, 3, 5, "No aliases found", TUI_DIM)
	} else {
		// List items with scrolling (adjusted for border)
		visible_height := state.terminal_height - 8
		start := state.scroll_offset
		end := min(start + visible_height, len(items))

		for i in start..<end {
			y := 5 + (i - start)
			item := items[i]

			if i == state.selected_index {
				// Selected: hot pink text + bold (NO background)
				text := fmt.tprintf("> %s", item)
				// Note: tprintf() uses temp buffer, do NOT delete
				render_text_styled(screen, 3, y, text, TUI_PRIMARY, "", true)
			} else {
				// Normal: muted gray text
				text := fmt.tprintf("  %s", item)
				// Note: tprintf() uses temp buffer, do NOT delete
				render_text_styled(screen, 5, y, text, TUI_MUTED)
			}
		}

		// Scroll indicator (dim gray)
		if len(items) > visible_height {
			scroll_info := fmt.tprintf("Showing %d-%d of %d", start+1, end, len(items))
			// Note: tprintf() uses temp buffer, do NOT delete
			render_text_styled(screen, 3, 5 + visible_height, scroll_info, TUI_DIM)
		}
	}

	// Footer (muted gray)
	footer_y := state.terminal_height - 3
	render_text_styled(screen, 3, footer_y, "d=Delete  Esc=Back  ↑/↓ or j/k=Navigate", TUI_MUTED)
}

// ============================================================================
// Constants View
// ============================================================================

// Render constants view with NAME="value" format (PHASE 1: COLORED + BORDERED)
render_constants_view :: proc(state: ^TUIState, screen: ^Screen) {
	// Draw outer border
	border_width := min(state.terminal_width - 2, 80)
	border_height := state.terminal_height - 2
	render_box_styled(screen, 1, 1, border_width, border_height, TUI_BORDER_FOCUSED)

	if state.data_cache[.CONSTANTS_VIEW] == nil {
		render_text_styled(screen, 3, 2, "💾 Environment Constants", TUI_PRIMARY, "", true)
		render_text_styled(screen, 3, 4, "Loading...", TUI_DIM)
		state.needs_refresh = true
		return
	}

	items := cast(^[dynamic]string)state.data_cache[.CONSTANTS_VIEW]

	// Header (hot pink + bold)
	render_text_styled(screen, 3, 2, "💾 Environment Constants", TUI_PRIMARY, "", true)
	count_text := fmt.tprintf("%d constants", len(items))
	// Note: tprintf() uses temp buffer, do NOT delete
	render_text_styled(screen, 3, 3, count_text, TUI_DIM)

	if len(items) == 0 {
		render_text_styled(screen, 3, 5, "No constants found", TUI_DIM)
	} else {
		// List with scrolling (adjusted for border)
		visible_height := state.terminal_height - 8
		start := state.scroll_offset
		end := min(start + visible_height, len(items))

		for i in start..<end {
			y := 5 + (i - start)
			item := items[i]

			if i == state.selected_index {
				// Selected: hot pink text + bold (NO background)
				text := fmt.tprintf("> %s", item)
				// Note: tprintf() uses temp buffer, do NOT delete
				render_text_styled(screen, 3, y, text, TUI_PRIMARY, "", true)
			} else {
				// Normal: muted gray text
				text := fmt.tprintf("  %s", item)
				// Note: tprintf() uses temp buffer, do NOT delete
				render_text_styled(screen, 5, y, text, TUI_MUTED)
			}
		}

		// Scroll indicator (dim gray)
		if len(items) > visible_height {
			scroll_info := fmt.tprintf("Showing %d-%d of %d", start+1, end, len(items))
			// Note: tprintf() uses temp buffer, do NOT delete
			render_text_styled(screen, 3, 5 + visible_height, scroll_info, TUI_DIM)
		}
	}

	// Footer (muted gray)
	footer_y := state.terminal_height - 3
	render_text_styled(screen, 3, footer_y, "d=Delete  Esc=Back  ↑/↓ or j/k=Navigate", TUI_MUTED)
}

// ============================================================================
// Completions View
// ============================================================================

// Render completions view (placeholder - basic list) (PHASE 1: COLORED + BORDERED)
render_completions_view :: proc(state: ^TUIState, screen: ^Screen) {
	// Draw outer border
	border_width := min(state.terminal_width - 2, 80)
	border_height := state.terminal_height - 2
	render_box_styled(screen, 1, 1, border_width, border_height, TUI_BORDER_NORMAL)

	// Header (hot pink + bold)
	render_text_styled(screen, 3, 2, "🎯 Completions", TUI_PRIMARY, "", true)
	render_text_styled(screen, 3, 4, "Completion scripts management", TUI_MUTED)
	render_text_styled(screen, 3, 6, "(Feature coming in Phase 7)", TUI_DIM)

	// Footer (muted gray)
	footer_y := state.terminal_height - 3
	render_text_styled(screen, 3, footer_y, "Esc=Back", TUI_MUTED)
}

// ============================================================================
// Backups View
// ============================================================================

// Render backups view with timestamps and config types (PHASE 1: COLORED + BORDERED)
render_backups_view :: proc(state: ^TUIState, screen: ^Screen) {
	// Draw outer border
	border_width := min(state.terminal_width - 2, 80)
	border_height := state.terminal_height - 2
	render_box_styled(screen, 1, 1, border_width, border_height, TUI_BORDER_FOCUSED)

	if state.data_cache[.BACKUPS_VIEW] == nil {
		render_text_styled(screen, 3, 2, "💾 Backups", TUI_PRIMARY, "", true)
		render_text_styled(screen, 3, 4, "Loading...", TUI_DIM)
		state.needs_refresh = true
		return
	}

	items := cast(^[dynamic]string)state.data_cache[.BACKUPS_VIEW]

	// Header (hot pink + bold)
	render_text_styled(screen, 3, 2, "💾 Backups", TUI_PRIMARY, "", true)
	count_text := fmt.tprintf("%d backups available", len(items))
	// Note: tprintf() uses temp buffer, do NOT delete
	render_text_styled(screen, 3, 3, count_text, TUI_DIM)

	if len(items) == 0 {
		render_text_styled(screen, 3, 5, "No backups found", TUI_DIM)
	} else {
		// List backups (adjusted for border)
		visible_height := state.terminal_height - 8
		start := state.scroll_offset
		end := min(start + visible_height, len(items))

		for i in start..<end {
			y := 5 + (i - start)
			backup := items[i]

			if i == state.selected_index {
				// Selected: hot pink text + bold (NO background)
				text := fmt.tprintf("> %s", backup)
				// Note: tprintf() uses temp buffer, do NOT delete
				render_text_styled(screen, 3, y, text, TUI_PRIMARY, "", true)
			} else {
				// Normal: muted gray text
				text := fmt.tprintf("  %s", backup)
				// Note: tprintf() uses temp buffer, do NOT delete
				render_text_styled(screen, 5, y, text, TUI_MUTED)
			}
		}

		// Scroll indicator (dim gray)
		if len(items) > visible_height {
			scroll_info := fmt.tprintf("Showing %d-%d of %d", start+1, end, len(items))
			// Note: tprintf() uses temp buffer, do NOT delete
			render_text_styled(screen, 3, 5 + visible_height, scroll_info, TUI_DIM)
		}
	}

	// Footer (muted gray)
	footer_y := state.terminal_height - 3
	render_text_styled(screen, 3, footer_y, "c=Cleanup  Esc=Back  ↑/↓ or j/k=Navigate", TUI_MUTED)
}

// ============================================================================
// Plugins View
// ============================================================================

// Render plugins view (placeholder) (PHASE 1: COLORED + BORDERED)
render_plugins_view :: proc(state: ^TUIState, screen: ^Screen) {
	// Draw outer border
	border_width := min(state.terminal_width - 2, 80)
	border_height := state.terminal_height - 2
	render_box_styled(screen, 1, 1, border_width, border_height, TUI_BORDER_NORMAL)

	// Header (hot pink + bold)
	render_text_styled(screen, 3, 2, "🔌 Plugins", TUI_PRIMARY, "", true)
	render_text_styled(screen, 3, 4, "Plugin management system", TUI_MUTED)
	render_text_styled(screen, 3, 6, "(Future feature)", TUI_DIM)

	footer_y := state.terminal_height - 3
	render_text_styled(screen, 3, footer_y, "Esc=Back", TUI_MUTED)
}

// ============================================================================
// Settings View
// ============================================================================

// Render settings view with current configuration (PHASE 1: COLORED + BORDERED)
render_settings_view :: proc(state: ^TUIState, screen: ^Screen) {
	// Draw outer border
	border_width := min(state.terminal_width - 2, 80)
	border_height := state.terminal_height - 2
	render_box_styled(screen, 1, 1, border_width, border_height, TUI_BORDER_NORMAL)

	// Header (hot pink + bold)
	render_text_styled(screen, 3, 2, "⚙️  Settings", TUI_PRIMARY, "", true)
	render_text_styled(screen, 3, 3, "wayu Configuration", TUI_MUTED)

	// Display placeholder settings (actual values set by bridge)
	settings := []string{
		"Shell: (from bridge)",
		"Config Directory: (from bridge)",
		"Backup Retention: 5 (last 5 backups kept)",
		"Dry-run Mode: (from bridge)",
	}

	for setting, i in settings {
		render_text_styled(screen, 5, 5 + i, setting, TUI_MUTED)
	}

	footer_y := state.terminal_height - 3
	render_text_styled(screen, 3, footer_y, "Esc=Back", TUI_MUTED)
}

// ============================================================================
// Helper Functions
// ============================================================================

// Clear cached data for a specific view (call after modifications)
clear_view_cache :: proc(state: ^TUIState, view: TUIView) {
	if state.data_cache[view] != nil {
		// Free the cached data
		items := cast(^[dynamic]string)state.data_cache[view]
		if items != nil {
			for item in items {
				delete(item)
			}
			delete(items^)
			free(items)
		}
		delete_key(&state.data_cache, view)
	}
}

// Get item count for current view (updated version with actual data)
get_view_item_count :: proc(state: ^TUIState) -> int {
	switch state.current_view {
	case .MAIN_MENU:
		return 7  // 7 menu items

	case .PATH_VIEW:
		if state.data_cache[.PATH_VIEW] != nil {
			items := cast(^[dynamic]string)state.data_cache[.PATH_VIEW]
			return len(items)
		}
		return 0

	case .ALIAS_VIEW:
		if state.data_cache[.ALIAS_VIEW] != nil {
			items := cast(^[dynamic]string)state.data_cache[.ALIAS_VIEW]
			return len(items)
		}
		return 0

	case .CONSTANTS_VIEW:
		if state.data_cache[.CONSTANTS_VIEW] != nil {
			items := cast(^[dynamic]string)state.data_cache[.CONSTANTS_VIEW]
			return len(items)
		}
		return 0

	case .BACKUPS_VIEW:
		if state.data_cache[.BACKUPS_VIEW] != nil {
			items := cast(^[dynamic]string)state.data_cache[.BACKUPS_VIEW]
			return len(items)
		}
		return 0

	case .COMPLETIONS_VIEW, .PLUGINS_VIEW, .SETTINGS_VIEW:
		return 0  // No navigation in these views yet
	}
	return 0
}
