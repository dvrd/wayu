package wayu_tui

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"

// ============================================================================
// Helper Functions
// ============================================================================

// Free and nil out the registry cache so it reloads on next entry.
// Call after a successful install so the installed plugin is filtered out.
clear_registry_cache :: proc(state: ^TUIState) {
	if state.plugin_registry_cache == nil { return }
	for item in state.plugin_registry_cache^ {
		delete(item)
	}
	delete(state.plugin_registry_cache^)
	free(state.plugin_registry_cache)
	state.plugin_registry_cache = nil
}

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
		delete_key(state.data_cache, view)
	}
}

// Get item count for current view (updated version with actual data)
get_view_item_count :: proc(state: ^TUIState) -> int {
	// When filter has results, use filtered count
	if len(state.filtered_indices) > 0 {
		return len(state.filtered_indices)
	}

	switch state.current_view {
	case .MAIN_MENU:
		return 8  // PATH, Aliases, Constants, Completions, Backups, Plugins, Hooks, Settings

	case .PATH_VIEW:
		if state.data_cache[.PATH_VIEW] != nil {
			items := cast(^[dynamic]string)state.data_cache[.PATH_VIEW]
			return len(items)
		}
		return 10  // placeholder count when cache not yet loaded

	case .ALIAS_VIEW:
		if state.data_cache[.ALIAS_VIEW] != nil {
			items := cast(^[dynamic]string)state.data_cache[.ALIAS_VIEW]
			return len(items)
		}
		return 8  // placeholder count when cache not yet loaded

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

	case .COMPLETIONS_VIEW:
		if state.data_cache[.COMPLETIONS_VIEW] != nil {
			items := cast(^[dynamic]string)state.data_cache[.COMPLETIONS_VIEW]
			return len(items)
		}
		return 0

	case .PLUGINS_VIEW:
		if state.plugin_tab == PLUGIN_TAB_REGISTRY {
			if state.plugin_registry_cache != nil {
				return len(state.plugin_registry_cache^)
			}
			return 0
		}
		if state.data_cache[.PLUGINS_VIEW] != nil {
			items := cast(^[dynamic]string)state.data_cache[.PLUGINS_VIEW]
			return len(items)
		}
		return 0

	case .HOOKS_VIEW:
		return 0  // Read-only view

	case .SETTINGS_VIEW:
		return 0  // Read-only view
	}
	return 0
}

