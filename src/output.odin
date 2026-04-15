// output.odin - JSON and YAML output formatting for wayu
//
// This module provides JSON/YAML serialization for wayu configuration data.
// It implements the interfaces defined in interfaces.odin for structured output.

package wayu

import "core:fmt"
import "core:os"
import "core:strings"

// ============================================================================
// OUTPUT FORMAT STATE
// ============================================================================

g_output_format: OutputFormat = .Plain

// Set the current output format
output_format_set :: proc(format: OutputFormat) {
	g_output_format = format
}

// Get the current output format
output_get_current_format :: proc() -> OutputFormat {
	return g_output_format
}

// ============================================================================
// JSON SERIALIZATION - Basic implementation for wayu types
// ============================================================================

// Convert any data to compact JSON string
output_to_json :: proc(data: any) -> string {
	// For now, implement a simple JSON formatter for common wayu types
	// This is a basic implementation that handles the core data structures
	return json_format_simple(data, false)
}

// Convert any data to pretty-printed JSON string
output_to_json_pretty :: proc(data: any) -> string {
	return json_format_simple(data, true)
}

// Parse JSON string into target data structure (basic stub)
output_from_json :: proc(json_str: string, target: ^any) -> bool {
	// Basic stub implementation - would need a full JSON parser
	return false
}

// ============================================================================
// YAML SERIALIZATION
// ============================================================================

// Convert any data to YAML string
output_to_yaml :: proc(data: any) -> string {
	// For now, return pretty JSON as YAML-compatible format
	return output_to_json_pretty(data)
}

// ============================================================================
// INTERNAL JSON FORMATTER
// ============================================================================

@(private="file")
json_format_simple :: proc(data: any, pretty: bool) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	json_format_value(&builder, data, pretty, 0)

	return strings.clone(strings.to_string(builder))
}

@(private="file")
json_format_value :: proc(builder: ^strings.Builder, data: any, pretty: bool, indent: int) {
	if data.data == nil {
		strings.write_string(builder, "null")
		return
	}

	// Use typeid to determine how to format
	tid := data.id

	// Check for ConfigType first (before other types) - use type assertion
	if config_type, ok := data.(^ConfigType); ok {
		strings.write_string(builder, "\"")
		strings.write_string(builder, config_type_to_string(config_type^))
		strings.write_string(builder, "\"")
		return
	}

	// Check for specific known types using type assertions (more reliable than typeid)
	// This works correctly across package boundaries
	if path_entry_list, ok := data.(^PathEntryList); ok {
		format_path_entry_list(builder, path_entry_list, pretty, indent)
	} else if path_entry, ok := data.(^PathEntry); ok {
		format_path_entry(builder, path_entry, pretty, indent)
	} else if alias_list, ok := data.(^AliasList); ok {
		format_alias_list(builder, alias_list, pretty, indent)
	} else if alias_entry, ok := data.(^AliasEntry); ok {
		format_alias_entry(builder, alias_entry, pretty, indent)
	} else if constant_list, ok := data.(^ConstantList); ok {
		format_constant_list(builder, constant_list, pretty, indent)
	} else if constant_entry, ok := data.(^ConstantEntry); ok {
		format_constant_entry(builder, constant_entry, pretty, indent)
	} else if lock_file, ok := data.(^LockFile); ok {
		format_lock_file_json(builder, lock_file, pretty, indent)
	} else if lock_entry, ok := data.(^LockEntry); ok {
		format_lock_entry_json(builder, lock_entry, pretty, indent)
	} else if verification_result, ok := data.(^VerificationResult); ok {
		format_verification_result(builder, verification_result, pretty, indent)
	} else if str, ok := data.(^string); ok {
		strings.write_byte(builder, '"')
		json_escape_string_builder(builder, str^)
		strings.write_byte(builder, '"')
	} else if i, ok := data.(^int); ok {
		fmt.sbprintf(builder, "%d", i^)
	} else if i32_val, ok := data.(^i32); ok {
		fmt.sbprintf(builder, "%d", i32_val^)
	} else if i64_val, ok := data.(^i64); ok {
		fmt.sbprintf(builder, "%d", i64_val^)
	} else if b, ok := data.(^bool); ok {
		if b^ {
			strings.write_string(builder, "true")
		} else {
			strings.write_string(builder, "false")
		}
	} else {
		// Unknown type - output null
		strings.write_string(builder, "null")
	}
}

