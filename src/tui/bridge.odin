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
g_load_plugins_data: proc(^TUIState)
g_load_settings_data: proc(^TUIState)
g_delete_path: proc(string) -> (bool, string)
g_delete_alias: proc(string) -> (bool, string)
g_delete_constant: proc(string) -> (bool, string)
g_cleanup_backups: proc() -> bool
g_get_path_detail: proc(string) -> [dynamic]string
g_add_path:       proc(string) -> (bool, string)
g_add_alias:      proc(string, string) -> (bool, string)
g_add_constant:   proc(string, string) -> (bool, string)
g_enable_plugin:  proc(string) -> bool
g_disable_plugin: proc(string) -> bool
g_load_registry:  proc(^TUIState)        // populate state.plugin_registry_cache
g_install_plugin: proc(string) -> bool   // install by registry key

// Set bridge functions (called from main.odin before tui_run)
tui_set_bridge_functions :: proc(
	load_path: proc(^TUIState),
	load_alias: proc(^TUIState),
	load_constants: proc(^TUIState),
	load_completions: proc(^TUIState),
	load_backups: proc(^TUIState),
	delete_path: proc(string) -> (bool, string),
	delete_alias: proc(string) -> (bool, string),
	delete_constant: proc(string) -> (bool, string),
	cleanup_backups: proc() -> bool,
	get_path_detail: proc(string) -> [dynamic]string,
	add_path: proc(string) -> (bool, string),
	add_alias: proc(string, string) -> (bool, string),
	add_constant: proc(string, string) -> (bool, string),
	load_plugins: proc(^TUIState) = nil,
	enable_plugin: proc(string) -> bool = nil,
	disable_plugin: proc(string) -> bool = nil,
	load_registry: proc(^TUIState) = nil,
	install_plugin: proc(string) -> bool = nil,
	load_settings: proc(^TUIState) = nil,
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
	g_add_path = add_path
	g_add_alias = add_alias
	g_add_constant = add_constant
	g_load_plugins_data = load_plugins
	g_enable_plugin = enable_plugin
	g_disable_plugin = disable_plugin
	g_load_registry = load_registry
	g_install_plugin = install_plugin
	g_load_settings_data = load_settings
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

// Load Plugins into cache
tui_load_plugins_data :: proc(state: ^TUIState) {
	if g_load_plugins_data != nil {
		g_load_plugins_data(state)
	}
}

// Load Settings into state
tui_load_settings_data :: proc(state: ^TUIState) {
	if g_load_settings_data != nil {
		g_load_settings_data(state)
	}
}

// Delete PATH entry
tui_delete_path :: proc(name: string) -> (bool, string) {
	if g_delete_path != nil {
		return g_delete_path(name)
	}
	return false, ""
}

// Delete Alias entry
tui_delete_alias :: proc(name: string) -> (bool, string) {
	if g_delete_alias != nil {
		return g_delete_alias(name)
	}
	return false, ""
}

// Delete Constants entry
tui_delete_constant :: proc(name: string) -> (bool, string) {
	if g_delete_constant != nil {
		return g_delete_constant(name)
	}
	return false, ""
}

// Cleanup old backups
tui_cleanup_backups :: proc() -> bool {
	if g_cleanup_backups != nil {
		return g_cleanup_backups()
	}
	return false
}

// Add PATH entry
tui_add_path :: proc(path: string) -> (bool, string) {
	if g_add_path != nil {
		return g_add_path(path)
	}
	return false, ""
}

// Add Alias entry
tui_add_alias :: proc(name: string, command: string) -> (bool, string) {
	if g_add_alias != nil {
		return g_add_alias(name, command)
	}
	return false, ""
}

// Add Constants entry
tui_add_constant :: proc(name: string, value: string) -> (bool, string) {
	if g_add_constant != nil {
		return g_add_constant(name, value)
	}
	return false, ""
}

// Enable plugin by name
tui_enable_plugin :: proc(name: string) -> bool {
	if g_enable_plugin != nil {
		return g_enable_plugin(name)
	}
	return false
}

// Disable plugin by name
tui_disable_plugin :: proc(name: string) -> bool {
	if g_disable_plugin != nil {
		return g_disable_plugin(name)
	}
	return false
}

// Load plugin registry into state.plugin_registry_cache
tui_load_registry :: proc(state: ^TUIState) {
	if g_load_registry != nil {
		g_load_registry(state)
	}
}

// Install plugin by registry key
tui_install_plugin :: proc(key: string) -> bool {
	if g_install_plugin != nil {
		return g_install_plugin(key)
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
	// Load data based on view (each loader is idempotent — skips if already loaded)
	switch view {
	case .PATH_VIEW:
		if state.data_cache[view] == nil do tui_load_path_data(state)
	case .ALIAS_VIEW:
		if state.data_cache[view] == nil do tui_load_alias_data(state)
	case .CONSTANTS_VIEW:
		if state.data_cache[view] == nil do tui_load_constants_data(state)
	case .COMPLETIONS_VIEW:
		if state.data_cache[view] == nil do tui_load_completions_data(state)
	case .BACKUPS_VIEW:
		if state.data_cache[view] == nil do tui_load_backups_data(state)
	case .PLUGINS_VIEW:
		// Installed plugins and registry are independent caches — load each if missing
		if state.data_cache[view] == nil do tui_load_plugins_data(state)
		tui_load_registry(state)  // idempotent: skips if plugin_registry_cache != nil
	case .MAIN_MENU, .HOOKS_VIEW, .SETTINGS_VIEW:
		// No data to load for these views
	}
}
