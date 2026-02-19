// tui_bridge.odin - Data bridge between TUI and wayu config functions
//
// This module defines the bridge function signatures that must be implemented
// by the main wayu package. This avoids circular dependencies by using function
// pointers that are set at runtime.

package wayu_tui

import "core:fmt"
import "core:os"
import "core:strings"

// Bridge function pointers - set by main.odin before launching TUI
g_load_path_data: proc(^TUIState)
g_load_alias_data: proc(^TUIState)
g_load_constants_data: proc(^TUIState)
g_load_completions_data: proc(^TUIState)
g_load_backups_data: proc(^TUIState)
g_delete_path: proc(string) -> bool
g_delete_alias: proc(string) -> bool
g_delete_constant: proc(string) -> bool
g_cleanup_backups: proc() -> bool
g_get_path_detail: proc(string) -> [dynamic]string
g_get_last_error: proc() -> string

// Set bridge functions (called from main.odin before tui_run)
tui_set_bridge_functions :: proc(
	load_path: proc(^TUIState),
	load_alias: proc(^TUIState),
	load_constants: proc(^TUIState),
	load_completions: proc(^TUIState),
	load_backups: proc(^TUIState),
	delete_path: proc(string) -> bool,
	delete_alias: proc(string) -> bool,
	delete_constant: proc(string) -> bool,
	cleanup_backups: proc() -> bool,
	get_path_detail: proc(string) -> [dynamic]string,
) {
	g_load_path_data = load_path
	g_load_alias_data = load_alias
	g_load_constants_data = load_constants
	g_load_completions_data = load_completions
	g_load_backups_data = load_backups
	g_delete_path = delete_path
	g_delete_alias = delete_alias
	g_delete_constant = delete_constant
	g_cleanup_backups = cleanup_backups
	g_get_path_detail = get_path_detail
}

// Bridge functions to load data into TUI state cache
// These are called when entering a view or after modifications

// Wrapper functions that call through the global function pointers

// Load PATH entries into cache
tui_load_path_data :: proc(state: ^TUIState) {
	if g_load_path_data != nil {
		g_load_path_data(state)
	}
}

// Load Alias entries into cache
tui_load_alias_data :: proc(state: ^TUIState) {
	if g_load_alias_data != nil {
		g_load_alias_data(state)
	}
}

// Load Constants entries into cache
tui_load_constants_data :: proc(state: ^TUIState) {
	if g_load_constants_data != nil {
		g_load_constants_data(state)
	}
}

// Load Completions into cache
tui_load_completions_data :: proc(state: ^TUIState) {
	if g_load_completions_data != nil {
		g_load_completions_data(state)
	}
}

// Load Backups into cache
tui_load_backups_data :: proc(state: ^TUIState) {
	if g_load_backups_data != nil {
		g_load_backups_data(state)
	}
}

// Delete PATH entry
tui_delete_path :: proc(name: string) -> bool {
	if g_delete_path != nil {
		return g_delete_path(name)
	}
	return false
}

// Delete Alias entry
tui_delete_alias :: proc(name: string) -> bool {
	if g_delete_alias != nil {
		return g_delete_alias(name)
	}
	return false
}

// Delete Constants entry
tui_delete_constant :: proc(name: string) -> bool {
	if g_delete_constant != nil {
		return g_delete_constant(name)
	}
	return false
}

// Cleanup old backups
tui_cleanup_backups :: proc() -> bool {
	if g_cleanup_backups != nil {
		return g_cleanup_backups()
	}
	return false
}

// Get PATH entry detail information
tui_get_path_detail :: proc(path: string) -> [dynamic]string {
	if g_get_path_detail != nil {
		return g_get_path_detail(path)
	}
	// Fallback: return empty
	result := make([dynamic]string)
	return result
}

// Auto-load data when entering a view
tui_ensure_data_loaded :: proc(state: ^TUIState, view: TUIView) {
	// Check if data is already loaded
	if state.data_cache[view] != nil {
		return
	}

	// Load data based on view
	switch view {
	case .PATH_VIEW:
		tui_load_path_data(state)
	case .ALIAS_VIEW:
		tui_load_alias_data(state)
	case .CONSTANTS_VIEW:
		tui_load_constants_data(state)
	case .COMPLETIONS_VIEW:
		tui_load_completions_data(state)
	case .BACKUPS_VIEW:
		tui_load_backups_data(state)
	case .MAIN_MENU, .PLUGINS_VIEW, .SETTINGS_VIEW:
		// No data to load for these views
	}
}
