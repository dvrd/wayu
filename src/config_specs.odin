// config_specs.odin - Configuration entry specifications
//
// This module defines the ConfigEntrySpec instances for each config type
// (PATH, ALIAS, CONSTANTS). Each spec configures how that entry type should
// be validated, formatted, parsed, and displayed.

package wayu

import "core:fmt"
import "core:os"
import "core:strings"

// PATH entry specification (global variable, not constant - can't be constant with function pointers)
PATH_SPEC := ConfigEntrySpec{
	type = .PATH,
	file_name = "path",
	line_prefix = "add_to_path",
	display_name = "PATH",
	icon = "📂",

	validator = validate_path_entry,
	format_line = format_path_line,
	parse_line = parse_path_line,

	has_clean = true,
	has_dedup = true,
	fields_count = 1,

	field_labels = []string{"Path"},
	field_placeholders = []string{"/usr/local/bin"},
	field_validators = []proc(string) -> InputValidation{validate_path_input},
}

// ALIAS entry specification (global variable, not constant)
ALIAS_SPEC := ConfigEntrySpec{
	type = .ALIAS,
	file_name = "aliases",
	line_prefix = "alias",
	display_name = "Alias",
	icon = "🔑",

	validator = validate_alias_entry,
	format_line = format_alias_line,
	parse_line = parse_alias_line,

	has_clean = false,
	has_dedup = false,
	fields_count = 2,

	field_labels = []string{"Alias Name", "Command"},
	field_placeholders = []string{"ll", "ls -lah"},
	field_validators = []proc(string) -> InputValidation{
		validate_alias_name_input,
		validate_alias_command_input,
	},
}

// CONSTANTS entry specification (global variable, not constant)
CONSTANTS_SPEC := ConfigEntrySpec{
	type = .CONSTANT,
	file_name = "constants",
	line_prefix = "export",
	display_name = "Constant",
	icon = "💾",

	validator = validate_constant_entry,
	format_line = format_constant_line,
	parse_line = parse_constant_line,

	has_clean = false,
	has_dedup = false,
	fields_count = 2,

	field_labels = []string{"Variable Name", "Value"},
	field_placeholders = []string{"MY_VAR", "my_value"},
	field_validators = []proc(string) -> InputValidation{
		validate_constant_name_input,
		validate_constant_value_input,
	},
}

// ============================================================================
// PATH Validators, Formatters, and Parsers
// ============================================================================

// Validate PATH entry
validate_path_entry :: proc(entry: ConfigEntry) -> ValidationResult {
	// Validate path format using existing validation system
	result := validate_path(entry.name)
	if !result.valid {
		return result
	}

	// Check if path exists (expand env vars first)
	expanded := expand_env_vars(entry.name)
	defer delete(expanded)

	if !os.exists(expanded) {
		return ValidationResult{
			valid = false,
			error_message = fmt.aprintf("Path does not exist: %s", entry.name),
		}
	}

	return ValidationResult{valid = true, error_message = ""}
}

// Format PATH line: add_to_path "/path/to/dir"
format_path_line :: proc(entry: ConfigEntry) -> string {
	return fmt.aprintf(`add_to_path "%s"`, entry.name)
}

// Parse PATH line: extract path from add_to_path "..."
parse_path_line :: proc(line: string) -> (ConfigEntry, bool) {
	trimmed := strings.trim_space(line)

	if !strings.has_prefix(trimmed, "add_to_path") {
		return {}, false
	}

	// Find quoted path
	start := strings.index(trimmed, `"`)
	if start == -1 { return {}, false }

	end := strings.last_index(trimmed, `"`)
	if end == -1 || end <= start { return {}, false }

	path := trimmed[start+1:end]

	entry := ConfigEntry{
		type = .PATH,
		name = strings.clone(path),
		value = "",
		line = strings.clone(line),
	}

	return entry, true
}

// Validate path input for interactive mode
validate_path_input :: proc(value: string) -> InputValidation {
	if len(value) == 0 {
		return InputValidation{
			valid = false,
			error_message = "",
			warning = "",
			info = "",
		}
	}

	result := validate_path(value)

	if !result.valid {
		return InputValidation{
			valid = false,
			error_message = strings.clone(result.error_message),
			warning = "",
			info = "",
		}
	}

	return InputValidation{
		valid = true,
		error_message = "",
		warning = "",
		info = "",
	}
}

// ============================================================================
// ALIAS Validators, Formatters, and Parsers
// ============================================================================

// Validate ALIAS entry
validate_alias_entry :: proc(entry: ConfigEntry) -> ValidationResult {
	// Use existing validate_alias function which takes both name and command
	return validate_alias(entry.name, entry.value)
}

// Format ALIAS line: alias name="command"
format_alias_line :: proc(entry: ConfigEntry) -> string {
	// Escape quotes in command (strings.replace_all returns 2 values: result and allocation count)
	escaped_cmd, _ := strings.replace_all(entry.value, `"`, `\"`)
	defer delete(escaped_cmd)

	return fmt.aprintf(`alias %s="%s"`, entry.name, escaped_cmd)
}