// ============================================================================
// TYPE-SPECIFIC FORMATTERS
// ============================================================================

@(private="file")
format_path_entry_list :: proc(builder: ^strings.Builder, list: ^PathEntryList, pretty: bool, indent: int) {
	strings.write_byte(builder, '{')
	if pretty {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent + 2)
	}

	strings.write_string(builder, `"entries": `)

	// Format entries array
	strings.write_byte(builder, '[')
	if pretty && len(list.entries) > 0 {
		strings.write_byte(builder, '\n')
	}

	for i := 0; i < len(list.entries); i += 1 {
		if i > 0 {
			strings.write_string(builder, ",")
			if pretty {
				strings.write_byte(builder, '\n')
			}
		}
		if pretty {
			write_indent(builder, indent + 4)
		}
		json_format_value(builder, &list.entries[i], pretty, indent + 4)
	}

	if pretty && len(list.entries) > 0 {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent + 2)
	}
	strings.write_byte(builder, ']')

	// Add count field
	strings.write_string(builder, ",")
	if pretty {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent + 2)
	}
	fmt.sbprintf(builder, `"count": %d`, list.count)

	if pretty {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent)
	}
	strings.write_byte(builder, '}')
}

@(private="file")
format_path_entry :: proc(builder: ^strings.Builder, entry: ^PathEntry, pretty: bool, indent: int) {
	strings.write_byte(builder, '{')
	if pretty {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent + 2)
	}

	fmt.sbprintf(builder, `"path": "%s",`, entry.path)

	if pretty {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent + 2)
	}
	fmt.sbprintf(builder, `"expanded": "%s",`, entry.expanded)

	if pretty {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent + 2)
	}
	fmt.sbprintf(builder, `"exists": %v`, entry.exists)

	if pretty {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent)
	}
	strings.write_byte(builder, '}')
}

@(private="file")
format_alias_list :: proc(builder: ^strings.Builder, list: ^AliasList, pretty: bool, indent: int) {
	strings.write_byte(builder, '{')
	if pretty {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent + 2)
	}

	strings.write_string(builder, `"aliases": `)

	// Format aliases array
	strings.write_byte(builder, '[')
	if pretty && len(list.aliases) > 0 {
		strings.write_byte(builder, '\n')
	}

	for i := 0; i < len(list.aliases); i += 1 {
		if i > 0 {
			strings.write_string(builder, ",")
			if pretty {
				strings.write_byte(builder, '\n')
			}
		}
		if pretty {
			write_indent(builder, indent + 4)
		}
		json_format_value(builder, &list.aliases[i], pretty, indent + 4)
	}

	if pretty && len(list.aliases) > 0 {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent + 2)
	}
	strings.write_byte(builder, ']')

	// Add count field
	strings.write_string(builder, ",")
	if pretty {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent + 2)
	}
	fmt.sbprintf(builder, `"count": %d`, list.count)

	if pretty {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent)
	}
	strings.write_byte(builder, '}')
}

@(private="file")
format_alias_entry :: proc(builder: ^strings.Builder, entry: ^AliasEntry, pretty: bool, indent: int) {
	strings.write_byte(builder, '{')
	if pretty {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent + 2)
	}

	fmt.sbprintf(builder, `"name": "%s",`, entry.name)

	if pretty {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent + 2)
	}
	fmt.sbprintf(builder, `"command": "%s"`, entry.command)

	if pretty {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent)
	}
	strings.write_byte(builder, '}')
}

