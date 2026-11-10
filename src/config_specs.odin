// config_specs.odin - Configuration entry specifications
//
// This module defines the ConfigEntrySpec instances for each config type
// (PATH, ALIAS, CONSTANTS). Each spec configures how that entry type is
// dispatched and displayed.

package wayu


// PATH entry specification (global variable, not constant - can't be constant with function pointers)
PATH_SPEC := ConfigEntrySpec {
	type               = .PATH,
	cli_name           = "path",
	display_name       = "PATH",
	icon               = "📂",
	has_clean          = true,
	has_dedup          = true,
	fields_count       = 1,
	field_labels       = []string{"Path"},
	field_placeholders = []string{"/usr/local/bin"},
}

// ALIAS entry specification (global variable, not constant)
ALIAS_SPEC := ConfigEntrySpec {
	type               = .ALIAS,
	cli_name           = "alias",
	display_name       = "Alias",
	icon               = "🔑",
	has_clean          = false,
	has_dedup          = false,
	fields_count       = 2,
	field_labels       = []string{"Alias Name", "Command"},
	field_placeholders = []string{"ll", "ls -lah"},

	// TOML-first ops wired for the generic handle_toml_entry_command dispatcher.
	toml_add           = toml_alias_add,
	toml_remove        = toml_alias_remove,
	toml_list          = list_toml_aliases,
	toml_get           = get_toml_alias_value,
	hook_pre_add       = hook_pre_alias_add,
	hook_post_add      = hook_post_alias_add,
	hook_pre_remove    = hook_pre_alias_remove,
	hook_post_remove   = hook_post_alias_remove,

	// Aliases also display external source files (e.g. /etc/shell-aliases.sh)
	// underneath the native list output — run that epilogue after toml_list.
	list_epilogue      = print_external_alias_sources,
}

// CONSTANTS entry specification (global variable, not constant)
CONSTANTS_SPEC := ConfigEntrySpec {
	type               = .CONSTANT,
	cli_name           = "const",
	display_name       = "Constant",
	icon               = "💾",
	has_clean          = false,
	has_dedup          = false,
	fields_count       = 2,
	field_labels       = []string{"Variable Name", "Value"},
	field_placeholders = []string{"MY_VAR", "my_value"},

	// TOML-first ops wired for the generic handle_toml_entry_command dispatcher.
	toml_add           = toml_constant_add,
	toml_remove        = toml_constant_remove,
	toml_list          = list_toml_constants,
	toml_get           = get_toml_constant_value,
	hook_pre_add       = hook_pre_constant_add,
	hook_post_add      = hook_post_constant_add,
	hook_pre_remove    = hook_pre_constant_remove,
	hook_post_remove   = hook_post_constant_remove,
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

// ============================================================================
// ALIAS Validators, Formatters, and Parsers
// ============================================================================
