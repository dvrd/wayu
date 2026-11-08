// config_specs.odin - Configuration entry specifications
//
// This module defines the ConfigEntrySpec instances for each config type
// (PATH, ALIAS, CONSTANTS). Each spec configures how that entry type should
// be parsed (legacy shell files), dispatched and displayed.

package wayu

import "core:strings"

// PATH entry specification (global variable, not constant - can't be constant with function pointers)
PATH_SPEC := ConfigEntrySpec{
	type = .PATH,
	file_name = "path",
	cli_name = "path",
	display_name = "PATH",
	icon = "📂",

	parse_line = parse_path_line,

	has_clean = true,
	has_dedup = true,
	fields_count = 1,

	field_labels = []string{"Path"},
	field_placeholders = []string{"/usr/local/bin"},
}

// ALIAS entry specification (global variable, not constant)
ALIAS_SPEC := ConfigEntrySpec{
	type = .ALIAS,
	file_name = "aliases",
	cli_name = "alias",
	display_name = "Alias",
	icon = "🔑",

	parse_line = parse_alias_line,

	has_clean = false,
	has_dedup = false,
	fields_count = 2,

	field_labels = []string{"Alias Name", "Command"},
	field_placeholders = []string{"ll", "ls -lah"},

	// TOML-first ops wired for the generic handle_toml_entry_command dispatcher.
	toml_add    = toml_alias_add,
	toml_remove = toml_alias_remove,
	toml_list   = list_toml_aliases,
	toml_get    = get_toml_alias_value,

	hook_pre_add     = hook_pre_alias_add,
	hook_post_add    = hook_post_alias_add,
	hook_pre_remove  = hook_pre_alias_remove,
	hook_post_remove = hook_post_alias_remove,

	// Aliases also display external source files (e.g. /etc/shell-aliases.sh)
	// underneath the native list output — run that epilogue after toml_list.
	list_epilogue = print_external_alias_sources,
}

// CONSTANTS entry specification (global variable, not constant)
CONSTANTS_SPEC := ConfigEntrySpec{
	type = .CONSTANT,
	file_name = "constants",
	cli_name = "const",
	display_name = "Constant",
	icon = "💾",

	parse_line = parse_constant_line,

	has_clean = false,
	has_dedup = false,
	fields_count = 2,

	field_labels = []string{"Variable Name", "Value"},
	field_placeholders = []string{"MY_VAR", "my_value"},

	// TOML-first ops wired for the generic handle_toml_entry_command dispatcher.
	toml_add    = toml_constant_add,
	toml_remove = toml_constant_remove,
	toml_list   = list_toml_constants,
	toml_get    = get_toml_constant_value,

	hook_pre_add     = hook_pre_constant_add,
	hook_post_add    = hook_post_constant_add,
	hook_pre_remove  = hook_pre_constant_remove,
	hook_post_remove = hook_post_constant_remove,
}

// ============================================================================
// PATH Validators, Formatters, and Parsers
// ============================================================================

// Validate PATH entry
validate_path_entry :: proc(entry: ConfigEntry) -> ValidationResult {
	// Validate path format using existing validation system
	// NOTE: This only validates format (not empty, no invalid chars)
	// Disk existence checks are intentionally NOT performed here
	return validate_path(entry.name)
}

// Parse PATH line: extract path from array element "..."
parse_path_line :: proc(line: string) -> (ConfigEntry, bool) {
	trimmed := strings.trim_space(line)

	// bash/zsh wayu-legacy form: "path" inside WAYU_PATHS=(...)
	if strings.has_prefix(trimmed, `"`) && strings.has_suffix(trimmed, `"`) && len(trimmed) >= 2 {
		path := trimmed[1:len(trimmed)-1]
		return ConfigEntry{
			type = .PATH,
			name = strings.clone(path),
			value = "",
			line  = strings.clone(line),
		}, true
	}

	// fish form: fish_add_path /some/dir
	if strings.has_prefix(trimmed, "fish_add_path ") {
		rest := strings.trim_space(trimmed[len("fish_add_path "):])
		// skip leading flags like -g, -p
		for strings.has_prefix(rest, "-") {
			sp := strings.index_byte(rest, ' ')
			if sp == -1 { return {}, false }
			rest = strings.trim_space(rest[sp+1:])
		}
		if len(rest) == 0 { return {}, false }
		if len(rest) >= 2 {
			first := rest[0]
			last := rest[len(rest)-1]
			if (first == '\'' || first == '"') && first == last {
				rest = rest[1:len(rest)-1]
			}
		}
		return ConfigEntry{
			type = .PATH,
			name = strings.clone(rest),
			value = "",
			line  = strings.clone(line),
		}, true
	}

	return {}, false
}