@(private="file")
format_constant_list :: proc(builder: ^strings.Builder, list: ^ConstantList, pretty: bool, indent: int) {
	if list == nil {
		strings.write_string(builder, `{"constants": [], "count": 0}`)
		return
	}

	strings.write_byte(builder, '{')
	if pretty {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent + 2)
	}

	strings.write_string(builder, `"constants": `)

	// Format constants array
	strings.write_byte(builder, '[')
	if pretty && len(list.constants) > 0 {
		strings.write_byte(builder, '\n')
	}

	for i := 0; i < len(list.constants); i += 1 {
		if i > 0 {
			strings.write_string(builder, ",")
			if pretty {
				strings.write_byte(builder, '\n')
			}
		}
		if pretty {
			write_indent(builder, indent + 4)
		}
		json_format_value(builder, &list.constants[i], pretty, indent + 4)
	}

	if pretty && len(list.constants) > 0 {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent + 2)
	}
	strings.write_byte(builder, ']')

	// Add count field
	strings.write_string(builder, ",")
	if pretty {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent + 2)
	}
	fmt.sbprintf(builder, `"count": %d`, list.count)

	if pretty {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent)
	}
	strings.write_byte(builder, '}')
}

@(private="file")
format_constant_entry :: proc(builder: ^strings.Builder, entry: ^ConstantEntry, pretty: bool, indent: int) {
	if entry == nil {
		strings.write_string(builder, "null")
		return
	}

	strings.write_byte(builder, '{')
	if pretty {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent + 2)
	}

	fmt.sbprintf(builder, `"name": "%s",`, entry.name)

	if pretty {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent + 2)
	}
	fmt.sbprintf(builder, `"value": "%s",`, entry.value)

	if pretty {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent + 2)
	}
	if entry.export {
		strings.write_string(builder, `"export": true`)
	} else {
		strings.write_string(builder, `"export": false`)
	}

	if pretty {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent)
	}
	strings.write_byte(builder, '}')
}

@(private="file")
format_lock_file_json :: proc(builder: ^strings.Builder, lock: ^LockFile, pretty: bool, indent: int) {
	strings.write_byte(builder, '{')
	if pretty {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent + 2)
	}

	fmt.sbprintf(builder, `"version": "%s",`, lock.version)

	if pretty {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent + 2)
	}
	fmt.sbprintf(builder, `"generated_at": "%s",`, lock.generated_at)

	if pretty {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent + 2)
	}
	strings.write_string(builder, `"entries": `)

	// Format entries array
	strings.write_byte(builder, '[')
	if pretty && len(lock.entries) > 0 {
		strings.write_byte(builder, '\n')
	}

	for i := 0; i < len(lock.entries); i += 1 {
		if i > 0 {
			strings.write_string(builder, ",")
			if pretty {
				strings.write_byte(builder, '\n')
			}
		}
		if pretty {
			write_indent(builder, indent + 4)
		}
		format_lock_entry_json(builder, &lock.entries[i], pretty, indent + 4)
	}

	if pretty && len(lock.entries) > 0 {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent + 2)
	}
	strings.write_byte(builder, ']')

	if pretty {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent)
	}
	strings.write_byte(builder, '}')
}

