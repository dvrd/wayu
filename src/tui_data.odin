// tui_data.odin - TUI data loading and mutation helpers

package wayu

import "core:fmt"
import "core:os"
import "core:strings"

// ============================================================================
// Plugin operations
// ============================================================================

tui_cleanup_backups :: proc() -> bool {
	config_files := []string{
		fmt.aprintf("%s/path.%s", g_ctx.wayu_config, g_ctx.shell_ext),
		fmt.aprintf("%s/aliases.%s", g_ctx.wayu_config, g_ctx.shell_ext),
		fmt.aprintf("%s/constants.%s", g_ctx.wayu_config, g_ctx.shell_ext),
	}
	defer for file in config_files do delete(file)

	for file in config_files {
		if os.exists(file) {
			cleanup_old_backups(file, 5)
		}
	}
	return true
}

tui_enable_plugin :: proc(name: string) -> bool {
	return _tui_set_plugin_enabled(name, true)
}

tui_disable_plugin :: proc(name: string) -> bool {
	return _tui_set_plugin_enabled(name, false)
}

@(private="file")
_tui_set_plugin_enabled :: proc(name: string, enabled: bool) -> bool {
	config, ok := read_plugin_config_json()
	if !ok { return false }
	defer cleanup_plugin_config_json(&config)

	for &plugin in config.plugins {
		if plugin.name == name {
			plugin.enabled = enabled
			if !write_plugin_config_json(&config) { return false }
			return generate_plugins_file(g_ctx.shell)
		}
	}
	return false
}

