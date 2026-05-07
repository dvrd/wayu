// toml_serialize.odin - TomlConfig serialization and profile merging
//
// Extracted from config_toml.odin (2026-04-24) per code review L2. Contains:
//   - toml_to_string       — render TomlConfig back to canonical TOML text
//   - toml_merge_profiles  — merge a profile override into a base config
//   - toml_get_active_profile — choose the profile for the current shell env
//
// Pure transforms on TomlConfig values; no I/O and no command dispatch.

package wayu

import "core:fmt"
import "core:os"
import "core:strings"

// ============================================================================
// SERIALIZATION
// ============================================================================

// Serialize TomlConfig to TOML string
toml_to_string :: proc(config: TomlConfig) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	
	// Header
	fmt.sbprintln(&builder, "# wayu configuration file")
	fmt.sbprintln(&builder, "# Documentation: https://github.com/dvrd/wayu")
	fmt.sbprintln(&builder)
	
	// Basic settings
	fmt.sbprintfln(&builder, "version = \"%s\"", config.version != "" ? config.version : "1.0")
	fmt.sbprintfln(&builder, "shell = \"%s\"", config.shell != "" ? config.shell : "zsh")
	fmt.sbprintfln(&builder, "wayu_version = \"%s\"", VERSION)
	fmt.sbprintln(&builder)
	
	// [paths] table: derived-key = "path"
	if len(config.path.entries) > 0 {
		fmt.sbprintln(&builder, "[paths]")
		taken := make(map[string]bool); defer delete(taken)
		lines := make([dynamic]string); defer { for l in lines { delete(l) }; delete(lines) }
		for entry in config.path.entries {
			k := derive_path_key(entry, taken)
			taken[k] = true
			escaped := escape_toml_string(entry)
			append(&lines, fmt.aprintf("%s = \"%s\"", k, escaped))
			delete(escaped)
		}
		// Sort alphabetically by emitted line (key prefix is the key).
		for i := 1; i < len(lines); i += 1 {
			j := i
			for j > 0 && lines[j-1] > lines[j] {
				lines[j-1], lines[j] = lines[j], lines[j-1]
				j -= 1
			}
		}
		for l in lines { fmt.sbprintln(&builder, l) }
		fmt.sbprintln(&builder)
	}

	// [aliases] table: name = "command"
	if len(config.aliases) > 0 {
		fmt.sbprintln(&builder, "[aliases]")
		lines := make([dynamic]string); defer { for l in lines { delete(l) }; delete(lines) }
		for alias in config.aliases {
			escaped := escape_toml_string(alias.command)
			append(&lines, fmt.aprintf("%s = \"%s\"", alias.name, escaped))
			delete(escaped)
		}
		for i := 1; i < len(lines); i += 1 {
			j := i
			for j > 0 && lines[j-1] > lines[j] {
				lines[j-1], lines[j] = lines[j], lines[j-1]
				j -= 1
			}
		}
		for l in lines { fmt.sbprintln(&builder, l) }
		fmt.sbprintln(&builder)
	}

	// [env] table: NAME = "value". The legacy `export`/`secret`/`description`
	// per-entry flags are dropped — every entry is exported, plain string.
	if len(config.constants) > 0 {
		fmt.sbprintln(&builder, "[env]")
		lines := make([dynamic]string); defer { for l in lines { delete(l) }; delete(lines) }
		for c in config.constants {
			escaped := escape_toml_string(c.value)
			append(&lines, fmt.aprintf("%s = \"%s\"", c.name, escaped))
			delete(escaped)
		}
		for i := 1; i < len(lines); i += 1 {
			j := i
			for j > 0 && lines[j-1] > lines[j] {
				lines[j-1], lines[j] = lines[j], lines[j-1]
				j -= 1
			}
		}
		for l in lines { fmt.sbprintln(&builder, l) }
		fmt.sbprintln(&builder)
	}
	
	// Plugins
	if len(config.plugins) > 0 {
		for plugin in config.plugins {
			fmt.sbprintln(&builder, "[[plugins]]")
			fmt.sbprintfln(&builder, "name = \"%s\"", plugin.name)
			fmt.sbprintfln(&builder, "source = \"%s\"", plugin.source)
			if plugin.version != "" {
				fmt.sbprintfln(&builder, "version = \"%s\"", plugin.version)
			}
			if plugin.defer_load {
				fmt.sbprintln(&builder, "defer = true")
			}
			if plugin.priority != 100 {
				fmt.sbprintfln(&builder, "priority = %d", plugin.priority)
			}
			if plugin.condition != "" {
				fmt.sbprintfln(&builder, "condition = \"%s\"", plugin.condition)
			}
			if plugin.description != "" {
				fmt.sbprintfln(&builder, "description = \"%s\"", plugin.description)
			}
			if len(plugin.use) > 0 {
				fmt.sbprint(&builder, "use = [")
				for u, i in plugin.use {
					if i > 0 {
						fmt.sbprint(&builder, ", ")
					}
					fmt.sbprintf(&builder, "\"%s\"", u)
				}
				fmt.sbprintln(&builder, "]")
			}
			fmt.sbprintln(&builder)
		}
	}
	
	// Settings
	fmt.sbprintln(&builder, "[settings]")
	fmt.sbprintfln(&builder, "auto_backup = %t", config.settings.auto_backup)
	fmt.sbprintfln(&builder, "fuzzy_fallback = %t", config.settings.fuzzy_fallback)
	fmt.sbprintfln(&builder, "dry_run_default = %t", config.settings.dry_run_default)
	if len(config.settings.autosuggestions_accept_keys) > 0 {
		fmt.sbprint(&builder, "autosuggestions_accept_keys = [")
		for key, i in config.settings.autosuggestions_accept_keys {
			if i > 0 {
				fmt.sbprint(&builder, ", ")
			}
			fmt.sbprintf(&builder, "\"%s\"", key)
		}
		fmt.sbprintln(&builder, "]")
	}
	fmt.sbprintln(&builder)
	
	// Profiles
	if len(config.profiles) > 0 {
		for profile_name, profile in config.profiles {
			fmt.sbprintfln(&builder, "[profile.%s]", profile_name)
			
			if profile.path != nil {
				fmt.sbprintfln(&builder, "  [profile.%s.path]", profile_name)
				fmt.sbprint(&builder, "    entries = [")
				for entry, i in profile.path.entries {
					if i > 0 {
						fmt.sbprint(&builder, ", ")
					}
					fmt.sbprintf(&builder, "\"%s\"", entry)
				}
				fmt.sbprintln(&builder, "]")
			}
			
			for alias in profile.aliases {
				fmt.sbprintfln(&builder, "  [[profile.%s.aliases]]", profile_name)
				fmt.sbprintfln(&builder, "    name = \"%s\"", alias.name)
				fmt.sbprintfln(&builder, "    command = \"%s\"", alias.command)
			}
			
			for constant in profile.constants {
				fmt.sbprintfln(&builder, "  [[profile.%s.constants]]", profile_name)
				fmt.sbprintfln(&builder, "    name = \"%s\"", constant.name)
				fmt.sbprintfln(&builder, "    value = \"%s\"", constant.value)
			}
			
			if profile.condition != "" {
				fmt.sbprintfln(&builder, "  condition = \"%s\"", profile.condition)
			}
			
			fmt.sbprintln(&builder)
		}
	}
	
	return strings.clone(strings.to_string(builder))
}

