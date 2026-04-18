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

// Source glyph colors (from TUI color scheme)
SOURCE_COLOR_WAYU_ACTIVE :: "\x1b[38;2;34;197;94m"    // green
SOURCE_COLOR_WAYU_INACTIVE :: "\x1b[38;2;217;119;6m"  // amber
SOURCE_COLOR_EXTERNAL :: "\x1b[38;2;59;130;246m"      // blue
SOURCE_COLOR_SHADOWED :: "\x1b[38;2;168;85;247m"      // purple
COLOR_RESET :: "\x1b[0m"

// Entry with source information for TUI rendering
// Format: "display_text\x00source_glyph\x00source_enum_value"
// where source_enum_value is "0" (WAYU_ACTIVE), "1" (WAYU_INACTIVE), "2" (EXTERNAL)
TUIEntry :: struct {
	display: string,      // The actual text to display (path/alias=cmd/const=val)
	glyph:   string,      // Colored glyph: "●" (WAYU_ACTIVE), "⚠" (WAYU_INACTIVE), "○" (EXTERNAL)
	source:  EntrySource, // For filtering
}

// Helper: determine if NO_COLOR or --no-color is set
should_color_output :: proc() -> bool {
	// Check NO_COLOR env var
	no_color := os.get_env("NO_COLOR", context.temp_allocator)
	if len(no_color) > 0 {
		return false
	}
	// Check TTY
	return os.is_tty(os.stdout)
}

// Helper: get source glyph with color codes embedded
// Return just the glyph rune (no ANSI). Unicode when available, ASCII fallback otherwise.
get_source_glyph_rune :: proc(source: EntrySource, use_color: bool) -> string {
	if !use_color {
		#partial switch source {
		case .WAYU_ACTIVE:   return "[wayu]"
		case .WAYU_INACTIVE: return "[wayu(i)]"
		case .EXTERNAL:      return "[ext]"
		case .SHADOWED:      return "[diff]"
		}
		return "?"
	}
	#partial switch source {
	case .WAYU_ACTIVE:   return "●"
	case .WAYU_INACTIVE: return "⚠"
	case .EXTERNAL:      return "○"
	case .SHADOWED:      return "♦"
	}
	return "?"
}

// Deprecated — keep only for CLI (path.odin etc.) paths that write ANSI
// straight to stdout. Do NOT use from tui_bridge_load_*.
get_source_glyph_with_ansi :: proc(source: EntrySource, use_color: bool) -> string {
	if !use_color {
		// ASCII-only fallback
		#partial switch source {
		case .WAYU_ACTIVE:
			return "[wayu]"
		case .WAYU_INACTIVE:
			return "[wayu(i)]"
		case .EXTERNAL:
			return "[ext]"
		case .SHADOWED:
			return "[diff]"
		}
		return "?"
	}
	// Unicode glyphs with embedded ANSI color codes
	#partial switch source {
	case .WAYU_ACTIVE:
		return fmt.tprintf("%s●%s", SOURCE_COLOR_WAYU_ACTIVE, COLOR_RESET)
	case .WAYU_INACTIVE:
		return fmt.tprintf("%s⚠%s", SOURCE_COLOR_WAYU_INACTIVE, COLOR_RESET)
	case .EXTERNAL:
		return fmt.tprintf("%s○%s", SOURCE_COLOR_EXTERNAL, COLOR_RESET)
	case .SHADOWED:
		return fmt.tprintf("%s♦%s", SOURCE_COLOR_SHADOWED, COLOR_RESET)
	}
	return "?"
}

// Helper: format counts line with breakdown: "25 wayu · 3 inactive · 47 external"
format_summary_counts :: proc(wayu_active, wayu_inactive, external: int) -> string {
	if wayu_active == 0 && wayu_inactive == 0 && external == 0 {
		return "0 entries"
	}
	parts := make([dynamic]string)
	defer delete(parts)

	if wayu_active > 0 {
		append(&parts, fmt.tprintf("%d wayu", wayu_active))
	}
	if wayu_inactive > 0 {
		append(&parts, fmt.tprintf("%d inactive", wayu_inactive))
	}
	if external > 0 {
		append(&parts, fmt.tprintf("%d external", external))
	}

	result := strings.join(parts[:], " · ")
	return result
}