tui_install_plugin :: proc(key: string) -> bool {
	info, found := popular_plugin_find(key)
	if !found { return false }

	plugins_dir := get_plugins_dir()
	defer delete(plugins_dir)

	if !os.exists(plugins_dir) {
		if err := os.make_directory(plugins_dir); err != nil {
			return false
		}
	}

	dest := fmt.aprintf("%s/%s", plugins_dir, info.name)
	defer delete(dest)

	if !git_clone(info.url, dest) { return false }

	config, _ := read_plugin_config_json()
	defer cleanup_plugin_config_json(&config)

	_, already_found := find_plugin_json(&config, info.name)
	if !already_found {
		git_info := get_git_info(dest)
		new_plugin := PluginMetadata{
			name           = strings.clone(info.name),
			display_name   = strings.clone(info.name),
			url            = strings.clone(info.url),
			source_type    = .GitHub,
			enabled        = true,
			shell          = info.shell,
			installed_path = strings.clone(dest),
			entry_file     = "",
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

	if !write_plugin_config_json(&config) { return false }
	return generate_plugins_file(g_ctx.shell)
}

tui_get_path_detail :: proc(path_str: string) -> [dynamic]string {
	lines := make([dynamic]string)
	append(&lines, strings.clone(fmt.tprintf("Path: %s", path_str)))

	if os.exists(path_str) {
		append(&lines, strings.clone("Status: ✓ Directory exists"))
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

// ============================================================================
// Data loading — populates TUI state caches
// ============================================================================

@(private="file")
should_color_output :: proc() -> bool {
	no_color := os.get_env("NO_COLOR", context.temp_allocator)
	if len(no_color) > 0 { return false }
	return os.is_tty(os.stdout)
}

@(private="file")
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

tui_load_path :: proc(state: ^TUIState) {
	if state.data_cache[.PATH_VIEW] != nil {
		clear_view_cache(state, .PATH_VIEW)
	}

	items := make([dynamic]string)
	use_color := should_color_output()

	wayu_entries := make(map[string]EntrySource)
	defer delete(wayu_entries)

	toml_file := fmt.aprintf("%s/%s", g_ctx.wayu_config, WAYU_TOML)
	defer delete(toml_file)

	if os.exists(toml_file) {
		config, ok := toml_read_file(toml_file)
		defer {
			for entry in config.path.entries { delete(entry) }
			delete(config.path.entries)
		}
		if ok {
			env_paths := snapshot_path_entries()

			for entry in config.path.entries {
				is_in_env := false
				for env_path in env_paths {
					if env_path == entry {
						is_in_env = true
						break
					}
				}

				source := is_in_env ? EntrySource.WAYU_ACTIVE : EntrySource.WAYU_INACTIVE
				wayu_entries[entry] = source

				glyph := get_source_glyph_rune(source, use_color)
				item := fmt.aprintf("%s %s", glyph, entry)
				append(&items, item)
			}

			if len(env_paths) > len(wayu_entries) {
				external_count := 0
				for env_path in env_paths {
					if wayu_entries[env_path] == nil {
						external_count += 1
					}
				}

				if external_count > 0 {
					sep := fmt.tprintf("─── External (%d) ───", external_count)
					append(&items, sep)

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
		entries := read_config_entries(&PATH_SPEC)
		defer cleanup_entries(&entries)

		for entry in entries {
			item := strings.clone(entry.name)
			append(&items, item)
		}
	}

	items_ptr := new([dynamic]string)
	items_ptr^ = items
	state.data_cache[.PATH_VIEW] = items_ptr
}

tui_load_alias :: proc(state: ^TUIState) {
	if state.data_cache[.ALIAS_VIEW] != nil {
		clear_view_cache(state, .ALIAS_VIEW)
	}

	items := make([dynamic]string)
	use_color := should_color_output()

	wayu_aliases := make(map[string]bool)
	defer delete(wayu_aliases)

	toml_file := fmt.aprintf("%s/%s", g_ctx.wayu_config, WAYU_TOML)
	defer delete(toml_file)

	if os.exists(toml_file) {
		config, ok := toml_read_file(toml_file)
		defer {
			for alias in config.aliases {
				delete(alias.name)
				delete(alias.command)
				delete(alias.description)
			}
			delete(config.aliases)
		}
		if ok {
			env_aliases := snapshot_aliases()

			for alias in config.aliases {
				wayu_aliases[alias.name] = true

				env_val, exists := env_aliases[alias.name]
				is_active := exists && env_val == alias.command
				source := is_active ? EntrySource.WAYU_ACTIVE : EntrySource.WAYU_INACTIVE

				glyph := get_source_glyph_rune(source, use_color)
				item := fmt.aprintf("%s %s=%s", glyph, alias.name, alias.command)
				append(&items, item)
			}

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
		entries := read_config_entries(&ALIAS_SPEC)
		defer cleanup_entries(&entries)

		for entry in entries {
			item := fmt.aprintf("%s=%s", entry.name, entry.value)
			append(&items, item)
		}
	}

	items_ptr := new([dynamic]string)
	items_ptr^ = items
	state.data_cache[.ALIAS_VIEW] = items_ptr
}

tui_load_constants :: proc(state: ^TUIState) {
	if state.data_cache[.CONSTANTS_VIEW] != nil {
		clear_view_cache(state, .CONSTANTS_VIEW)
	}

	items := make([dynamic]string)
	use_color := should_color_output()

	wayu_constants := make(map[string]bool)
	defer delete(wayu_constants)

	toml_file := fmt.aprintf("%s/%s", g_ctx.wayu_config, WAYU_TOML)
	defer delete(toml_file)

	if os.exists(toml_file) {
		config, ok := toml_read_file(toml_file)
		defer {
			for const in config.constants {
				delete(const.name)
				delete(const.value)
				delete(const.description)
			}
			delete(config.constants)
		}
		if ok {
			for const in config.constants {
				wayu_constants[const.name] = true

				env_val_maybe := snapshot_env_var(const.name)
				is_active := env_val_maybe != nil
				source := is_active ? EntrySource.WAYU_ACTIVE : EntrySource.WAYU_INACTIVE

				glyph := get_source_glyph_rune(source, use_color)
				item := fmt.aprintf("%s %s=%s", glyph, const.name, const.value)
				append(&items, item)
			}
		}

		content, file_ok := safe_read_file(toml_file)
		if file_ok {
			defer delete(content)
			lines := strings.split(string(content), "\n")
			defer delete(lines)

			in_env := false
			for line in lines {
				trimmed := strings.trim_space(line)
				if trimmed == "[env]" { in_env = true; continue }
				if strings.has_prefix(trimmed, "[") { in_env = false; continue }
				if !in_env { continue }
				if len(trimmed) == 0 || strings.has_prefix(trimmed, "#") { continue }

				eq_idx := strings.index_byte(trimmed, '=')
				if eq_idx < 1 { continue }

				name := strings.trim_space(trimmed[:eq_idx])
				value := strings.trim_space(trimmed[eq_idx+1:])
				value = strings.trim_prefix(value, `"`)
				value = strings.trim_suffix(value, `"`)
				value = strings.trim_prefix(value, "'")
				value = strings.trim_suffix(value, "'")
				if len(name) == 0 || len(value) == 0 { continue }
				if name in wayu_constants { continue }

				wayu_constants[name] = true
				unescaped := unescape_toml_string(value)
				defer delete(unescaped)
				env_val_maybe := snapshot_env_var(name)
				is_active := env_val_maybe != nil
				source := is_active ? EntrySource.WAYU_ACTIVE : EntrySource.WAYU_INACTIVE
				glyph := get_source_glyph_rune(source, use_color)
				item := fmt.aprintf("%s %s=%s", glyph, name, unescaped)
				append(&items, item)
			}
		}

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
		entries := read_config_entries(&CONSTANTS_SPEC)
		defer cleanup_entries(&entries)

		for entry in entries {
			item := fmt.aprintf("%s=%s", entry.name, entry.value)
			append(&items, item)
		}
	}

	items_ptr := new([dynamic]string)
	items_ptr^ = items
	state.data_cache[.CONSTANTS_VIEW] = items_ptr
}

tui_load_completions :: proc(state: ^TUIState) {
	if state.data_cache[.COMPLETIONS_VIEW] != nil {
		clear_view_cache(state, .COMPLETIONS_VIEW)
	}

	completions_dir := fmt.aprintf("%s/completions", g_ctx.wayu_config)
	defer delete(completions_dir)

	items := make([dynamic]string)

	if !os.exists(completions_dir) {
		items_ptr := new([dynamic]string)
		items_ptr^ = items
		state.data_cache[.COMPLETIONS_VIEW] = items_ptr
		return
	}

	dir_handle, err := os.open(completions_dir)
	if err != nil {
		items_ptr := new([dynamic]string)
		items_ptr^ = items
		state.data_cache[.COMPLETIONS_VIEW] = items_ptr
		return
	}
	defer os.close(dir_handle)

	file_infos, read_err := os.read_dir(dir_handle, -1, context.allocator)
	if read_err != nil {
		items_ptr := new([dynamic]string)
		items_ptr^ = items
		state.data_cache[.COMPLETIONS_VIEW] = items_ptr
		return
	}
	defer os.file_info_slice_delete(file_infos, context.allocator)

	for info in file_infos {
		if strings.has_prefix(info.name, "_") && info.type != .Directory {
			if strings.contains(info.name, ".backup.") { continue }
			item := strings.clone(info.name)
			append(&items, item)
		}
	}

	items_ptr := new([dynamic]string)
	items_ptr^ = items
	state.data_cache[.COMPLETIONS_VIEW] = items_ptr
}

tui_load_backups :: proc(state: ^TUIState) {
	if state.data_cache[.BACKUPS_VIEW] != nil {
		clear_view_cache(state, .BACKUPS_VIEW)
	}

	items := make([dynamic]string)

	backups_dir := fmt.aprintf("%s/backup", g_ctx.wayu_config)
	defer delete(backups_dir)

	if !os.exists(backups_dir) {
		items_ptr := new([dynamic]string)
		items_ptr^ = items
		state.data_cache[.BACKUPS_VIEW] = items_ptr
		return
	}

	dir_handle, err := os.open(backups_dir)
	if err != nil {
		items_ptr := new([dynamic]string)
		items_ptr^ = items
		state.data_cache[.BACKUPS_VIEW] = items_ptr
		return
	}
	defer os.close(dir_handle)

	infos, read_err := os.read_dir(dir_handle, -1, context.allocator)
	if read_err != nil {
		items_ptr := new([dynamic]string)
		items_ptr^ = items
		state.data_cache[.BACKUPS_VIEW] = items_ptr
		return
	}
	defer os.file_info_slice_delete(infos, context.allocator)

	for info in infos {
		if info.type == .Directory { continue }

		name := info.name
		if !strings.contains(name, ".backup.") { continue }

		is_config := (strings.has_prefix(name, "path.") ||
		              strings.has_prefix(name, "aliases.") ||
		              strings.has_prefix(name, "constants."))

		if is_config {
			item := strings.clone(name)
			append(&items, item)
		}
	}

	items_ptr := new([dynamic]string)
	items_ptr^ = items
	state.data_cache[.BACKUPS_VIEW] = items_ptr
}

tui_load_plugins :: proc(state: ^TUIState) {
	if state.data_cache[.PLUGINS_VIEW] != nil {
		clear_view_cache(state, .PLUGINS_VIEW)
	}

	config, ok := read_plugin_config_json()
	if !ok {
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

tui_load_settings :: proc(state: ^TUIState) {
	if state.settings_loaded { return }

	if len(state.settings_shell)      > 0 { delete(state.settings_shell) }
	if len(state.settings_config_dir) > 0 { delete(state.settings_config_dir) }
	if len(state.settings_version)    > 0 { delete(state.settings_version) }
	if len(state.settings_toml_path)  > 0 { delete(state.settings_toml_path) }

	state.settings_shell      = strings.clone(get_shell_name(g_ctx.shell))
	state.settings_config_dir = strings.clone(g_ctx.wayu_config)
	state.settings_dry_run    = g_ctx.dry_run
	state.settings_version    = strings.clone(VERSION)

	toml_full := fmt.aprintf("%s/%s", g_ctx.wayu_config, WAYU_TOML)
	state.settings_toml_path   = toml_full
	state.settings_toml_exists = os.exists(toml_full)

	total_backups := 0
	backup_targets := []string{g_ctx.path_file, g_ctx.alias_file, g_ctx.constants_file}
	for f in backup_targets {
		full := fmt.aprintf("%s/%s", g_ctx.wayu_config, f)
		defer delete(full)
		backups := list_backups_for_file(full)
		total_backups += len(backups)
		for b in backups {
			delete(b.original_file)
			delete(b.backup_file)
		}
		delete(backups)
	}
	state.settings_backups = total_backups

	enabled_plugins := 0
	config, cfg_ok := read_plugin_config_json()
	if cfg_ok {
		for plugin in config.plugins {
			if plugin.enabled { enabled_plugins += 1 }
		}
		cleanup_plugin_config_json(&config)
	}
	state.settings_plugins = enabled_plugins

	state.settings_loaded = true
}

tui_load_registry :: proc(state: ^TUIState) {
	if state.plugin_registry_cache != nil { return }

	installed_names := make(map[string]bool)
	defer delete(installed_names)
	config, _ := read_plugin_config_json()
	defer cleanup_plugin_config_json(&config)
	for plugin in config.plugins {
		installed_names[plugin.name] = true
	}

	items := make([dynamic]string)
	for entry in POPULAR_PLUGINS {
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

tui_ensure_data_loaded :: proc(state: ^TUIState, view: TUIView) {
	switch view {
	case .PATH_VIEW:
		if state.data_cache[view] == nil do tui_load_path(state)
	case .ALIAS_VIEW:
		if state.data_cache[view] == nil do tui_load_alias(state)
	case .CONSTANTS_VIEW:
		if state.data_cache[view] == nil do tui_load_constants(state)
	case .COMPLETIONS_VIEW:
		if state.data_cache[view] == nil do tui_load_completions(state)
	case .BACKUPS_VIEW:
		if state.data_cache[view] == nil do tui_load_backups(state)
	case .PLUGINS_VIEW:
		if state.data_cache[view] == nil do tui_load_plugins(state)
		tui_load_registry(state)
	case .MAIN_MENU, .HOOKS_VIEW, .SETTINGS_VIEW:
	}
}
