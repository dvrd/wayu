package wayu
import "base:intrinsics"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:reflect"
import "core:strings"
import "core:sync"
// Mutex to protect concurrent access to plugins.json
// Prevents race conditions when multiple threads read/write simultaneously
_plugins_json_mutex: sync.Mutex

// Get plugins JSON config file path
get_plugins_json_config_file :: proc() -> string {
	return fmt.aprintf("%s/plugins.json", wayu.data)
}

// Get plugins directory path
get_plugins_dir :: proc() -> string {
	return fmt.aprintf("%s/plugins", wayu.data)
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
	marshal_options := json.Marshal_Options {
		pretty         = true,
		use_spaces     = true,
		spaces         = 2,
		spec           = .JSON5,
		// "shell": "ZSH" instead of "shell": 0 — readable when hand-edited.
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

// Resolve one plugins.json enum value: a value name, case-insensitively
// ("zsh", "ZSH", "Both"); numbers are refused. json.unmarshal maps unknown or differently-cased names to the
// zero value without an error, so enums are resolved here instead.
plugin_enum_from_json :: proc(
	$E: typeid,
	v: json.Value,
) -> (
	E,
	bool,
) where intrinsics.type_is_enum(E) {
	#partial switch x in v {
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
@(private = "file")
plugin_enum_choices :: proc($E: typeid) -> string where intrinsics.type_is_enum(E) {
	sb := strings.builder_make(context.temp_allocator)
	first := true
	for val in E {
		if !first {
			strings.write_string(&sb, ", ")
		}
		first = false
		strings.write_string(
			&sb,
			strings.to_lower(reflect.enum_string(val), context.temp_allocator),
		)
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
				return fmt.tprintf(
					"%s: invalid shell %v (expected one of: %s)",
					label,
					v,
					plugin_enum_choices(ShellCompat),
				)
			}
			p.shell = val
		}
		if v, has := obj["template"]; has {
			val, vok := plugin_enum_from_json(PluginLoadTemplate, v)
			if !vok {
				return fmt.tprintf(
					"%s: invalid template %v (expected one of: %s)",
					label,
					v,
					plugin_enum_choices(PluginLoadTemplate),
				)
			}
			p.template = val
		}
		if v, has := obj["source_type"]; has {
			val, vok := plugin_enum_from_json(PluginSourceType, v)
			if !vok {
				return fmt.tprintf(
					"%s: invalid source_type %v (expected one of: %s)",
					label,
					v,
					plugin_enum_choices(PluginSourceType),
				)
			}
			p.source_type = val
		}
		if git_v, has_git := obj["git"]; has_git {
			if git_obj, gok := git_v.(json.Object); gok {
				if v, has := git_obj["ref_type"]; has {
					val, vok := plugin_enum_from_json(GitRefType, v)
					if !vok {
						return fmt.tprintf(
							"%s: invalid git.ref_type %v (expected one of: %s)",
							label,
							v,
							plugin_enum_choices(GitRefType),
						)
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
			return fmt.tprintf(
				"%s: invalid name (must be a single path component, not starting with '-')",
				label,
			)
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
		refs := [?]struct {
			field: string,
			value: string,
		} {
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
