// toml_mapping.odin - TomlDoc → TomlConfig mapping and value accessors
//
// Extracted from config_toml.odin (2026-04-24) per code review L2.
// This file owns the translation from the parsed TOML AST (TomlDoc/TomlValue,
// defined in config_toml.odin) into the strongly-typed `TomlConfig` struct
// that the rest of wayu consumes. Pure data-shape translation; no I/O,
// no serialization, no command-handler logic.

package wayu

import "core:fmt"
import "core:strings"

// ============================================================================
// TOML TO CONFIG CONVERSION
// ============================================================================

// Extract string array from TOML value
get_string_array :: proc(val: ^TomlValue) -> ([]string, bool) {
	if val == nil || val.type != .ARRAY {
		return nil, false
	}
	
	n := 0
	for elem in val.arr_val {
		if elem.type == .STRING {
			n += 1
		}
	}
	
	result := make([]string, n)
	i := 0
	for elem in val.arr_val {
		if elem.type == .STRING {
			result[i] = strings.clone(elem.str_val)
			i += 1
		}
	}
	
	return result, true
}

// Extract string from TOML value
get_string :: proc(val: ^TomlValue, default: string = "") -> string {
	if val == nil || val.type != .STRING {
		return strings.clone(default)
	}
	return strings.clone(val.str_val)
}

// Extract int from TOML value
get_int :: proc(val: ^TomlValue, default: int = 0) -> int {
	if val == nil || val.type != .INTEGER {
		return default
	}
	return val.int_val
}

// Extract bool from TOML value
get_bool :: proc(val: ^TomlValue, default: bool = false) -> bool {
	if val == nil {
		return default
	}
	if val.type == .BOOLEAN {
		return val.bool_val
	}
	if val.type == .STRING {
		return val.str_val == "true"
	}
	return default
}

