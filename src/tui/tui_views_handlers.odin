// tui_views_handlers.odin - Event handlers for TUI views
//
// This module implements event handling for all 8 views, including:
// - Navigation (j/k, up/down, Enter, Esc)
// - CRUD operations (add, delete, edit)
// - View-specific actions (clean, restore, cleanup)
//
// Note: This module does NOT import the main wayu package to avoid circular dependencies.
// Delete operations set a flag that the bridge layer in main.odin will handle.

package wayu_tui

import "core:fmt"
import "core:strings"

// ============================================================================
// Main Event Router
// ============================================================================

// Handle view-specific key events (called from tui_main.odin)
handle_view_event :: proc(state: ^TUIState, key: KeyEvent) {
	switch state.current_view {
	case .PATH_VIEW:
		handle_path_event(state, key)

	case .ALIAS_VIEW:
		handle_alias_event(state, key)

	case .CONSTANTS_VIEW:
		handle_constants_event(state, key)

	case .COMPLETIONS_VIEW:
		handle_completions_event(state, key)

	case .BACKUPS_VIEW:
		handle_backups_event(state, key)

	case .PLUGINS_VIEW:
		handle_plugins_event(state, key)

	case .SETTINGS_VIEW:
		handle_settings_event(state, key)

	case .MAIN_MENU:
		// Main menu handled in tui_main.odin
	}
}

// ============================================================================
// PATH View Event Handler
// ============================================================================

handle_path_event :: proc(state: ^TUIState, key: KeyEvent) {
	#partial switch key.key {
	case .Char:
		switch key.char {
		case 'd', 'x':
			// Delete selected PATH entry
			if state.data_cache[.PATH_VIEW] != nil {
				items := cast(^[dynamic]string)state.data_cache[.PATH_VIEW]
				if state.selected_index >= 0 && state.selected_index < len(items) {
					selected_entry := items[state.selected_index]
					item_count := len(items)  // Save count BEFORE clearing cache

					// Call bridge function to delete (creates backup automatically)
					tui_delete_path(selected_entry)

					// Clear cache to force reload
					clear_view_cache(state, .PATH_VIEW)

					// Reset selection if needed (use saved count, not freed items)
					if state.selected_index >= item_count - 1 {
						state.selected_index = max(0, item_count - 2)
					}
					state.scroll_offset = 0

					state.needs_refresh = true
				}
			}
		}
	}
}

// ============================================================================
// Alias View Event Handler
// ============================================================================

handle_alias_event :: proc(state: ^TUIState, key: KeyEvent) {
	#partial switch key.key {
	case .Char:
		switch key.char {
		case 'd', 'x':
			// Delete selected alias
			if state.data_cache[.ALIAS_VIEW] != nil {
				items := cast(^[dynamic]string)state.data_cache[.ALIAS_VIEW]
				if state.selected_index >= 0 && state.selected_index < len(items) {
					selected_item := items[state.selected_index]
					item_count := len(items)  // Save count BEFORE clearing cache

					// Parse name from "name=value" format
					parts := strings.split(selected_item, "=")
					defer delete(parts)

					if len(parts) >= 1 {
						alias_name := parts[0]

						// Call bridge function to delete (creates backup automatically)
						tui_delete_alias(alias_name)

						// Clear cache to force reload
						clear_view_cache(state, .ALIAS_VIEW)

						// Reset selection if needed (use saved count, not freed items)
						if state.selected_index >= item_count - 1 {
							state.selected_index = max(0, item_count - 2)
						}
						state.scroll_offset = 0

						state.needs_refresh = true
					}
				}
			}
		}
	}
}

// ============================================================================
// Constants View Event Handler
// ============================================================================

handle_constants_event :: proc(state: ^TUIState, key: KeyEvent) {
	#partial switch key.key {
	case .Char:
		switch key.char {
		case 'd', 'x':
			// Delete selected constant
			if state.data_cache[.CONSTANTS_VIEW] != nil {
				items := cast(^[dynamic]string)state.data_cache[.CONSTANTS_VIEW]
				if state.selected_index >= 0 && state.selected_index < len(items) {
					selected_item := items[state.selected_index]
					item_count := len(items)  // Save count BEFORE clearing cache

					// Parse name from "NAME=value" format
					parts := strings.split(selected_item, "=")
					defer delete(parts)

					if len(parts) >= 1 {
						constant_name := parts[0]

						// Call bridge function to delete (creates backup automatically)
						tui_delete_constant(constant_name)

						// Clear cache to force reload
						clear_view_cache(state, .CONSTANTS_VIEW)

						// Reset selection if needed (use saved count, not freed items)
						if state.selected_index >= item_count - 1 {
							state.selected_index = max(0, item_count - 2)
						}
						state.scroll_offset = 0

						state.needs_refresh = true
					}
				}
			}
		}
	}
}

// ============================================================================
// Completions View Event Handler
// ============================================================================

handle_completions_event :: proc(state: ^TUIState, key: KeyEvent) {
	// Placeholder - no actions yet
	// Will be implemented in Phase 7
}

// ============================================================================
// Backups View Event Handler
// ============================================================================

handle_backups_event :: proc(state: ^TUIState, key: KeyEvent) {
	#partial switch key.key {
	case .Char:
		switch key.char {
		case 'c':
			// Cleanup old backups
			tui_cleanup_backups()

			// Clear cache to reload
			clear_view_cache(state, .BACKUPS_VIEW)

			state.needs_refresh = true
		}
	}
}

// ============================================================================
// Plugins View Event Handler
// ============================================================================

handle_plugins_event :: proc(state: ^TUIState, key: KeyEvent) {
	// Placeholder - no actions yet
	// Future feature
}

// ============================================================================
// Settings View Event Handler
// ============================================================================

handle_settings_event :: proc(state: ^TUIState, key: KeyEvent) {
	// Settings view is read-only for now
	// Future: Add toggle options
}
