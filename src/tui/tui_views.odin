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

// Render PATH configuration view with scrollable list
render_path_view :: proc(state: ^TUIState, screen: ^Screen) {
	// Data should be loaded by bridge layer
	if state.data_cache[.PATH_VIEW] == nil {
		render_text(screen, 2, 1, "📂 PATH Configuration")
		render_text(screen, 2, 3, "Loading...")
		state.needs_refresh = true
		return
	}

	items := cast(^[dynamic]string)state.data_cache[.PATH_VIEW]

	// Header
	render_text(screen, 2, 1, "📂 PATH Configuration")
	count_text := fmt.tprintf("%d entries", len(items))
	// Note: tprintf() uses temp buffer, do NOT delete
	render_text(screen, 2, 2, count_text)

	if len(items) == 0 {
		render_text(screen, 2, 4, "No PATH entries found")
	} else {
		// List items with scrolling
		visible_height := state.terminal_height - 6
		start := state.scroll_offset
		end := min(start + visible_height, len(items))

		for i in start..<end {
			y := 4 + (i - start)
			entry := items[i]

			if i == state.selected_index {
				// Highlight selected
				text := fmt.tprintf("> %s", entry)
				// Note: tprintf() uses temp buffer, do NOT delete
				render_text(screen, 2, y, text)
			} else {
				text := fmt.tprintf("  %s", entry)
				// Note: tprintf() uses temp buffer, do NOT delete
				render_text(screen, 4, y, text)
			}
		}

		// Show scroll indicator if needed
		if len(items) > visible_height {
			scroll_info := fmt.tprintf("Showing %d-%d of %d", start+1, end, len(items))
			// Note: tprintf() uses temp buffer, do NOT delete
			render_text(screen, 2, 4 + visible_height, scroll_info)
		}
	}

	// Footer with shortcuts
	footer_y := state.terminal_height - 2
	render_text(screen, 2, footer_y, "d=Delete  Esc=Back  ↑/↓ or j/k=Navigate")
}

// ============================================================================
// Alias View
// ============================================================================

// Render alias view with name=command format
render_alias_view :: proc(state: ^TUIState, screen: ^Screen) {
	if state.data_cache[.ALIAS_VIEW] == nil {
		render_text(screen, 2, 1, "🔑 Aliases")
		render_text(screen, 2, 3, "Loading...")
		state.needs_refresh = true
		return
	}

	items := cast(^[dynamic]string)state.data_cache[.ALIAS_VIEW]

	// Header
	render_text(screen, 2, 1, "🔑 Aliases")
	count_text := fmt.tprintf("%d aliases", len(items))
	// Note: tprintf() uses temp buffer, do NOT delete
	render_text(screen, 2, 2, count_text)

	if len(items) == 0 {
		render_text(screen, 2, 4, "No aliases found")
	} else {
		// List items with scrolling
		visible_height := state.terminal_height - 6
		start := state.scroll_offset
		end := min(start + visible_height, len(items))

		for i in start..<end {
			y := 4 + (i - start)
			item := items[i]

			if i == state.selected_index {
				text := fmt.tprintf("> %s", item)
				// Note: tprintf() uses temp buffer, do NOT delete
				render_text(screen, 2, y, text)
			} else {
				text := fmt.tprintf("  %s", item)
				// Note: tprintf() uses temp buffer, do NOT delete
				render_text(screen, 4, y, text)
			}
		}

		// Scroll indicator
		if len(items) > visible_height {
			scroll_info := fmt.tprintf("Showing %d-%d of %d", start+1, end, len(items))
			// Note: tprintf() uses temp buffer, do NOT delete
			render_text(screen, 2, 4 + visible_height, scroll_info)
		}
	}

	// Footer
	footer_y := state.terminal_height - 2
	render_text(screen, 2, footer_y, "d=Delete  Esc=Back  ↑/↓ or j/k=Navigate")
}

// ============================================================================
// Constants View
// ============================================================================

