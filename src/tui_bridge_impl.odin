// tui_bridge_impl.odin - Implementation of TUI bridge functions in main package
//
// This module implements the bridge functions that connect the TUI with wayu's
// config management system. These functions are passed to the TUI at runtime
// to avoid circular dependencies.

package wayu

import "core:fmt"
import "core:os"
import "core:strings"
import tui "tui"

// Load PATH entries into TUI cache
tui_bridge_load_path :: proc(state: ^tui.TUIState) {
	// Clear existing cache
	if state.data_cache[.PATH_VIEW] != nil {
		tui.clear_view_cache(state, .PATH_VIEW)
	}

	// Read entries using PATH_SPEC
	entries := read_config_entries(&PATH_SPEC)
	defer cleanup_entries(&entries)

	// Convert to strings
	items := make([dynamic]string)
	for entry in entries {
		item := strings.clone(entry.name)
		append(&items, item)
	}

	// Store in cache
	items_ptr := new([dynamic]string)
	items_ptr^ = items
	state.data_cache[.PATH_VIEW] = items_ptr
}

// Load Alias entries into TUI cache
tui_bridge_load_alias :: proc(state: ^tui.TUIState) {
	// Clear existing cache
	if state.data_cache[.ALIAS_VIEW] != nil {
		tui.clear_view_cache(state, .ALIAS_VIEW)
	}

	// Read entries using ALIAS_SPEC
	entries := read_config_entries(&ALIAS_SPEC)
	defer cleanup_entries(&entries)

	// Convert to "name=value" format
	items := make([dynamic]string)
	for entry in entries {
		item := fmt.aprintf("%s=%s", entry.name, entry.value)
		append(&items, item)
	}

	// Store in cache
	items_ptr := new([dynamic]string)
	items_ptr^ = items
	state.data_cache[.ALIAS_VIEW] = items_ptr
}

// Load Constants entries into TUI cache
tui_bridge_load_constants :: proc(state: ^tui.TUIState) {
	// Clear existing cache
	if state.data_cache[.CONSTANTS_VIEW] != nil {
		tui.clear_view_cache(state, .CONSTANTS_VIEW)
	}

	// Read entries using CONSTANTS_SPEC
	entries := read_config_entries(&CONSTANTS_SPEC)
	defer cleanup_entries(&entries)

	// Convert to "NAME=value" format
	items := make([dynamic]string)
	for entry in entries {
		item := fmt.aprintf("%s=%s", entry.name, entry.value)
		append(&items, item)
	}

	// Store in cache
	items_ptr := new([dynamic]string)
	items_ptr^ = items
	state.data_cache[.CONSTANTS_VIEW] = items_ptr
}

// Load Completions into TUI cache
tui_bridge_load_completions :: proc(state: ^tui.TUIState) {
	// Clear existing cache
	if state.data_cache[.COMPLETIONS_VIEW] != nil {
		tui.clear_view_cache(state, .COMPLETIONS_VIEW)
	}

	// Build completions directory path
	completions_dir := fmt.aprintf("%s/completions", WAYU_CONFIG)
	defer delete(completions_dir)

	// Create items array
	items := make([dynamic]string)

	// Check if directory exists
	if !os.exists(completions_dir) {
		// No completions directory - return empty list
		items_ptr := new([dynamic]string)
		items_ptr^ = items
		state.data_cache[.COMPLETIONS_VIEW] = items_ptr
		return
	}

	// Read directory contents
	dir_handle, err := os.open(completions_dir)
	if err != 0 {
		// Can't open directory - return empty list
		items_ptr := new([dynamic]string)
		items_ptr^ = items
		state.data_cache[.COMPLETIONS_VIEW] = items_ptr
		return
	}
	defer os.close(dir_handle)

	file_infos, read_err := os.read_dir(dir_handle, -1)
	if read_err != 0 {
		// Can't read directory - return empty list
		items_ptr := new([dynamic]string)
		items_ptr^ = items
		state.data_cache[.COMPLETIONS_VIEW] = items_ptr
		return
	}
	defer os.file_info_slice_delete(file_infos)

	// Filter completion files (start with '_', not backup files)
	for info in file_infos {
		if strings.has_prefix(info.name, "_") && !info.is_dir {
			// Skip backup files
			if strings.contains(info.name, ".backup.") {
				continue
			}
			item := strings.clone(info.name)
			append(&items, item)
		}
	}

	// Store in cache
	items_ptr := new([dynamic]string)
	items_ptr^ = items
	state.data_cache[.COMPLETIONS_VIEW] = items_ptr
}

