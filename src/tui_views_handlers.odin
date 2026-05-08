// tui_views_handlers.odin - Event handlers for TUI views
//
// All five list-style data views (PATH, ALIAS, CONSTANTS, COMPLETIONS, BACKUPS)
// share the same key bindings — a, d/x, /, s, c. Their differences are pure
// data: which keys are supported, the delete-confirmation label, how to extract
// a name from a cache row. So they're driven by a single
// `handle_data_view_event` proc reading per-view config from
// `data_view_behavior`. The plugins view has its own handler because it
// supports tabs and registry installs, which don't fit the generic shape.

package wayu

import "core:fmt"
import "core:strings"

// ============================================================================
// Main Event Router
// ============================================================================

handle_view_event :: proc(state: ^TUIState, key: KeyEvent) {
	#partial switch state.current_view {
	case .PATH_VIEW, .ALIAS_VIEW, .CONSTANTS_VIEW, .COMPLETIONS_VIEW, .BACKUPS_VIEW:
		handle_data_view_event(state, key)
	case .PLUGINS_VIEW:
		handle_plugins_event(state, key)
	case .HOOKS_VIEW, .SETTINGS_VIEW, .MAIN_MENU:
		// Read-only or handled elsewhere — no per-view keys
	}
}

// ============================================================================
// Unified Data-View Event Handler
// ============================================================================

// How to extract the entity name from a cache row when prompting for delete.
NameExtractor :: enum {
	None,           // No delete supported
	Whole,          // Use the entire row as the name (PATH)
	BeforeEquals,   // Substring before '=' (ALIAS, CONSTANT)
}

// Per-view behavior knobs. Computed inline by `data_view_behavior`.
DataViewBehavior :: struct {
	supports_add:           bool,
	supports_source_filter: bool,
	supports_cleanup:       bool,
	delete_label:           string,        // "" for raw display (PATH); "Alias"/"Constant" otherwise
	name_extractor:         NameExtractor,
}

@(private="file")
data_view_behavior :: proc(view: TUIView) -> DataViewBehavior {
	#partial switch view {
	case .PATH_VIEW:
		return DataViewBehavior{
			supports_add           = true,
			supports_source_filter = true,
			name_extractor         = .Whole,
		}
	case .ALIAS_VIEW:
		return DataViewBehavior{
			supports_add           = true,
			supports_source_filter = true,
			delete_label           = "Alias",
			name_extractor         = .BeforeEquals,
		}
	case .CONSTANTS_VIEW:
		return DataViewBehavior{
			supports_add           = true,
			supports_source_filter = true,
			delete_label           = "Constant",
			name_extractor         = .BeforeEquals,
		}
	case .BACKUPS_VIEW:
		return DataViewBehavior{
			supports_cleanup = true,
		}
	case:
		// .COMPLETIONS_VIEW and any other read-only view
		return DataViewBehavior{}
	}
}

handle_data_view_event :: proc(state: ^TUIState, key: KeyEvent) {
	#partial switch key.key {
	case .Char:
		view := state.current_view
		b := data_view_behavior(view)

		switch key.char {
		case 'a':
			if b.supports_add {
				show_add_form(state, view)
			}
		case 'd', 'x':
			if b.name_extractor == .None do return
			if state.data_cache[view] == nil do return
			items := cast(^[dynamic]string)state.data_cache[view]
			if state.selected_index < 0 || state.selected_index >= len(items) do return

			item := items[state.selected_index]
			delete_key, display: string
			switch b.name_extractor {
			case .None:
				return
			case .Whole:
				delete_key = item
				display    = item
			case .BeforeEquals:
				eq_idx := strings.index_byte(item, '=')
				delete_key = item[:eq_idx] if eq_idx >= 0 else item
				display    = fmt.tprintf("%s: %s", b.delete_label, delete_key)
			}
			show_delete_confirmation(state, view, display, delete_key)

		case 'c':
			if !b.supports_cleanup do return
			if tui_cleanup_backups() {
				set_notification(state, .SUCCESS, "Cleaned up old backups")
				clear_view_cache(state, view)
			} else {
				set_notification(state, .ERROR, "Failed to cleanup backups")
			}
			state.needs_refresh = true

		case '/':
			activate_filter(state)
			cache := get_current_cache(state)
			if cache != nil {
				apply_filter(state, cache)
			}
			state.needs_refresh = true

		case 's':
			if !b.supports_source_filter do return
			cache := get_current_cache(state)
			if cache != nil {
				cycle_source_filter(state, cache)
			}
			state.needs_refresh = true
		}
	}
}

// ============================================================================
// Plugins View Event Handler
// ============================================================================

