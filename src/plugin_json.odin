package wayu
import "core:fmt"
import "core:os"
import "core:strings"
import "core:slice"
import "core:sync"
import "core:strconv"
import "core:encoding/json"
import "core:reflect"
import "base:intrinsics"
// Mutex to protect concurrent access to plugins.json
// Prevents race conditions when multiple threads read/write simultaneously
_plugins_json_mutex: sync.Mutex

// Get plugins config file path
get_plugins_config_file :: proc() -> string {
	return fmt.aprintf("%s/plugins.conf", wayu.data)
}

// Get plugins JSON config file path
get_plugins_json_config_file :: proc() -> string {
	return fmt.aprintf("%s/plugins.json", wayu.data)
}

// Get plugins directory path
get_plugins_dir :: proc() -> string {
	return fmt.aprintf("%s/plugins", wayu.data)
}

// Read plugins.conf configuration file
read_plugin_config :: proc() -> PluginConfig {
	config := PluginConfig{}
	config.plugins = make([dynamic]InstalledPlugin)

	config_file := get_plugins_config_file()
	defer delete(config_file)

	if !os.exists(config_file) {
		return config
	}

	data, read_err := os.read_entire_file(config_file, context.allocator)
	if read_err != nil {
		return config
	}
	defer delete(data)

	content := string(data)
	lines := strings.split_lines(content)
	defer delete(lines)

	for line in lines {
		trimmed_line := strings.trim_space(line)

		// Skip empty lines and comments
		if len(trimmed_line) == 0 || strings.has_prefix(trimmed_line, "#") {
			continue
		}

		// Parse: name|url|enabled|shell
		parts := strings.split(trimmed_line, "|")
		defer delete(parts)

		if len(parts) != 4 {
			continue
		}

		plugins_dir := get_plugins_dir()
		defer delete(plugins_dir)

		plugin := InstalledPlugin{
			name = strings.clone(parts[0]),
			url = strings.clone(parts[1]),
			enabled = parts[2] == "true",
			shell = parse_shell_compat(parts[3]),
			installed_path = fmt.aprintf("%s/%s", plugins_dir, parts[0]),
		}

		append(&config.plugins, plugin)
	}

	return config
}

// Write plugins.conf configuration file
write_plugin_config :: proc(config: ^PluginConfig) -> bool {
	config_file := get_plugins_config_file()
	defer delete(config_file)

	// Build content
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)

	strings.write_string(&sb, "# Wayu Plugin Configuration\n")
	strings.write_string(&sb, "# Format: name|url|enabled|shell\n")
	strings.write_string(&sb, "# shell: zsh, bash, both\n\n")

	for plugin in config.plugins {
		line := fmt.aprintf("%s|%s|%t|%s\n",
			plugin.name,
			plugin.url,
			plugin.enabled,
			shell_compat_to_string(plugin.shell))
		defer delete(line)

		strings.write_string(&sb, line)
	}

	content := strings.to_string(sb)
	return write_file_atomic(config_file, transmute([]byte)content) == nil
}

// Read JSON5 configuration file
read_plugin_config_json :: proc() -> (config: PluginConfigJSON, ok: bool) {
	sync.lock(&_plugins_json_mutex)
	defer sync.unlock(&_plugins_json_mutex)

	config_file := get_plugins_json_config_file()
	defer delete(config_file)

	if !os.exists(config_file) {
		// Return empty config on first run
		config.version = strings.clone("1.0")
		config.last_updated = get_iso8601_timestamp()
		config.plugins = make([dynamic]PluginMetadata)
		return config, true
	}

	data, read_err := os.read_entire_file(config_file, context.allocator)
	if read_err != nil {
		fmt.eprintln("Error: Failed to read plugins.json")
		return config, false
	}
	defer delete(data)

	// Parse as JSON5 (allows comments and trailing commas)
	json_err := json.unmarshal(data, &config, spec = .JSON5)
	if json_err != nil {
		fmt.eprintfln("Error: Failed to parse plugins.json: %v", json_err)
		return config, false
	}

	// plugins.json may be hand-edited or synced from a dotfiles repo, and
	// its values reach git argv, rm and the generated shell loader: reject
	// anything malformed instead of silently coercing or trusting it.
	if problem := plugin_json_resolve_enums(data, &config); problem != "" {
		fmt.eprintfln("Error: Invalid plugins.json: %s", problem)
		return config, false
	}
	if problem := validate_plugin_config_entries(&config); problem != "" {
		fmt.eprintfln("Error: Invalid plugins.json: %s", problem)
		return config, false
	}

	// Phase 4: Validate no circular dependencies on load
	if !validate_no_circular_dependencies(&config) {
		return config, false
	}

	return config, true
}

