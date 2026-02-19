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
			// Stage delete confirmation for selected PATH entry
			if state.data_cache[.PATH_VIEW] != nil {
				items := cast(^[dynamic]string)state.data_cache[.PATH_VIEW]
				if state.selected_index >= 0 && state.selected_index < len(items) {
					entry := items[state.selected_index]
					show_delete_confirmation(state, .PATH_VIEW, entry, entry)
				}
			}
		case '/':
			// Activate inline filter
			activate_filter(state)
			cache := get_current_cache(state)
			if cache != nil {
				apply_filter(state, cache)
			}
			state.needs_refresh = true
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
			// Stage delete confirmation for selected alias
			if state.data_cache[.ALIAS_VIEW] != nil {
				items := cast(^[dynamic]string)state.data_cache[.ALIAS_VIEW]
				if state.selected_index >= 0 && state.selected_index < len(items) {
					item := items[state.selected_index]
					// Extract name before '=' — zero allocation, slice of cache string
					eq_idx := strings.index_byte(item, '=')
					alias_name := item[:eq_idx] if eq_idx >= 0 else item
					display := fmt.tprintf("Alias: %s", alias_name)
					show_delete_confirmation(state, .ALIAS_VIEW, display, alias_name)
				}
			}
		case '/':
			// Activate inline filter
			activate_filter(state)
			cache := get_current_cache(state)
			if cache != nil {
				apply_filter(state, cache)
			}
			state.needs_refresh = true
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
			// Stage delete confirmation for selected constant
			if state.data_cache[.CONSTANTS_VIEW] != nil {
				items := cast(^[dynamic]string)state.data_cache[.CONSTANTS_VIEW]
				if state.selected_index >= 0 && state.selected_index < len(items) {
					item := items[state.selected_index]
					// Extract name before '=' — zero allocation, slice of cache string
					eq_idx := strings.index_byte(item, '=')
					constant_name := item[:eq_idx] if eq_idx >= 0 else item
					display := fmt.tprintf("Constant: %s", constant_name)
					show_delete_confirmation(state, .CONSTANTS_VIEW, display, constant_name)
				}
			}
		case '/':
			// Activate inline filter
			activate_filter(state)
			cache := get_current_cache(state)
			if cache != nil {
				apply_filter(state, cache)
			}
			state.needs_refresh = true
		}
	}
}

// ============================================================================
// Completions View Event Handler
// ============================================================================

handle_completions_event :: proc(state: ^TUIState, key: KeyEvent) {
	#partial switch key.key {
	case .Char:
		switch key.char {
		case '/':
			// Activate inline filter
			activate_filter(state)
			cache := get_current_cache(state)
			if cache != nil {
				apply_filter(state, cache)
			}
			state.needs_refresh = true
		}
	}
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
			success := tui_cleanup_backups()

			if success {
				set_notification(state, .SUCCESS, "Cleaned up old backups")
				// Clear cache to reload
				clear_view_cache(state, .BACKUPS_VIEW)
			} else {
				set_notification(state, .ERROR, "Failed to cleanup backups")
			}

			state.needs_refresh = true
		case '/':
			// Activate inline filter
			activate_filter(state)
			cache := get_current_cache(state)
			if cache != nil {
				apply_filter(state, cache)
			}
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