handle_plugins_event :: proc(state: ^TUIState, key: KeyEvent) {
	#partial switch key.key {
	case .Tab:
		// Switch between Installed and Registry tabs; reset cursor + filter
		deactivate_filter(state)
		state.selected_index = 0
		state.scroll_offset  = 0
		state.plugin_tab = 1 - state.plugin_tab  // toggle 0↔1
		state.needs_refresh = true

	case .Enter:
		// Registry tab: install selected plugin
		if state.plugin_tab == PLUGIN_TAB_REGISTRY && state.plugin_registry_cache != nil {
			items := state.plugin_registry_cache
			idx   := state.selected_index
			if len(state.filtered_indices) > 0 {
				if idx >= 0 && idx < len(state.filtered_indices) {
					idx = state.filtered_indices[idx]
				} else {
					return
				}
			}
			if idx < 0 || idx >= len(items^) do return

			// Extract key (first \x00-delimited field)
			item    := items[idx]
			sep_idx := strings.index(item, "\x00")
			plugin_key := item[:sep_idx] if sep_idx >= 0 else item

			// Show "Installing..." before the blocking git clone
			set_notification(state, .SUCCESS,
				fmt.tprintf("Installing %s...", plugin_key))
			state.needs_refresh = true

			ok := tui_install_plugin(plugin_key)
			if ok {
				// Reload installed list and invalidate registry so the
				// installed plugin is filtered out on next registry load
				clear_view_cache(state, .PLUGINS_VIEW)
				clear_registry_cache(state)
				set_notification(state, .SUCCESS,
					fmt.tprintf("Installed %s", plugin_key))
			} else {
				set_notification(state, .ERROR,
					fmt.tprintf("Failed to install %s", plugin_key))
			}
			state.needs_refresh = true
		}

	case .Char:
		switch key.char {
		case '/':
			// Activate inline filter (works on both Installed and Registry tabs)
			activate_filter(state)
			cache := get_current_cache(state)
			if cache != nil {
				apply_filter(state, cache)
			}
			state.needs_refresh = true
		case 't':
			// 't' also switches tabs (fallback for terminals where Tab is intercepted)
			deactivate_filter(state)
			state.selected_index = 0
			state.scroll_offset  = 0
			state.plugin_tab = 1 - state.plugin_tab
			state.needs_refresh = true
		case 'i':
			// 'i' installs selected registry plugin (fallback for terminals where Enter is intercepted)
			if state.plugin_tab == PLUGIN_TAB_REGISTRY && state.plugin_registry_cache != nil {
				items := state.plugin_registry_cache
				idx   := state.selected_index
				if len(state.filtered_indices) > 0 {
					if idx >= 0 && idx < len(state.filtered_indices) {
						idx = state.filtered_indices[idx]
					} else { break }
				}
				if idx < 0 || idx >= len(items^) { break }
				item    := items[idx]
				sep_idx := strings.index(item, "\x00")
				plugin_key := item[:sep_idx] if sep_idx >= 0 else item
				set_notification(state, .SUCCESS, fmt.tprintf("Installing %s...", plugin_key))
				state.needs_refresh = true
				ok := tui_install_plugin(plugin_key)
				if ok {
					clear_view_cache(state, .PLUGINS_VIEW)
					clear_registry_cache(state)
					set_notification(state, .SUCCESS, fmt.tprintf("Installed %s", plugin_key))
				} else {
					set_notification(state, .ERROR, fmt.tprintf("Failed to install %s", plugin_key))
				}
				state.needs_refresh = true
			}
		case 'e':
			// Installed tab: enable selected plugin
			if state.plugin_tab == PLUGIN_TAB_INSTALLED && state.data_cache[.PLUGINS_VIEW] != nil {
				items := cast(^[dynamic]string)state.data_cache[.PLUGINS_VIEW]
				if state.selected_index >= 0 && state.selected_index < len(items) {
					item := items[state.selected_index]
					sep_idx := strings.index(item, " | ")
					plugin_name := item[:sep_idx] if sep_idx >= 0 else item
					if tui_enable_plugin(plugin_name) {
						clear_view_cache(state, .PLUGINS_VIEW)
						state.needs_refresh = true
					}
				}
			}
		case 'd':
			// Installed tab: disable selected plugin
			if state.plugin_tab == PLUGIN_TAB_INSTALLED && state.data_cache[.PLUGINS_VIEW] != nil {
				items := cast(^[dynamic]string)state.data_cache[.PLUGINS_VIEW]
				if state.selected_index >= 0 && state.selected_index < len(items) {
					item := items[state.selected_index]
					sep_idx := strings.index(item, " | ")
					plugin_name := item[:sep_idx] if sep_idx >= 0 else item
					if tui_disable_plugin(plugin_name) {
						clear_view_cache(state, .PLUGINS_VIEW)
						state.needs_refresh = true
					}
				}
			}
		}
	}
}