// Load Backups into TUI cache
tui_bridge_load_backups :: proc(state: ^tui.TUIState) {
	// Clear existing cache
	if state.data_cache[.BACKUPS_VIEW] != nil {
		tui.clear_view_cache(state, .BACKUPS_VIEW)
	}

	// Get all backup files
	items := make([dynamic]string)

	// List all backups from the backups directory
	backups_dir := fmt.aprintf("%s/.backups", WAYU_CONFIG)
	defer delete(backups_dir)

	if !os.exists(backups_dir) {
		// No backups directory - empty list
		items_ptr := new([dynamic]string)
		items_ptr^ = items
		state.data_cache[.BACKUPS_VIEW] = items_ptr
		return
	}

	// Read directory contents
	dir_handle, err := os.open(backups_dir)
	if err != nil {
		// Can't open directory - empty list
		items_ptr := new([dynamic]string)
		items_ptr^ = items
		state.data_cache[.BACKUPS_VIEW] = items_ptr
		return
	}
	defer os.close(dir_handle)

	infos, read_err := os.read_dir(dir_handle, -1)
	if read_err != nil {
		// Can't read directory - empty list
		items_ptr := new([dynamic]string)
		items_ptr^ = items
		state.data_cache[.BACKUPS_VIEW] = items_ptr
		return
	}
	defer delete(infos)

	// Filter and format backup files
	for info in infos {
		if info.is_dir { continue }

		// Format: path.zsh.backup.2024-03-15_14-30-00
		name := info.name
		if strings.contains(name, ".backup.") {
			item := strings.clone(name)
			append(&items, item)
		}
	}

	// Store in cache
	items_ptr := new([dynamic]string)
	items_ptr^ = items
	state.data_cache[.BACKUPS_VIEW] = items_ptr
}

// Delete PATH entry
tui_bridge_delete_path :: proc(name: string) -> bool {
	// Disable dry-run for TUI operations
	old_dry_run := DRY_RUN
	DRY_RUN = false
	defer { DRY_RUN = old_dry_run }

	// Call wayu's remove function (it creates backup automatically)
	remove_config_entry(&PATH_SPEC, name)
	return true
}

// Delete Alias entry
tui_bridge_delete_alias :: proc(name: string) -> bool {
	// Disable dry-run for TUI operations
	old_dry_run := DRY_RUN
	DRY_RUN = false
	defer { DRY_RUN = old_dry_run }

	// Call wayu's remove function (it creates backup automatically)
	remove_config_entry(&ALIAS_SPEC, name)
	return true
}

// Delete Constants entry
tui_bridge_delete_constant :: proc(name: string) -> bool {
	// Disable dry-run for TUI operations
	old_dry_run := DRY_RUN
	DRY_RUN = false
	defer { DRY_RUN = old_dry_run }

	// Call wayu's remove function (it creates backup automatically)
	remove_config_entry(&CONSTANTS_SPEC, name)
	return true
}

// Cleanup old backups
tui_bridge_cleanup_backups :: proc() -> bool {
	// Get config files
	config_files := []string{
		fmt.aprintf("%s/path.%s", WAYU_CONFIG, SHELL_EXT),
		fmt.aprintf("%s/aliases.%s", WAYU_CONFIG, SHELL_EXT),
		fmt.aprintf("%s/constants.%s", WAYU_CONFIG, SHELL_EXT),
	}
	defer for file in config_files do delete(file)

	// Cleanup old backups for each file
	for file in config_files {
		if os.exists(file) {
			cleanup_old_backups(file, 5)  // Keep last 5 backups
		}
	}

	return true
}