// Merge profile into base config
toml_merge_profiles :: proc(base: TomlConfig, profile_name: string) -> TomlConfig {
	profile, ok := base.profiles[profile_name]
	if !ok {
		// Profile not found, return deep clone of base
		result: TomlConfig
		result.version = strings.clone(base.version)
		result.shell = strings.clone(base.shell)
		result.wayu_version = strings.clone(base.wayu_version)
		result.path.dedup = base.path.dedup
		result.path.clean = base.path.clean
		result.path.entries = make([]string, len(base.path.entries))
		for e, i in base.path.entries {
			result.path.entries[i] = strings.clone(e)
		}
		result.aliases = make([]TomlAlias, len(base.aliases))
		for a, i in base.aliases {
			result.aliases[i] = {strings.clone(a.name), strings.clone(a.command), strings.clone(a.description)}
		}
		result.constants = make([]TomlConstant, len(base.constants))
		for c, i in base.constants {
			result.constants[i] = {strings.clone(c.name), strings.clone(c.value), c.export, c.secret, strings.clone(c.description)}
		}
		result.plugins = make([]TomlPlugin, len(base.plugins))
		for p, i in base.plugins {
			result.plugins[i] = {
				strings.clone(p.name), strings.clone(p.source), strings.clone(p.version),
				p.defer_load, p.priority,
				strings.clone(p.condition),
				make([]string, len(p.use)),
				strings.clone(p.description),
			}
			for u, j in p.use {
				result.plugins[i].use[j] = strings.clone(u)
			}
		}
		result.settings = base.settings
		result.settings.autosuggestions_accept_keys = make([]string, len(base.settings.autosuggestions_accept_keys))
		for k, i in base.settings.autosuggestions_accept_keys {
			result.settings.autosuggestions_accept_keys[i] = strings.clone(k)
		}
		result.profiles = make(map[string]ProfileConfig)
		for name, pf in base.profiles {
			pc: ProfileConfig
			pc.condition = strings.clone(pf.condition)
			if pf.path != nil {
				pc.path = new(TomlPathConfig)
				pc.path.dedup = pf.path.dedup
				pc.path.clean = pf.path.clean
				pc.path.entries = make([]string, len(pf.path.entries))
				for e2, i2 in pf.path.entries {
					pc.path.entries[i2] = strings.clone(e2)
				}
			}
			result.profiles[name] = pc
		}
		return result
	}
	
	// Deep-clone base config to avoid sharing string/map pointers
	merged: TomlConfig
	merged.version = strings.clone(base.version)
	merged.shell = strings.clone(base.shell)
	merged.wayu_version = strings.clone(base.wayu_version)
	merged.path.dedup = base.path.dedup
	merged.path.clean = base.path.clean
	merged.path.entries = make([]string, len(base.path.entries))
	for e, i in base.path.entries {
		merged.path.entries[i] = strings.clone(e)
	}
	merged.aliases = nil
	merged.constants = nil
	merged.plugins = nil
	merged.settings = base.settings
	merged.settings.autosuggestions_accept_keys = make([]string, len(base.settings.autosuggestions_accept_keys))
	for k, i in base.settings.autosuggestions_accept_keys {
		merged.settings.autosuggestions_accept_keys[i] = strings.clone(k)
	}
	// Clone profiles map
	merged.profiles = make(map[string]ProfileConfig)
	for name, pf in base.profiles {
		pc: ProfileConfig
		pc.condition = strings.clone(pf.condition)
		if pf.path != nil {
			pc.path = new(TomlPathConfig)
			pc.path.dedup = pf.path.dedup
			pc.path.clean = pf.path.clean
			pc.path.entries = make([]string, len(pf.path.entries))
			for e, i in pf.path.entries {
				pc.path.entries[i] = strings.clone(e)
			}
		}
		pc.aliases = make([]TomlAlias, len(pf.aliases))
		for a, i in pf.aliases {
			pc.aliases[i] = {strings.clone(a.name), strings.clone(a.command), strings.clone(a.description)}
		}
		pc.constants = make([]TomlConstant, len(pf.constants))
		for c, i in pf.constants {
			pc.constants[i] = {strings.clone(c.name), strings.clone(c.value), c.export, c.secret, strings.clone(c.description)}
		}
		pc.plugins = make([]TomlPlugin, len(pf.plugins))
		for p, i in pf.plugins {
			pc.plugins[i] = {
				strings.clone(p.name), strings.clone(p.source), strings.clone(p.version),
				p.defer_load, p.priority,
				strings.clone(p.condition),
				make([]string, len(p.use)),
				strings.clone(p.description),
			}
			for u, j in p.use {
				pc.plugins[i].use[j] = strings.clone(u)
			}
		}
		merged.profiles[name] = pc
	}
	
	// Override path settings if profile has them (deep clone to avoid sharing).
	// Free the base-cloned entries first — otherwise the earlier
	// `merged.path.entries = make(...)` allocation (and every cloned entry
	// inside it) leaks when we swap in the profile version.
	if profile.path != nil {
		merged.path.dedup = profile.path.dedup
		merged.path.clean = profile.path.clean
		if merged.path.entries != nil {
			for e in merged.path.entries {
				delete(e)
			}
			delete(merged.path.entries)
		}
		merged.path.entries = make([]string, len(profile.path.entries))
		for e, i in profile.path.entries {
			merged.path.entries[i] = strings.clone(e)
		}
	}
	
	// Temp dynamic arrays for merged config
	merged_aliases_dyn := make([dynamic]TomlAlias)
	merged_constants_dyn := make([dynamic]TomlConstant)
	merged_plugins_dyn := make([dynamic]TomlPlugin)
	
	// Copy existing aliases (deep clone strings)
	for alias in base.aliases {
		append(&merged_aliases_dyn, TomlAlias{strings.clone(alias.name), strings.clone(alias.command), strings.clone(alias.description)})
	}
	// Append profile aliases (deep clone strings)
	for alias in profile.aliases {
		append(&merged_aliases_dyn, TomlAlias{strings.clone(alias.name), strings.clone(alias.command), strings.clone(alias.description)})
	}
	
	// Copy existing constants (deep clone strings)
	for constant in base.constants {
		append(&merged_constants_dyn, TomlConstant{strings.clone(constant.name), strings.clone(constant.value), constant.export, constant.secret, strings.clone(constant.description)})
	}
	// Append profile constants (deep clone strings)
	for constant in profile.constants {
		append(&merged_constants_dyn, TomlConstant{strings.clone(constant.name), strings.clone(constant.value), constant.export, constant.secret, strings.clone(constant.description)})
	}
	
	// Copy existing plugins (deep clone strings)
	for plugin in base.plugins {
		p := TomlPlugin{
			strings.clone(plugin.name), strings.clone(plugin.source), strings.clone(plugin.version),
			plugin.defer_load, plugin.priority,
			strings.clone(plugin.condition),
			make([]string, len(plugin.use)),
			strings.clone(plugin.description),
		}
		for u, j in plugin.use { p.use[j] = strings.clone(u) }
		append(&merged_plugins_dyn, p)
	}
	// Append profile plugins (deep clone strings)
	for plugin in profile.plugins {
		p := TomlPlugin{
			strings.clone(plugin.name), strings.clone(plugin.source), strings.clone(plugin.version),
			plugin.defer_load, plugin.priority,
			strings.clone(plugin.condition),
			make([]string, len(plugin.use)),
			strings.clone(plugin.description),
		}
		for u, j in plugin.use { p.use[j] = strings.clone(u) }
		append(&merged_plugins_dyn, p)
	}
	
	// Assign dynamic arrays to merged
	ma_slice := make([]TomlAlias, len(merged_aliases_dyn))
	copy(ma_slice, merged_aliases_dyn[:])
	delete(merged_aliases_dyn)
	merged.aliases = ma_slice
	
	mc_slice := make([]TomlConstant, len(merged_constants_dyn))
	copy(mc_slice, merged_constants_dyn[:])
	delete(merged_constants_dyn)
	merged.constants = mc_slice
	
	mp_slice := make([]TomlPlugin, len(merged_plugins_dyn))
	copy(mp_slice, merged_plugins_dyn[:])
	delete(merged_plugins_dyn)
	merged.plugins = mp_slice
	
	return merged
}

// Get active profile based on condition (simplified - returns first matching)
toml_get_active_profile :: proc(config: TomlConfig) -> string {
	for name, profile in config.profiles {
		if profile.condition != "" {
			// Simple condition evaluation could be expanded
			// For now, just return first profile with a condition
			return name
		}
	}
	return ""
}