// Parse ALIAS line: extract name and command from alias name="..."
parse_alias_line :: proc(line: string) -> (ConfigEntry, bool) {
	trimmed := strings.trim_space(line)

	if !strings.has_prefix(trimmed, "alias ") {
		return {}, false
	}

	// Find equals sign
	eq_idx := strings.index(trimmed, "=")
	if eq_idx == -1 { return {}, false }

	// Extract name (between "alias " and "=")
	name := strings.trim_space(trimmed[6:eq_idx])
	if len(name) == 0 { return {}, false }

	// Extract command (after "=" and inside quotes)
	rest := trimmed[eq_idx+1:]
	start := strings.index(rest, `"`)
	if start == -1 { return {}, false }

	end := strings.last_index(rest, `"`)
	if end == -1 || end <= start { return {}, false }

	command := rest[start+1:end]

	entry := ConfigEntry{
		type = .ALIAS,
		name = strings.clone(name),
		value = strings.clone(command),
		line = strings.clone(line),
	}

	return entry, true
}

// Validate alias name input
validate_alias_name_input :: proc(value: string) -> InputValidation {
	if len(value) == 0 {
		return InputValidation{
			valid = false,
			error_message = "",
			warning = "",
			info = "",
		}
	}

	// Use existing validate_identifier function
	result := validate_identifier(value, "Alias")

	if !result.valid {
		return InputValidation{
			valid = false,
			error_message = strings.clone(result.error_message),
			warning = "",
			info = "",
		}
	}

	return InputValidation{
		valid = true,
		error_message = "",
		warning = "",
		info = "",
	}
}

// Validate alias command input
validate_alias_command_input :: proc(value: string) -> InputValidation {
	if len(value) == 0 {
		return InputValidation{
			valid = false,
			error_message = "",
			warning = "",
			info = "",
		}
	}

	// Command just needs to be non-empty (trimmed)
	trimmed := strings.trim_space(value)
	if len(trimmed) == 0 {
		return InputValidation{
			valid = false,
			error_message = strings.clone("Command cannot be empty"),
			warning = "",
			info = "",
		}
	}

	return InputValidation{
		valid = true,
		error_message = "",
		warning = "",
		info = "",
	}
}

// ============================================================================
// CONSTANTS Validators, Formatters, and Parsers
// ============================================================================

// Validate CONSTANT entry
validate_constant_entry :: proc(entry: ConfigEntry) -> ValidationResult {
	// Use existing validate_constant function which takes both name and value
	return validate_constant(entry.name, entry.value)
}

// Format CONSTANT line: export NAME="value"
format_constant_line :: proc(entry: ConfigEntry) -> string {
	// Escape quotes in value (strings.replace_all returns 2 values)
	escaped_value, _ := strings.replace_all(entry.value, `"`, `\"`)
	defer delete(escaped_value)

	return fmt.aprintf(`export %s="%s"`, entry.name, escaped_value)
}

// Parse CONSTANT line: extract name and value from export NAME="..."
parse_constant_line :: proc(line: string) -> (ConfigEntry, bool) {
	trimmed := strings.trim_space(line)

	if !strings.has_prefix(trimmed, "export ") {
		return {}, false
	}

	// Find equals sign
	eq_idx := strings.index(trimmed, "=")
	if eq_idx == -1 { return {}, false }

	// Extract name (between "export " and "=")
	name := strings.trim_space(trimmed[7:eq_idx])
	if len(name) == 0 { return {}, false }

	// Extract value (after "=" and inside quotes)
	rest := trimmed[eq_idx+1:]
	start := strings.index(rest, `"`)
	if start == -1 { return {}, false }

	end := strings.last_index(rest, `"`)
	if end == -1 || end <= start { return {}, false }

	value := rest[start+1:end]

	entry := ConfigEntry{
		type = .CONSTANT,
		name = strings.clone(name),
		value = strings.clone(value),
		line = strings.clone(line),
	}

	return entry, true
}

// Validate constant name input
validate_constant_name_input :: proc(value: string) -> InputValidation {
	if len(value) == 0 {
		return InputValidation{
			valid = false,
			error_message = "",
			warning = "",
			info = "",
		}
	}

	// Use existing validate_identifier function
	result := validate_identifier(value, "Constant")

	if !result.valid {
		return InputValidation{
			valid = false,
			error_message = strings.clone(result.error_message),
			warning = "",
			info = "",
		}
	}

	// Check for lowercase warning
	has_lower := false
	for c in value {
		if c >= 'a' && c <= 'z' {
			has_lower = true
			break
		}
	}

	if has_lower {
		return InputValidation{
			valid = true,
			error_message = "",
			warning = strings.clone("Convention: use UPPER_CASE for constants"),
			info = "",
		}
	}

	return InputValidation{
		valid = true,
		error_message = "",
		warning = "",
		info = "",
	}
}

// Validate constant value input
validate_constant_value_input :: proc(value: string) -> InputValidation {
	if len(value) == 0 {
		return InputValidation{
			valid = false,
			error_message = "",
			warning = "",
			info = "",
		}
	}

	// Value just needs to be non-empty for interactive input
	// Full validation happens during submit
	return InputValidation{
		valid = true,
		error_message = "",
		warning = "",
		info = "",
	}
}
