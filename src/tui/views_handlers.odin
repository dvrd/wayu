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
					// Clone before bridge call — clear_view_cache frees the original
					selected_entry := strings.clone(items[state.selected_index])
					defer delete(selected_entry)
					item_count := len(items)  // Save count BEFORE clearing cache

					// Call bridge function to delete (creates backup automatically)
					success := tui_delete_path(selected_entry)

					if success {
						msg := fmt.tprintf("Removed PATH entry: %s", selected_entry)
						set_notification(state, .SUCCESS, msg)

						// Clear cache to force reload
						clear_view_cache(state, .PATH_VIEW)

						// Preserve cursor position: only adjust if was on last item
						if state.selected_index >= item_count - 1 {
							state.selected_index = max(0, item_count - 2)
						}
						// Adjust scroll_offset if selected_index is now above visible window
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
							msg := fmt.tprintf("Failed to remove PATH entry: %s", selected_entry)
							set_notification(state, .ERROR, msg)
						}
					}

					state.needs_refresh = true
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
			// Delete selected alias
			if state.data_cache[.ALIAS_VIEW] != nil {
				items := cast(^[dynamic]string)state.data_cache[.ALIAS_VIEW]
				if state.selected_index >= 0 && state.selected_index < len(items) {
					// Clone before bridge call — clear_view_cache frees the original
					selected_item := strings.clone(items[state.selected_index])
					defer delete(selected_item)
					item_count := len(items)  // Save count BEFORE clearing cache

					// Parse name from "name=value" format
					parts := strings.split(selected_item, "=")
					defer delete(parts)

					if len(parts) >= 1 {
						alias_name := parts[0]

						// Call bridge function to delete (creates backup automatically)
						success := tui_delete_alias(alias_name)

						if success {
							msg := fmt.tprintf("Removed alias: %s", alias_name)
							set_notification(state, .SUCCESS, msg)

							// Clear cache to force reload
							clear_view_cache(state, .ALIAS_VIEW)

							// Preserve cursor position: only adjust if was on last item
							if state.selected_index >= item_count - 1 {
								state.selected_index = max(0, item_count - 2)
							}
							// Adjust scroll_offset if selected_index is now above visible window
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
								msg := fmt.tprintf("Failed to remove alias: %s", alias_name)
								set_notification(state, .ERROR, msg)
							}
						}

						state.needs_refresh = true
					}
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
			// Delete selected constant
			if state.data_cache[.CONSTANTS_VIEW] != nil {
				items := cast(^[dynamic]string)state.data_cache[.CONSTANTS_VIEW]
				if state.selected_index >= 0 && state.selected_index < len(items) {
					// Clone before bridge call — clear_view_cache frees the original
					selected_item := strings.clone(items[state.selected_index])
					defer delete(selected_item)
					item_count := len(items)  // Save count BEFORE clearing cache

					// Parse name from "NAME=value" format
					parts := strings.split(selected_item, "=")
					defer delete(parts)

					if len(parts) >= 1 {
						constant_name := parts[0]

						// Call bridge function to delete (creates backup automatically)
						success := tui_delete_constant(constant_name)

						if success {
							msg := fmt.tprintf("Removed constant: %s", constant_name)
							set_notification(state, .SUCCESS, msg)

							// Clear cache to force reload
							clear_view_cache(state, .CONSTANTS_VIEW)

							// Preserve cursor position: only adjust if was on last item
							if state.selected_index >= item_count - 1 {
								state.selected_index = max(0, item_count - 2)
							}
							// Adjust scroll_offset if selected_index is now above visible window
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
								msg := fmt.tprintf("Failed to remove constant: %s", constant_name)
								set_notification(state, .ERROR, msg)
							}
						}

						state.needs_refresh = true
					}
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
