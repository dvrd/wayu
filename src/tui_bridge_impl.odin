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

	items := make([dynamic]string)

	// Check if wayu.toml exists and read from it preferentially
	toml_file := fmt.aprintf("%s/%s", WAYU_CONFIG, WAYU_TOML)
	defer delete(toml_file)

	if os.exists(toml_file) {
		config, ok := toml_read_file(toml_file)
		defer {
			// Clean up config memory
			for entry in config.path.entries { delete(entry) }
			delete(config.path.entries)
		}
		if ok {
			for entry in config.path.entries {
				item := strings.clone(entry)
				append(&items, item)
			}
		}
	} else {
		// Fall back to shell config entries
		entries := read_config_entries(&PATH_SPEC)
		defer cleanup_entries(&entries)

		for entry in entries {
			item := strings.clone(entry.name)
			append(&items, item)
		}
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

	items := make([dynamic]string)

	// Check if wayu.toml exists and read from it preferentially
	toml_file := fmt.aprintf("%s/%s", WAYU_CONFIG, WAYU_TOML)
	defer delete(toml_file)

	if os.exists(toml_file) {
		config, ok := toml_read_file(toml_file)
		defer {
			// Clean up config memory
			for alias in config.aliases {
				delete(alias.name)
				delete(alias.command)
				delete(alias.description)
			}
			delete(config.aliases)
		}
		if ok {
			for alias in config.aliases {
				item := fmt.aprintf("%s=%s", alias.name, alias.command)
				append(&items, item)
			}
		}
	} else {
		// Fall back to shell config entries
		entries := read_config_entries(&ALIAS_SPEC)
		defer cleanup_entries(&entries)

		for entry in entries {
			item := fmt.aprintf("%s=%s", entry.name, entry.value)
			append(&items, item)
		}
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

	items := make([dynamic]string)

	// Check if wayu.toml exists and read from it preferentially
	toml_file := fmt.aprintf("%s/%s", WAYU_CONFIG, WAYU_TOML)
	defer delete(toml_file)

	if os.exists(toml_file) {
		config, ok := toml_read_file(toml_file)
		defer {
			// Clean up config memory
			for const in config.constants {
				delete(const.name)
				delete(const.value)
				delete(const.description)
			}
			delete(config.constants)
		}
		if ok {
			for const in config.constants {
				item := fmt.aprintf("%s=%s", const.name, const.value)
				append(&items, item)
			}
		}
	} else {
		// Fall back to shell config entries
		entries := read_config_entries(&CONSTANTS_SPEC)
		defer cleanup_entries(&entries)

		for entry in entries {
			item := fmt.aprintf("%s=%s", entry.name, entry.value)
			append(&items, item)
		}
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
	if err != nil {
		// Can't open directory - return empty list
		items_ptr := new([dynamic]string)
		items_ptr^ = items
		state.data_cache[.COMPLETIONS_VIEW] = items_ptr
		return
	}
	defer os.close(dir_handle)

	file_infos, read_err := os.read_dir(dir_handle, -1, context.allocator)
	if read_err != nil {
		// Can't read directory - return empty list
		items_ptr := new([dynamic]string)
		items_ptr^ = items
		state.data_cache[.COMPLETIONS_VIEW] = items_ptr
		return
	}
	defer os.file_info_slice_delete(file_infos, context.allocator)

	// Filter completion files (start with '_', not backup files)
	for info in file_infos {
		if strings.has_prefix(info.name, "_") && info.type != .Directory {
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
	backups_dir := fmt.aprintf("%s/backup", WAYU_CONFIG)
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

	infos, read_err := os.read_dir(dir_handle, -1, context.allocator)
	if read_err != nil {
		// Can't read directory - empty list
		items_ptr := new([dynamic]string)
		items_ptr^ = items
		state.data_cache[.BACKUPS_VIEW] = items_ptr
		return
	}
	defer os.file_info_slice_delete(infos, context.allocator)

	// Filter and format backup files
	for info in infos {
		if info.type == .Directory { continue }

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
tui_bridge_delete_path :: proc(name: string) -> (bool, string) {
	old_dry_run := DRY_RUN
	DRY_RUN = false
	defer { DRY_RUN = old_dry_run }
	return remove_config_entry(&PATH_SPEC, name)
}

// Delete Alias entry
tui_bridge_delete_alias :: proc(name: string) -> (bool, string) {
	old_dry_run := DRY_RUN
	DRY_RUN = false
	defer { DRY_RUN = old_dry_run }
	return remove_config_entry(&ALIAS_SPEC, name)
}

// Delete Constants entry
tui_bridge_delete_constant :: proc(name: string) -> (bool, string) {
	old_dry_run := DRY_RUN
	DRY_RUN = false
	defer { DRY_RUN = old_dry_run }
	return remove_config_entry(&CONSTANTS_SPEC, name)
}

// Add PATH entry
tui_bridge_add_path :: proc(path: string) -> (bool, string) {
	old_dry_run := DRY_RUN
	DRY_RUN = false
	defer { DRY_RUN = old_dry_run }
	return add_config_entry(&PATH_SPEC, ConfigEntry{name = path})
}

// Add Alias entry
tui_bridge_add_alias :: proc(name: string, command: string) -> (bool, string) {
	old_dry_run := DRY_RUN
	DRY_RUN = false
	defer { DRY_RUN = old_dry_run }
	return add_config_entry(&ALIAS_SPEC, ConfigEntry{name = name, value = command})
}

// Add Constants entry
tui_bridge_add_constant :: proc(name: string, value: string) -> (bool, string) {
	old_dry_run := DRY_RUN
	DRY_RUN = false
	defer { DRY_RUN = old_dry_run }
	return add_config_entry(&CONSTANTS_SPEC, ConfigEntry{name = name, value = value})
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

// Load plugin entries into TUI cache
// Format: "name | ✓ Active | priority:100" or "name | ○ Disabled | priority:100"
tui_bridge_load_plugins :: proc(state: ^tui.TUIState) {
	if state.data_cache[.PLUGINS_VIEW] != nil {
		tui.clear_view_cache(state, .PLUGINS_VIEW)
	}

	config, ok := read_plugin_config_json()
	if !ok {
		// No plugins installed yet — store empty list
		items_ptr := new([dynamic]string)
		items_ptr^ = make([dynamic]string)
		state.data_cache[.PLUGINS_VIEW] = items_ptr
		return
	}
	defer cleanup_plugin_config_json(&config)

	items := make([dynamic]string)
	for plugin in config.plugins {
		status := "○ Disabled"
		if plugin.enabled { status = "✓ Active" }
		item := strings.clone(fmt.tprintf("%s | %s | priority:%d", plugin.name, status, plugin.priority))
		append(&items, item)
	}

	items_ptr := new([dynamic]string)
	items_ptr^ = items
	state.data_cache[.PLUGINS_VIEW] = items_ptr
}

// Shared implementation for TUI enable/disable plugin operations.
// Reads JSON config, flips the enabled flag, writes back, and regenerates the
// shell loader. Returns false if the plugin is not found, the write fails, or
// the loader regeneration fails — so callers can show an accurate error state.
// Uses DETECTED_SHELL (set at startup) consistent with the CLI path.
@(private="file")
_tui_bridge_set_plugin_enabled :: proc(name: string, enabled: bool) -> bool {
	config, ok := read_plugin_config_json()
	if !ok { return false }
	defer cleanup_plugin_config_json(&config)

	for &plugin in config.plugins {
		if plugin.name == name {
			plugin.enabled = enabled
			if !write_plugin_config_json(&config) { return false }
			return generate_plugins_file(DETECTED_SHELL)  // propagate loader errors
		}
	}
	return false // plugin not found
}

// Enable plugin by name — reads JSON, flips flag, writes back, regenerates loader
tui_bridge_enable_plugin :: proc(name: string) -> bool {
	return _tui_bridge_set_plugin_enabled(name, true)
}

// Disable plugin by name — reads JSON, flips flag, writes back, regenerates loader
tui_bridge_disable_plugin :: proc(name: string) -> bool {
	return _tui_bridge_set_plugin_enabled(name, false)
}

// Load plugin registry into TUI state cache.
// Each item is NUL-delimited: "key\x00category\x00shell\x00description"
// Skips plugins that are already installed (present in plugins.json).
// Idempotent — skips if cache is already populated.
tui_bridge_load_registry :: proc(state: ^tui.TUIState) {
	if state.plugin_registry_cache != nil { return }

	// Build a set of installed plugin names so we can filter them out
	installed_names := make(map[string]bool)
	defer delete(installed_names)
	config, _ := read_plugin_config_json()
	defer cleanup_plugin_config_json(&config)
	for plugin in config.plugins {
		installed_names[plugin.name] = true
	}

	items := make([dynamic]string)
	for entry in POPULAR_PLUGINS {
		// Skip if this plugin is already installed
		if installed_names[entry.info.name] { continue }

		item := strings.clone(fmt.tprintf("%s\x00%s\x00%s\x00%s",
			entry.key,
			entry.category,
			shell_compat_to_string(entry.info.shell),
			entry.info.description))
		append(&items, item)
	}

	ptr := new([dynamic]string)
	ptr^ = items
	state.plugin_registry_cache = ptr
}

// Install a plugin from the registry by its key.
// Looks up the key in POPULAR_PLUGINS, clones the repo, then registers it in
// plugins.json and regenerates the shell loader so it appears in the Installed tab.
tui_bridge_install_plugin :: proc(key: string) -> bool {
	info, found := popular_plugin_find(key)
	if !found { return false }

	plugins_dir := get_plugins_dir()
	defer delete(plugins_dir)

	// Ensure plugins directory exists
	if !os.exists(plugins_dir) {
		if err := os.make_directory(plugins_dir); err != nil {
			return false
		}
	}

	dest := fmt.aprintf("%s/%s", plugins_dir, info.name)
	defer delete(dest)

	// Clone the repository (blocking — TUI freezes here; notification shown by caller).
	// run_command redirects stdin to /dev/null so git won't try to prompt for
	// credentials via the raw terminal.
	if !git_clone(info.url, dest) { return false }

	// read_plugin_config_json always returns ok=true (creates empty config when file absent)
	config, _ := read_plugin_config_json()
	defer cleanup_plugin_config_json(&config)

	// Skip registration if already present (idempotent)
	_, already_found := find_plugin_json(&config, info.name)
	if !already_found {
		git_info := get_git_info(dest)
		new_plugin := PluginMetadata{
			name           = strings.clone(info.name),
			display_name   = strings.clone(info.name),
			url            = strings.clone(info.url),
			source_type    = .GitHub,  // Default
			enabled        = true,
			shell          = info.shell,
			installed_path = strings.clone(dest),
			entry_file     = "",   // detected by generate_plugins_file
			use            = make([dynamic]string),
			template       = .Source,
			git            = git_info,
			dependencies   = make([dynamic]string),
			priority       = 100,
			profiles       = make([dynamic]string),
			conflicts      = ConflictInfo{},
		}
		append(&config.plugins, new_plugin)
	}

	// Persist config
	if !write_plugin_config_json(&config) { return false }

	// Regenerate shell loader so the plugin is sourced
	return generate_plugins_file(DETECTED_SHELL)
}

// Load Settings into state cache
tui_bridge_load_settings :: proc(state: ^tui.TUIState) {
	// Get shell name from DETECTED_SHELL global
	shell_name := get_shell_name(DETECTED_SHELL)

	// Store in state fields
	state.settings_shell = strings.clone(shell_name)
	state.settings_config_dir = strings.clone(WAYU_CONFIG)
	state.settings_dry_run = DRY_RUN
}

// Get PATH entry detail information
tui_bridge_get_path_detail :: proc(path_str: string) -> [dynamic]string {
	lines := make([dynamic]string)

	append(&lines, strings.clone(fmt.tprintf("Path: %s", path_str)))

	if os.exists(path_str) {
		append(&lines, strings.clone("Status: ✓ Directory exists"))

		// Try to list contents
		dir_handle, err := os.open(path_str)
		if err == nil {
			defer os.close(dir_handle)
			infos, read_err := os.read_dir(dir_handle, -1, context.allocator)
			if read_err == nil {
				defer os.file_info_slice_delete(infos, context.allocator)
				append(&lines, strings.clone(fmt.tprintf("Contents: %d items", len(infos))))
			}
		}
	} else {
		append(&lines, strings.clone("Status: ✗ Directory not found"))
	}

	return lines
}