// Load PATH entries into TUI cache with source classification and external entries
tui_bridge_load_path :: proc(state: ^tui.TUIState) {
	// Clear existing cache
	if state.data_cache[.PATH_VIEW] != nil {
		tui.clear_view_cache(state, .PATH_VIEW)
	}

	items := make([dynamic]string)
	use_color := should_color_output()

	// Read wayu-declared entries from TOML
	wayu_entries := make(map[string]EntrySource)
	defer delete(wayu_entries)

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
			// Get PATH snapshot from env
			env_paths := snapshot_path_entries()

			for entry in config.path.entries {
				// Classify: check if in env
				is_in_env := false
				for env_path in env_paths {
					if env_path == entry {
						is_in_env = true
						break
					}
				}

				source := is_in_env ? EntrySource.WAYU_ACTIVE : EntrySource.WAYU_INACTIVE
				wayu_entries[entry] = source

				// Add to items with glyph
				glyph := get_source_glyph_rune(source, use_color)
				item := fmt.aprintf("%s %s", glyph, entry)
				append(&items, item)
			}

			// Now add external entries (in env but not in TOML)
			// Render separator before external section
			if len(env_paths) > len(wayu_entries) {
				// Count externals
				external_count := 0
				for env_path in env_paths {
					if wayu_entries[env_path] == nil {
						external_count += 1
					}
				}

				if external_count > 0 {
					sep := fmt.tprintf("─── External (%d) ───", external_count)
					append(&items, sep)

					// Add each external path
					for env_path in env_paths {
						if wayu_entries[env_path] == nil {
							glyph := get_source_glyph_rune(EntrySource.EXTERNAL, use_color)
							item := fmt.aprintf("%s %s", glyph, env_path)
							append(&items, item)
						}
					}
				}
			}
		}
	} else {
		// Fall back to shell config entries (no source info)
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

// Load Alias entries into TUI cache with source classification
tui_bridge_load_alias :: proc(state: ^tui.TUIState) {
	// Clear existing cache
	if state.data_cache[.ALIAS_VIEW] != nil {
		tui.clear_view_cache(state, .ALIAS_VIEW)
	}

	items := make([dynamic]string)
	use_color := should_color_output()

	// Track wayu-declared aliases
	wayu_aliases := make(map[string]bool)
	defer delete(wayu_aliases)

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
			// Get alias snapshot from shell
			env_aliases := snapshot_aliases()

			for alias in config.aliases {
				wayu_aliases[alias.name] = true

				// Check if alias is active (in env)
				env_val, exists := env_aliases[alias.name]
				is_active := exists && env_val == alias.command
				source := is_active ? EntrySource.WAYU_ACTIVE : EntrySource.WAYU_INACTIVE

				// Add to items with glyph
				glyph := get_source_glyph_rune(source, use_color)
				item := fmt.aprintf("%s %s=%s", glyph, alias.name, alias.command)
				append(&items, item)
			}

			// Add external aliases (in env but not in TOML)
			external_count := 0
			for env_name in env_aliases {
				if wayu_aliases[env_name] == false {
					external_count += 1
				}
			}

			if external_count > 0 {
				sep := fmt.tprintf("─── External (%d) ───", external_count)
				append(&items, sep)

				for env_name, env_cmd in env_aliases {
					if wayu_aliases[env_name] == false {
						glyph := get_source_glyph_rune(EntrySource.EXTERNAL, use_color)
						item := fmt.aprintf("%s %s=%s", glyph, env_name, env_cmd)
						append(&items, item)
					}
				}
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

// Load Constants entries into TUI cache with source classification
tui_bridge_load_constants :: proc(state: ^tui.TUIState) {
	// Clear existing cache
	if state.data_cache[.CONSTANTS_VIEW] != nil {
		tui.clear_view_cache(state, .CONSTANTS_VIEW)
	}

	items := make([dynamic]string)
	use_color := should_color_output()

	// Track wayu-declared constants
	wayu_constants := make(map[string]bool)
	defer delete(wayu_constants)

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
			// Process [constants] section (structured TOML)
			for const in config.constants {
				wayu_constants[const.name] = true

				// Check if in env using snapshot
				// Constants are active if the NAME exists in env (regardless of value match)
				env_val_maybe := snapshot_env_var(const.name)
				is_active := env_val_maybe != nil
				source := is_active ? EntrySource.WAYU_ACTIVE : EntrySource.WAYU_INACTIVE

				glyph := get_source_glyph_rune(source, use_color)
				item := fmt.aprintf("%s %s=%s", glyph, const.name, const.value)
				append(&items, item)
			}
		}

		// Also parse [env] and [[constants]] sections from raw TOML file
		// (these are not in the structured TomlConfig)
		content, file_ok := safe_read_file(toml_file)
		if file_ok {
			defer delete(content)
			lines := strings.split(string(content), "\n")
			defer delete(lines)

			in_env := false
			in_constants_table := false
			in_constants_array := false
			current_name := ""
			current_value := ""

			for line in lines {
				trimmed := strings.trim_space(line)
				if len(trimmed) == 0 || strings.has_prefix(trimmed, "#") {
					continue
				}

				if trimmed == "[env]" {
					in_env = true
					in_constants_table = false
					in_constants_array = false
					continue
				}
				if trimmed == "[constants]" {
					in_env = false
					in_constants_table = true
					in_constants_array = false
					continue
				}
				if trimmed == "[[constants]]" {
					in_env = false
					in_constants_table = false
					in_constants_array = true
					continue
				}
				if strings.has_prefix(trimmed, "[") {
					in_env = false
					in_constants_table = false
					in_constants_array = false
					continue
				}

				eq_idx := strings.index(trimmed, "=")
				if eq_idx < 1 {
					continue
				}

				name := strings.trim_space(trimmed[:eq_idx])
				value := strings.trim_space(trimmed[eq_idx+1:])
				value = strings.trim_prefix(value, `"`)
				value = strings.trim_suffix(value, `"`)
				value = strings.trim_prefix(value, "'")
				value = strings.trim_suffix(value, "'")
				value = unescape_toml_string(value)

				// Add entries from [env] and [constants] table sections only
				// Skip [[constants]] array which is handled above
				if (in_env || in_constants_table) && len(name) > 0 && len(value) > 0 {
					// Skip if already processed from structured config
					if !(name in wayu_constants) {
						wayu_constants[name] = true

						env_val_maybe := snapshot_env_var(name)
						is_active := env_val_maybe != nil
						source := is_active ? EntrySource.WAYU_ACTIVE : EntrySource.WAYU_INACTIVE

						glyph := get_source_glyph_rune(source, use_color)
						item := fmt.aprintf("%s %s=%s", glyph, name, value)
						append(&items, item)
					}
				}
			}
		}

		// Now add external entries (in env but not in wayu.toml)
		// Match CLI behavior: read environ directly to get accurate external list
		external_constants := make([dynamic]string)
		defer delete(external_constants)

		env_list, env_err := os.environ(context.allocator)
		if env_err == nil {
			defer delete(env_list)
			for pair in env_list {
				parts := strings.split(pair, "=", context.allocator)
				defer delete(parts)
				if len(parts) > 0 {
					const_name := parts[0]
					if !(const_name in wayu_constants) {
						append(&external_constants, const_name)
					}
				}
			}
		}

		if len(external_constants) > 0 {
			sep := fmt.tprintf("─── External (%d) ───", len(external_constants))
			append(&items, sep)

			for ext_const_name in external_constants {
				if env_val := snapshot_env_var(ext_const_name); env_val != nil {
					glyph := get_source_glyph_rune(EntrySource.EXTERNAL, use_color)
					item := fmt.aprintf("%s %s=%s", glyph, ext_const_name, env_val.(string))
					append(&items, item)
				}
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

	// Filter and format backup files - match CLI behavior
	// CLI only shows backups for: path, alias, constants config files
	for info in infos {
		if info.type == .Directory { continue }

		name := info.name
		if !strings.contains(name, ".backup.") {
			continue
		}

		// Only include backups for path, alias, constants files
		// Pattern: {path,aliases,constants}.{ext}.backup.{timestamp}
		is_config := (strings.has_prefix(name, "path.") ||
		              strings.has_prefix(name, "aliases.") ||
		              strings.has_prefix(name, "constants."))

		if is_config {
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