// ============================================================================
// ALIAS Validators, Formatters, and Parsers
// ============================================================================

// Parse ALIAS line: extract name and command from alias name="..."
parse_alias_line :: proc(line: string) -> (ConfigEntry, bool) {
	trimmed := strings.trim_space(line)

	if !strings.has_prefix(trimmed, "alias ") {
		return {}, false
	}

	// bash/zsh form: alias name="command"
	if eq_idx := strings.index(trimmed, "="); eq_idx != -1 {
		name := strings.trim_space(trimmed[6:eq_idx])
		if len(name) == 0 { return {}, false }
		rest := trimmed[eq_idx+1:]
		start := strings.index(rest, `"`)
		if start == -1 { return {}, false }
		end := strings.last_index(rest, `"`)
		if end == -1 || end <= start { return {}, false }
		command := rest[start+1:end]
		return ConfigEntry{
			type  = .ALIAS,
			name  = strings.clone(name),
			value = strings.clone(command),
			line  = strings.clone(line),
		}, true
	}

	// fish form: alias name 'command'  (or "command")
	rest := strings.trim_space(trimmed[6:])
	sp := strings.index_byte(rest, ' ')
	if sp <= 0 { return {}, false }
	name := rest[:sp]
	cmd := strings.trim_space(rest[sp+1:])
	if len(cmd) >= 2 {
		first := cmd[0]
		last := cmd[len(cmd)-1]
		if (first == '\'' || first == '"') && first == last {
			cmd = cmd[1:len(cmd)-1]
		}
	}
	return ConfigEntry{
		type  = .ALIAS,
		name  = strings.clone(name),
		value = strings.clone(cmd),
		line  = strings.clone(line),
	}, true
}

// ============================================================================
// CONSTANTS Validators, Formatters, and Parsers
// ============================================================================

// Parse CONSTANT line: extract name and value from export NAME="..."
parse_constant_line :: proc(line: string) -> (ConfigEntry, bool) {
	trimmed := strings.trim_space(line)

	// bash/zsh form: export NAME="value"
	if strings.has_prefix(trimmed, "export ") {
		eq_idx := strings.index(trimmed, "=")
		if eq_idx == -1 { return {}, false }
		name := strings.trim_space(trimmed[7:eq_idx])
		if len(name) == 0 { return {}, false }
		rest := trimmed[eq_idx+1:]
		start := strings.index(rest, `"`)
		if start == -1 { return {}, false }
		end := strings.last_index(rest, `"`)
		if end == -1 || end <= start { return {}, false }
		value := rest[start+1:end]
		return ConfigEntry{
			type  = .CONSTANT,
			name  = strings.clone(name),
			value = strings.clone(value),
			line  = strings.clone(line),
		}, true
	}

	// fish form: set -gx NAME value   (also -g, -Ux, -U)
	if strings.has_prefix(trimmed, "set ") {
		rest := strings.trim_space(trimmed[4:])
		// Skip flags (tokens starting with '-')
		for strings.has_prefix(rest, "-") {
			sp := strings.index_byte(rest, ' ')
			if sp == -1 { return {}, false }
			rest = strings.trim_space(rest[sp+1:])
		}
		sp := strings.index_byte(rest, ' ')
		if sp <= 0 { return {}, false }
		name := rest[:sp]
		if name == "PATH" || name == "fish_user_paths" { return {}, false }
		value := strings.trim_space(rest[sp+1:])
		if len(value) >= 2 {
			first := value[0]
			last := value[len(value)-1]
			if (first == '\'' || first == '"') && first == last {
				value = value[1:len(value)-1]
			}
		}
		return ConfigEntry{
			type  = .CONSTANT,
			name  = strings.clone(name),
			value = strings.clone(value),
			line  = strings.clone(line),
		}, true
	}

	return {}, false
}