// Render constants view with NAME="value" format
render_constants_view :: proc(state: ^TUIState, screen: ^Screen) {
	if state.data_cache[.CONSTANTS_VIEW] == nil {
		render_text(screen, 2, 1, "💾 Environment Constants")
		render_text(screen, 2, 3, "Loading...")
		state.needs_refresh = true
		return
	}

	items := cast(^[dynamic]string)state.data_cache[.CONSTANTS_VIEW]

	// Header
	render_text(screen, 2, 1, "💾 Environment Constants")
	count_text := fmt.tprintf("%d constants", len(items))
	// Note: tprintf() uses temp buffer, do NOT delete
	render_text(screen, 2, 2, count_text)

	if len(items) == 0 {
		render_text(screen, 2, 4, "No constants found")
	} else {
		// List with scrolling
		visible_height := state.terminal_height - 6
		start := state.scroll_offset
		end := min(start + visible_height, len(items))

		for i in start..<end {
			y := 4 + (i - start)
			item := items[i]

			if i == state.selected_index {
				text := fmt.tprintf("> %s", item)
				// Note: tprintf() uses temp buffer, do NOT delete
				render_text(screen, 2, y, text)
			} else {
				text := fmt.tprintf("  %s", item)
				// Note: tprintf() uses temp buffer, do NOT delete
				render_text(screen, 4, y, text)
			}
		}

		// Scroll indicator
		if len(items) > visible_height {
			scroll_info := fmt.tprintf("Showing %d-%d of %d", start+1, end, len(items))
			// Note: tprintf() uses temp buffer, do NOT delete
			render_text(screen, 2, 4 + visible_height, scroll_info)
		}
	}

	// Footer
	footer_y := state.terminal_height - 2
	render_text(screen, 2, footer_y, "d=Delete  Esc=Back  ↑/↓ or j/k=Navigate")
}

// ============================================================================
// Completions View
// ============================================================================

// Render completions view (placeholder - basic list)
render_completions_view :: proc(state: ^TUIState, screen: ^Screen) {
	// Header
	render_text(screen, 2, 1, "🎯 Completions")
	render_text(screen, 2, 3, "Completion scripts management")
	render_text(screen, 2, 5, "(Feature coming in Phase 7)")

	// Footer
	footer_y := state.terminal_height - 2
	render_text(screen, 2, footer_y, "Esc=Back")
}

// ============================================================================
// Backups View
// ============================================================================

// Render backups view with timestamps and config types
render_backups_view :: proc(state: ^TUIState, screen: ^Screen) {
	if state.data_cache[.BACKUPS_VIEW] == nil {
		render_text(screen, 2, 1, "💾 Backups")
		render_text(screen, 2, 3, "Loading...")
		state.needs_refresh = true
		return
	}

	items := cast(^[dynamic]string)state.data_cache[.BACKUPS_VIEW]

	// Header
	render_text(screen, 2, 1, "💾 Backups")
	count_text := fmt.tprintf("%d backups available", len(items))
	// Note: tprintf() uses temp buffer, do NOT delete
	render_text(screen, 2, 2, count_text)

	if len(items) == 0 {
		render_text(screen, 2, 4, "No backups found")
	} else {
		// List backups
		visible_height := state.terminal_height - 6
		start := state.scroll_offset
		end := min(start + visible_height, len(items))

		for i in start..<end {
			y := 4 + (i - start)
			backup := items[i]

			if i == state.selected_index {
				text := fmt.tprintf("> %s", backup)
				// Note: tprintf() uses temp buffer, do NOT delete
				render_text(screen, 2, y, text)
			} else {
				text := fmt.tprintf("  %s", backup)
				// Note: tprintf() uses temp buffer, do NOT delete
				render_text(screen, 4, y, text)
			}
		}

		// Scroll indicator
		if len(items) > visible_height {
			scroll_info := fmt.tprintf("Showing %d-%d of %d", start+1, end, len(items))
			// Note: tprintf() uses temp buffer, do NOT delete
			render_text(screen, 2, 4 + visible_height, scroll_info)
		}
	}

	// Footer
	footer_y := state.terminal_height - 2
	render_text(screen, 2, footer_y, "c=Cleanup  Esc=Back  ↑/↓ or j/k=Navigate")
}

// ============================================================================
// Plugins View
// ============================================================================

// Render plugins view (placeholder)
render_plugins_view :: proc(state: ^TUIState, screen: ^Screen) {
	render_text(screen, 2, 1, "🔌 Plugins")
	render_text(screen, 2, 3, "Plugin management system")
	render_text(screen, 2, 5, "(Future feature)")

	footer_y := state.terminal_height - 2
	render_text(screen, 2, footer_y, "Esc=Back")
}

// ============================================================================
// Settings View
// ============================================================================

// Render settings view with current configuration
render_settings_view :: proc(state: ^TUIState, screen: ^Screen) {
	render_text(screen, 2, 1, "⚙️  Settings")
	render_text(screen, 2, 2, "wayu Configuration")

	// Display placeholder settings (actual values set by bridge)
	settings := []string{
		"Shell: (from bridge)",
		"Config Directory: (from bridge)",
		"Backup Retention: 5 (last 5 backups kept)",
		"Dry-run Mode: (from bridge)",
	}

	for setting, i in settings {
		render_text(screen, 4, 4 + i, setting)
	}

	footer_y := state.terminal_height - 2
	render_text(screen, 2, footer_y, "Esc=Back")
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