// Convert TomlDoc to TomlConfig
doc_to_config :: proc(doc: ^TomlDoc) -> (TomlConfig, bool) {
	config: TomlConfig
	
	// Temp dynamic arrays for building slices
	aliases_dyn := make([dynamic]TomlAlias)
	constants_dyn := make([dynamic]TomlConstant)
	plugins_dyn := make([dynamic]TomlPlugin)
	
	// Basic fields
	version_val := get_toml_value(doc, "version")
	config.version = get_string(version_val, "1.0")
	
	shell_val := get_toml_value(doc, "shell")
	config.shell = get_string(shell_val, "zsh")
	
	wayu_version_val := get_toml_value(doc, "wayu_version")
	config.wayu_version = get_string(wayu_version_val, VERSION)
	
	// [paths] table: name = "/path/to/dir".
	paths_val := get_toml_value(doc, "paths")
	if paths_val != nil && paths_val.type == .TABLE {
		paths_entries := make([dynamic]string)
		names := make([dynamic]string)
		defer delete(names)
		for name, _ in paths_val.table_val { append(&names, name) }
		// Sort by key for deterministic order.
		for i := 1; i < len(names); i += 1 {
			j := i
			for j > 0 && names[j-1] > names[j] {
				names[j-1], names[j] = names[j], names[j-1]
				j -= 1
			}
		}
		for n in names {
			v := paths_val.table_val[n]
			if v != nil && v.type == .STRING {
				append(&paths_entries, strings.clone(v.str_val))
			}
		}
		config.path.entries = paths_entries[:]
	}

	path_dedup_val := get_toml_value(doc, "path.dedup")
	config.path.dedup = get_bool(path_dedup_val, true)

	path_clean_val := get_toml_value(doc, "path.clean")
	config.path.clean = get_bool(path_clean_val, false)
	
	// [aliases] table: name = "command".
	aliases_val := get_toml_value(doc, "aliases")
	if aliases_val != nil && aliases_val.type == .TABLE {
		for name, cmd_val in aliases_val.table_val {
			if cmd_val == nil || cmd_val.type != .STRING { continue }
			alias: TomlAlias
			alias.name = strings.clone(name)
			alias.command = strings.clone(cmd_val.str_val)
			append(&aliases_dyn, alias)
		}
	}
	
	// [env] table: NAME = "value". Always exported (no per-entry flags).
	env_val := get_toml_value(doc, "env")
	if env_val != nil && env_val.type == .TABLE {
		for name, val_val in env_val.table_val {
			if val_val == nil || val_val.type != .STRING { continue }
			constant: TomlConstant
			constant.name = strings.clone(name)
			constant.value = strings.clone(val_val.str_val)
			constant.export = true
			append(&constants_dyn, constant)
		}
	}
	
	// Parse plugins
	plugins_val := get_toml_value(doc, "plugins")
	if plugins_val != nil && plugins_val.type == .ARRAY {
		for plugin_table in plugins_val.arr_val {
			if plugin_table.type != .TABLE {
				continue
			}
			
			plugin: TomlPlugin
			if name_val, ok := plugin_table.table_val["name"]; ok && name_val.type == .STRING {
				plugin.name = strings.clone(name_val.str_val)
			}
			if source_val, ok := plugin_table.table_val["source"]; ok && source_val.type == .STRING {
				plugin.source = strings.clone(source_val.str_val)
			}
			if version_val, ok := plugin_table.table_val["version"]; ok && version_val.type == .STRING {
				plugin.version = strings.clone(version_val.str_val)
			}
			if defer_val, ok := plugin_table.table_val["defer"]; ok {
				plugin.defer_load = get_bool(defer_val, false)
			}
			if priority_val, ok := plugin_table.table_val["priority"]; ok {
				plugin.priority = get_int(priority_val, 100)
			} else {
				plugin.priority = 100
			}
			if cond_val, ok := plugin_table.table_val["condition"]; ok && cond_val.type == .STRING {
				plugin.condition = strings.clone(cond_val.str_val)
			}
			if desc_val, ok := plugin_table.table_val["description"]; ok && desc_val.type == .STRING {
				plugin.description = strings.clone(desc_val.str_val)
			}
			
			// Parse use array
			if use_val, ok := plugin_table.table_val["use"]; ok && use_val.type == .ARRAY {
				use_files, _ := get_string_array(use_val)
				plugin.use = use_files
			}
			
			if len(plugin.name) > 0 {
				append(&plugins_dyn, plugin)
			}
		}
	}
	
	// Extract slices from dynamics and free dynamic metadata
	aliases_slice := make([]TomlAlias, len(aliases_dyn))
	copy(aliases_slice, aliases_dyn[:])
	delete(aliases_dyn)
	config.aliases = aliases_slice
	
	constants_slice := make([]TomlConstant, len(constants_dyn))
	copy(constants_slice, constants_dyn[:])
	delete(constants_dyn)
	config.constants = constants_slice
	
	plugins_slice := make([]TomlPlugin, len(plugins_dyn))
	copy(plugins_slice, plugins_dyn[:])
	delete(plugins_dyn)
	config.plugins = plugins_slice
	
	// Parse profiles
	profiles_val := get_toml_value(doc, "profile")
	if profiles_val != nil && profiles_val.type == .TABLE {
		for profile_name, profile_table in profiles_val.table_val {
			if profile_table.type != .TABLE {
				continue
			}
			
			profile: ProfileConfig
			
			// Parse profile path overrides
			if path_val, ok := profile_table.table_val["path"]; ok && path_val.type == .TABLE {
				profile.path = new(TomlPathConfig)
				if entries_val, ok2 := path_val.table_val["entries"]; ok2 && entries_val.type == .ARRAY {
					entries, _ := get_string_array(entries_val)
					profile.path.entries = entries
				}
				if dedup_val, ok2 := path_val.table_val["dedup"]; ok2 {
					profile.path.dedup = get_bool(dedup_val, true)
				}
				if clean_val, ok2 := path_val.table_val["clean"]; ok2 {
					profile.path.clean = get_bool(clean_val, false)
				}
			}
			
			// Temp dynamic arrays for profile
			profile_aliases_dyn := make([dynamic]TomlAlias)
			profile_constants_dyn := make([dynamic]TomlConstant)
			profile_plugins_dyn := make([dynamic]TomlPlugin)
			
			// Parse profile aliases - support both formats
			if aliases_val, ok := profile_table.table_val["aliases"]; ok {
				if aliases_val.type == .TABLE {
					// New format: simple table
					for name, cmd_val in aliases_val.table_val {
						if cmd_val.type == .STRING {
							alias: TomlAlias
							alias.name = strings.clone(name)
							alias.command = strings.clone(cmd_val.str_val)
							append(&profile_aliases_dyn, alias)
						}
					}
				} else if aliases_val.type == .ARRAY {
					// Old format: array of tables
					for alias_table in aliases_val.arr_val {
						if alias_table.type != .TABLE {
							continue
						}
						alias: TomlAlias
						if name_val, ok2 := alias_table.table_val["name"]; ok2 && name_val.type == .STRING {
							alias.name = strings.clone(name_val.str_val)
						}
						if cmd_val, ok2 := alias_table.table_val["command"]; ok2 && cmd_val.type == .STRING {
							alias.command = strings.clone(cmd_val.str_val)
						}
						if len(alias.name) > 0 {
							append(&profile_aliases_dyn, alias)
						}
					}
				}
			}
			
			// Parse profile constants - support both formats
			if constants_val, ok := profile_table.table_val["constants"]; ok {
				if constants_val.type == .TABLE {
					// New format: simple table
					for name, val_val in constants_val.table_val {
						if val_val.type == .STRING {
							constant: TomlConstant
							constant.name = strings.clone(name)
							constant.value = strings.clone(val_val.str_val)
							constant.export = true
							append(&profile_constants_dyn, constant)
						}
					}
				} else if constants_val.type == .ARRAY {
					// Old format: array of tables
					for const_table in constants_val.arr_val {
						if const_table.type != .TABLE {
							continue
						}
						constant: TomlConstant
						if name_val, ok2 := const_table.table_val["name"]; ok2 && name_val.type == .STRING {
							constant.name = strings.clone(name_val.str_val)
						}
						if val_val, ok2 := const_table.table_val["value"]; ok2 && val_val.type == .STRING {
							constant.value = strings.clone(val_val.str_val)
						}
						if len(constant.name) > 0 {
							append(&profile_constants_dyn, constant)
						}
					}
				}
			}
			
			// Parse profile plugins
			if plugins_val, ok := profile_table.table_val["plugins"]; ok && plugins_val.type == .ARRAY {
				for plugin_table in plugins_val.arr_val {
					if plugin_table.type != .TABLE {
						continue
					}
					plugin: TomlPlugin
					if name_val, ok2 := plugin_table.table_val["name"]; ok2 && name_val.type == .STRING {
						plugin.name = strings.clone(name_val.str_val)
					}
					if len(plugin.name) > 0 {
						append(&profile_plugins_dyn, plugin)
					}
				}
			}
			
			// Assign dynamic arrays to profile slices
			pa_slice := make([]TomlAlias, len(profile_aliases_dyn))
			copy(pa_slice, profile_aliases_dyn[:])
			delete(profile_aliases_dyn)
			profile.aliases = pa_slice
			
			pc_slice := make([]TomlConstant, len(profile_constants_dyn))
			copy(pc_slice, profile_constants_dyn[:])
			delete(profile_constants_dyn)
			profile.constants = pc_slice
			
			pp_slice := make([]TomlPlugin, len(profile_plugins_dyn))
			copy(pp_slice, profile_plugins_dyn[:])
			delete(profile_plugins_dyn)
			profile.plugins = pp_slice
			
			// Parse profile condition
			if cond_val, ok := profile_table.table_val["condition"]; ok && cond_val.type == .STRING {
				profile.condition = strings.clone(cond_val.str_val)
			}
			
			config.profiles[profile_name] = profile
		}
	}
	
	// Parse settings
	settings_val := get_toml_value(doc, "settings")
	if settings_val != nil && settings_val.type == .TABLE {
		if auto_backup_val, ok := settings_val.table_val["auto_backup"]; ok {
			config.settings.auto_backup = get_bool(auto_backup_val, true)
		}
		if fuzzy_val, ok := settings_val.table_val["fuzzy_fallback"]; ok {
			config.settings.fuzzy_fallback = get_bool(fuzzy_val, true)
		}
		if dry_run_val, ok := settings_val.table_val["dry_run_default"]; ok {
			config.settings.dry_run_default = get_bool(dry_run_val, false)
		}
		if accept_keys_val, ok := settings_val.table_val["autosuggestions_accept_keys"]; ok && accept_keys_val.type == .ARRAY {
			accept_keys, ok2 := get_string_array(accept_keys_val)
			if ok2 {
				config.settings.autosuggestions_accept_keys = accept_keys
			}
		}
	}
	if config.settings.autosuggestions_accept_keys == nil || len(config.settings.autosuggestions_accept_keys) == 0 {
		keys := make([]string, 2)
		keys[0] = strings.clone("^Y")
		keys[1] = strings.clone("^[[121;5u")
		config.settings.autosuggestions_accept_keys = keys
	}
	
	return config, true
}