// Write JSON5 configuration file
write_plugin_config_json :: proc(config: ^PluginConfigJSON) -> bool {
	sync.lock(&_plugins_json_mutex)
	defer sync.unlock(&_plugins_json_mutex)

	// Free old last_updated before overwriting (it was allocated by get_iso8601_timestamp)
	if len(config.last_updated) > 0 {
		delete(config.last_updated)
	}
	config.last_updated = get_iso8601_timestamp()

	// Marshal to JSON5 with pretty printing
	marshal_options := json.Marshal_Options{
		pretty = true,
		use_spaces = true,
		spaces = 2,
		spec = .JSON5,
		// "shell": "ZSH" instead of "shell": 0 — readable when hand-edited
		// and still exactly what older wayu versions parse.
		use_enum_names = true,
	}

	data, marshal_err := json.marshal(config^, marshal_options)
	if marshal_err != nil {
		fmt.eprintfln("Error: Failed to marshal config: %v", marshal_err)
		return false
	}
	defer delete(data)

	config_file := get_plugins_json_config_file()
	defer delete(config_file)

	write_err := write_file_atomic(config_file, data)
	if write_err != nil {
		fmt.eprintln("Error: Failed to write plugins.json")
		return false
	}

	return true
}

// Migrate from old pipe-delimited format to JSON5
migrate_plugin_config :: proc() -> bool {
	old_file := get_plugins_config_file()
	defer delete(old_file)

	new_file := get_plugins_json_config_file()
	defer delete(new_file)

	// Skip if new file exists or old file doesn't exist
	if os.exists(new_file) || !os.exists(old_file) {
		return true
	}

	if wayu.dry_run {
		print_info("[DRY RUN] Would migrate plugins.conf to plugins.json")
		return true
	}

	print_info("Migrating plugins.conf to plugins.json...")

	// Read old config
	old_config := read_plugin_config()
	defer {
		for plugin in old_config.plugins {
			delete(plugin.name)
			delete(plugin.url)
			delete(plugin.installed_path)
			delete(plugin.entry_file)
		}
		delete(old_config.plugins)
	}

	// Convert to new format
	new_config := PluginConfigJSON{
		version = strings.clone("1.0"),
		last_updated = get_iso8601_timestamp(),
		plugins = make([dynamic]PluginMetadata),
	}
	defer cleanup_plugin_config_json(&new_config)

	for old_plugin in old_config.plugins {
		// Get git info for existing plugin
		git_info := get_git_info(old_plugin.installed_path)

		new_plugin := PluginMetadata{
			name = strings.clone(old_plugin.name),
			display_name = strings.clone(old_plugin.name),
			url = strings.clone(old_plugin.url),
			source_type = .GitHub,  // Default for migrated plugins
			enabled = old_plugin.enabled,
			shell = old_plugin.shell,
			installed_path = strings.clone(old_plugin.installed_path),
			entry_file = strings.clone(old_plugin.entry_file),
			use = make([dynamic]string),  // Empty = auto-detect
			template = .Source,  // Default template
			git = git_info,
			dependencies = make([dynamic]string),
			priority = 100, // Default priority
			profiles = make([dynamic]string),  // Empty = all profiles
			conflicts = ConflictInfo{
				env_vars = make([dynamic]string),
				functions = make([dynamic]string),
				aliases_ = make([dynamic]string),
				detected = false,
				conflicting_plugins = make([dynamic]string),
			},
		}

		append(&new_config.plugins, new_plugin)
	}

	// Write new config
	if !write_plugin_config_json(&new_config) {
		print_error_simple("Failed to write new configuration")
		return false
	}

	// Backup old config
	backup_file := fmt.aprintf("%s.backup", old_file)
	defer delete(backup_file)

	os.rename(old_file, backup_file)

	print_success("Migration complete! Old config backed up to plugins.conf.backup")
	return true
}

// Resolve one plugins.json enum value: an integer in range (the format wayu
// wrote up to 4.4.5) or a value name, case-insensitively ("zsh", "ZSH",
// "Both"). json.unmarshal maps unknown or differently-cased names to the
// zero value without an error, so enums are resolved here instead.
plugin_enum_from_json :: proc($E: typeid, v: json.Value) -> (E, bool) where intrinsics.type_is_enum(E) {
	#partial switch x in v {
	case json.Integer:
		for val in E {
			if i64(val) == x {
				return val, true
			}
		}
	case json.Float:
		for val in E {
			if f64(val) == x {
				return val, true
			}
		}
	case json.String:
		for val in E {
			if strings.equal_fold(reflect.enum_string(val), x) {
				return val, true
			}
		}
	}
	return {}, false
}