@(private="file")
format_lock_entry_json :: proc(builder: ^strings.Builder, entry: ^LockEntry, pretty: bool, indent: int) {
	strings.write_byte(builder, '{')
	if pretty {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent + 2)
	}

	fmt.sbprintf(builder, `"type": "%s",`, config_type_to_string(entry.type))

	if pretty {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent + 2)
	}
	fmt.sbprintf(builder, `"name": "%s",`, entry.name)

	if pretty {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent + 2)
	}
	fmt.sbprintf(builder, `"hash": "%s",`, entry.hash)

	if pretty {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent + 2)
	}
	fmt.sbprintf(builder, `"source": "%s",`, entry.source)

	if len(entry.value) > 0 {
		if pretty {
			strings.write_byte(builder, '\n')
			write_indent(builder, indent + 2)
		}
		fmt.sbprintf(builder, `"value": "%s",`, entry.value)
	}

	if pretty {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent + 2)
	}
	fmt.sbprintf(builder, `"added_at": "%s",`, entry.added_at)

	if pretty {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent + 2)
	}
	fmt.sbprintf(builder, `"modified_at": "%s"`, entry.modified_at)

	if pretty {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent)
	}
	strings.write_byte(builder, '}')
}

@(private="file")
format_verification_result :: proc(builder: ^strings.Builder, result: ^VerificationResult, pretty: bool, indent: int) {
	strings.write_byte(builder, '{')
	if pretty {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent + 2)
	}

	fmt.sbprintf(builder, `"valid": %v,`, result.valid)

	if pretty {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent + 2)
	}
	fmt.sbprintf(builder, `"passed": %d,`, result.passed)

	if pretty {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent + 2)
	}
	fmt.sbprintf(builder, `"failed": %d,`, result.failed)

	if pretty {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent + 2)
	}
	fmt.sbprintf(builder, `"missing": %d,`, result.missing)

	if pretty {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent + 2)
	}
	fmt.sbprintf(builder, `"extra": %d`, result.extra)

	if pretty {
		strings.write_byte(builder, '\n')
		write_indent(builder, indent)
	}
	strings.write_byte(builder, '}')
}

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================

@(private="file")
write_indent :: proc(builder: ^strings.Builder, spaces: int) {
	for i := 0; i < spaces; i += 1 {
		strings.write_byte(builder, ' ')
	}
}

@(private="file")
json_escape_string_builder :: proc(builder: ^strings.Builder, str: string) {
	for r in str {
		switch r {
		case '"':
			strings.write_string(builder, `\"`)
		case '\\':
			strings.write_string(builder, `\\`)
		case '\n':
			strings.write_string(builder, `\n`)
		case '\t':
			strings.write_string(builder, `\t`)
		case:
			if r < 0x20 {
				fmt.sbprintf(builder, "\\u%04x", r)
			} else {
				strings.write_rune(builder, r)
			}
		}
	}
}

@(private="file")
config_type_to_string :: proc(t: ConfigType) -> string {
	switch t {
	case .PATH:        return "PATH"
	case .ALIAS:       return "ALIAS"
	case .CONSTANT:    return "CONSTANT"
	case .PLUGIN:      return "PLUGIN"
	case .COMPLETION:  return "COMPLETION"
	}
	return "unknown"
}

// ============================================================================
// WAYU-SPECIFIC OUTPUT FORMATTERS
// ============================================================================

// PathEntryList represents a list of PATH entries for JSON output
PathEntryList :: struct {
	entries: []PathEntry,
	count:   int,
}

// PathEntry represents a single PATH entry
PathEntry :: struct {
	path:     string,
	expanded: string,
	exists:   bool,
}

// AliasList represents a list of aliases for JSON output
AliasList :: struct {
	aliases: []AliasEntry,
	count:   int,
}

// AliasEntry represents a single alias
AliasEntry :: struct {
	name:    string,
	command: string,
}

// ConstantList represents a list of constants for JSON output
ConstantList :: struct {
	constants: []ConstantEntry,
	count:     int,
}

// ConstantEntry represents a single constant
ConstantEntry :: struct {
	name:   string,
	value:  string,
	export: bool,
}

// Format PATH entries for JSON output
format_path_list_json :: proc(entries: []ConfigEntry) -> string {
	path_entries := make([]PathEntry, len(entries))
	defer delete(path_entries)

	for entry, i in entries {
		expanded := expand_env_vars(entry.name)
		defer delete(expanded)

		path_entries[i] = PathEntry{
			path     = entry.name,
			expanded = expanded,
			exists   = os.exists(expanded),
		}
	}

	list := PathEntryList{
		entries = path_entries,
		count   = len(entries),
	}

	return output_to_json(&list)
}

// Format PATH entries for pretty JSON output
format_path_list_json_pretty :: proc(entries: []ConfigEntry) -> string {
	path_entries := make([]PathEntry, len(entries))
	defer delete(path_entries)

	for entry, i in entries {
		expanded := expand_env_vars(entry.name)
		defer delete(expanded)

		path_entries[i] = PathEntry{
			path     = entry.name,
			expanded = expanded,
			exists   = os.exists(expanded),
		}
	}

	list := PathEntryList{
		entries = path_entries,
		count   = len(entries),
	}

	return output_to_json_pretty(&list)
}

// Format aliases for JSON output
format_alias_list_json :: proc(entries: []ConfigEntry) -> string {
	alias_entries := make([]AliasEntry, len(entries))
	defer delete(alias_entries)

	for entry, i in entries {
		alias_entries[i] = AliasEntry{
			name    = entry.name,
			command = entry.value,
		}
	}

	list := AliasList{
		aliases = alias_entries,
		count   = len(entries),
	}

	return output_to_json(&list)
}

// Format aliases for pretty JSON output
format_alias_list_json_pretty :: proc(entries: []ConfigEntry) -> string {
	alias_entries := make([]AliasEntry, len(entries))
	defer delete(alias_entries)

	for entry, i in entries {
		alias_entries[i] = AliasEntry{
			name    = entry.name,
			command = entry.value,
		}
	}

	list := AliasList{
		aliases = alias_entries,
		count   = len(entries),
	}

	return output_to_json_pretty(&list)
}

// Format constants for JSON output
format_constant_list_json :: proc(entries: []ConfigEntry) -> string {
	const_entries := make([]ConstantEntry, len(entries))
	defer delete(const_entries)

	for entry, i in entries {
		// Check if it starts with export to determine if it's exported
		is_export := strings.has_prefix(strings.trim_space(entry.line), "export")

		const_entries[i] = ConstantEntry{
			name   = entry.name,
			value  = entry.value,
			export = is_export,
		}
	}

	list := ConstantList{
		constants = const_entries,
		count     = len(entries),
	}

	return output_to_json(&list)
}

// Format constants for pretty JSON output
format_constant_list_json_pretty :: proc(entries: []ConfigEntry) -> string {
	const_entries := make([]ConstantEntry, len(entries))
	defer delete(const_entries)

	for entry, i in entries {
		// Check if it starts with export to determine if it's exported
		is_export := strings.has_prefix(strings.trim_space(entry.line), "export")

		const_entries[i] = ConstantEntry{
			name   = entry.name,
			value  = entry.value,
			export = is_export,
		}
	}

	list := ConstantList{
		constants = const_entries,
		count     = len(entries),
	}

	return output_to_json_pretty(&list)
}

// Format a single constant value for JSON output (used by 'const get NAME --json')
format_constant_get_json :: proc(name: string, value: string, is_export: bool) -> string {
	entry := ConstantEntry{
		name   = name,
		value  = value,
		export = is_export,
	}
	return output_to_json(&entry)
}

// Format a single constant value for pretty JSON output
format_constant_get_json_pretty :: proc(name: string, value: string, is_export: bool) -> string {
	entry := ConstantEntry{
		name   = name,
		value  = value,
		export = is_export,
	}
	return output_to_json_pretty(&entry)
}

// Format lock file as JSON for 'wayu lock --json' output
format_lock_file_json_output :: proc(lock: ^LockFile) -> string {
	return output_to_json(lock)
}

// Format verification result as JSON
format_verification_result_json :: proc(result: ^VerificationResult) -> string {
	return output_to_json(result)
}