// Names of an enum's values, lowercase, comma-separated (temp allocated).
@(private="file")
plugin_enum_choices :: proc($E: typeid) -> string where intrinsics.type_is_enum(E) {
	sb := strings.builder_make(context.temp_allocator)
	first := true
	for val in E {
		if !first {
			strings.write_string(&sb, ", ")
		}
		first = false
		strings.write_string(&sb, strings.to_lower(reflect.enum_string(val), context.temp_allocator))
	}
	return strings.to_string(sb)
}

// Re-read the enum fields (shell, template, source_type, git.ref_type) from
// the raw document and store the resolved values in `config`. Returns "" on
// success, otherwise a description of the first invalid value (temp).
plugin_json_resolve_enums :: proc(data: []byte, config: ^PluginConfigJSON) -> string {
	root, perr := json.parse(data, spec = .JSON5, parse_integers = true)
	defer json.destroy_value(root)
	if perr != nil {
		return fmt.tprintf("parse error: %v", perr)
	}

	root_obj, is_obj := root.(json.Object)
	if !is_obj {
		return "top level must be an object"
	}
	plugins_val, has_plugins := root_obj["plugins"]
	if !has_plugins {
		return ""
	}
	plugins_arr, is_arr := plugins_val.(json.Array)
	if !is_arr || len(plugins_arr) != len(config.plugins) {
		return "\"plugins\" must be an array of objects"
	}

	for entry, i in plugins_arr {
		obj, ok := entry.(json.Object)
		if !ok {
			return fmt.tprintf("plugin #%d is not an object", i + 1)
		}
		p := &config.plugins[i]
		label := fmt.tprintf("plugin #%d ('%s')", i + 1, p.name)

		if v, has := obj["shell"]; has {
			val, vok := plugin_enum_from_json(ShellCompat, v)
			if !vok {
				return fmt.tprintf("%s: invalid shell %v (expected one of: %s)", label, v, plugin_enum_choices(ShellCompat))
			}
			p.shell = val
		}
		if v, has := obj["template"]; has {
			val, vok := plugin_enum_from_json(PluginLoadTemplate, v)
			if !vok {
				return fmt.tprintf("%s: invalid template %v (expected one of: %s)", label, v, plugin_enum_choices(PluginLoadTemplate))
			}
			p.template = val
		}
		if v, has := obj["source_type"]; has {
			val, vok := plugin_enum_from_json(PluginSourceType, v)
			if !vok {
				return fmt.tprintf("%s: invalid source_type %v (expected one of: %s)", label, v, plugin_enum_choices(PluginSourceType))
			}
			p.source_type = val
		}
		if git_v, has_git := obj["git"]; has_git {
			if git_obj, gok := git_v.(json.Object); gok {
				if v, has := git_obj["ref_type"]; has {
					val, vok := plugin_enum_from_json(GitRefType, v)
					if !vok {
						return fmt.tprintf("%s: invalid git.ref_type %v (expected one of: %s)", label, v, plugin_enum_choices(GitRefType))
					}
					p.git.ref_type = val
				}
			}
		}
	}
	return ""
}

// Validate the string fields of every plugin entry that reach git argv, the
// filesystem (rm, directory names) or the generated loader. Returns "" when
// all entries are valid, otherwise a description of the first problem (temp).
validate_plugin_config_entries :: proc(config: ^PluginConfigJSON) -> string {
	for &p, i in config.plugins {
		label := fmt.tprintf("plugin #%d ('%s')", i + 1, p.name)

		// An empty name/url is tolerated so a broken legacy entry can still
		// be listed and removed (removal is guarded by the plugins root).
		if len(p.name) > 0 && !is_valid_plugin_name(p.name) {
			return fmt.tprintf("%s: invalid name (must be a single path component, not starting with '-')", label)
		}
		if len(p.url) > 0 {
			if problem := plugin_url_problem(p.url); problem != "" {
				return fmt.tprintf("%s: invalid url: %s", label, problem)
			}
		}
		if strings.has_prefix(p.installed_path, "-") {
			return fmt.tprintf("%s: installed_path must not start with '-'", label)
		}
		for c in p.installed_path {
			if c < 0x20 || c == 0x7f {
				return fmt.tprintf("%s: installed_path contains control characters", label)
			}
		}
		// Dependency names are written into comments of the generated loader;
		// a newline in one would turn the rest of it into shell code.
		for dep in p.dependencies {
			if !is_valid_plugin_name(dep) {
				return fmt.tprintf("%s: invalid dependency name %q", label, dep)
			}
		}
		refs := [?]struct{field: string, value: string}{
			{"git.branch", p.git.branch},
			{"git.tag", p.git.tag},
			{"git.commit", p.git.commit},
			{"git.pinned_ref", p.git.pinned_ref},
		}
		for r in refs {
			if problem := plugin_ref_problem(r.value); problem != "" {
				return fmt.tprintf("%s: %s %s", label, r.field, problem)
			}
		}
	}
	return ""
}

// Git operations

// Clone plugin repository
