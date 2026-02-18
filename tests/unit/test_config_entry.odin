package test_wayu

import "core:testing"
import "core:strings"
import wayu "../../src"

// ============================================================================
// parse_line -> format_line round-trip tests (Strategy Pattern contract)
// ============================================================================

@(test)
test_path_parse_format_roundtrip :: proc(t: ^testing.T) {
	original := `  "/usr/local/bin"`
	entry, ok := wayu.parse_path_line(original)
	testing.expect(t, ok, "Should parse valid PATH line")
	defer wayu.cleanup_entry(&entry)

	testing.expect_value(t, entry.type, wayu.ConfigEntryType.PATH)
	testing.expect_value(t, entry.name, "/usr/local/bin")
	testing.expect_value(t, entry.value, "")

	formatted := wayu.format_path_line(entry)
	defer delete(formatted)
	testing.expect_value(t, formatted, `  "/usr/local/bin"`)
}

@(test)
test_alias_parse_format_roundtrip :: proc(t: ^testing.T) {
	original := `alias ll="ls -la"`
	entry, ok := wayu.parse_alias_line(original)
	testing.expect(t, ok, "Should parse valid alias line")
	defer wayu.cleanup_entry(&entry)

	testing.expect_value(t, entry.type, wayu.ConfigEntryType.ALIAS)
	testing.expect_value(t, entry.name, "ll")
	testing.expect_value(t, entry.value, "ls -la")

	formatted := wayu.format_alias_line(entry)
	defer delete(formatted)
	testing.expect_value(t, formatted, `alias ll="ls -la"`)
}

@(test)
test_constant_parse_format_roundtrip :: proc(t: ^testing.T) {
	original := `export MY_VAR="hello world"`
	entry, ok := wayu.parse_constant_line(original)
	testing.expect(t, ok, "Should parse valid constant line")
	defer wayu.cleanup_entry(&entry)

	testing.expect_value(t, entry.type, wayu.ConfigEntryType.CONSTANT)
	testing.expect_value(t, entry.name, "MY_VAR")
	testing.expect_value(t, entry.value, "hello world")

	formatted := wayu.format_constant_line(entry)
	defer delete(formatted)
	testing.expect_value(t, formatted, `export MY_VAR="hello world"`)
}

// ============================================================================
// parse_line edge cases
// ============================================================================

@(test)
test_path_parse_rejects_non_quoted :: proc(t: ^testing.T) {
	invalid_lines := []string{
		"# comment",
		"WAYU_PATHS=(",
		")",
		"",
		"  not-a-path",
		"export PATH=something",
	}

	for line in invalid_lines {
		_, ok := wayu.parse_path_line(line)
		testing.expect(t, !ok, "Should reject non-PATH line")
	}
}

@(test)
test_alias_parse_rejects_invalid :: proc(t: ^testing.T) {
	invalid_lines := []string{
		`# alias commented="out"`,
		`export VAR="value"`,
		"alias",
		"alias =value",
		"",
		"not an alias",
	}

	for line in invalid_lines {
		_, ok := wayu.parse_alias_line(line)
		testing.expect(t, !ok, "Should reject non-alias line")
	}
}

@(test)
test_constant_parse_rejects_invalid :: proc(t: ^testing.T) {
	invalid_lines := []string{
		`# export COMMENTED="out"`,
		`alias ll="ls"`,
		"export",
		"export =value",
		"",
		"not an export",
	}

	for line in invalid_lines {
		_, ok := wayu.parse_constant_line(line)
		testing.expect(t, !ok, "Should reject non-constant line")
	}
}

@(test)
test_path_parse_with_env_vars :: proc(t: ^testing.T) {
	line := `  "$HOME/go/bin"`
	entry, ok := wayu.parse_path_line(line)
	testing.expect(t, ok, "Should parse PATH with env var")
	defer wayu.cleanup_entry(&entry)

	testing.expect_value(t, entry.name, "$HOME/go/bin")
}

@(test)
test_path_parse_empty_path :: proc(t: ^testing.T) {
	line := `  ""`
	entry, ok := wayu.parse_path_line(line)
	testing.expect(t, ok, "Should parse empty PATH entry")
	defer wayu.cleanup_entry(&entry)

	testing.expect_value(t, entry.name, "")
}

@(test)
test_alias_parse_with_complex_command :: proc(t: ^testing.T) {
	line := `alias gc="git commit -m"`
	entry, ok := wayu.parse_alias_line(line)
	testing.expect(t, ok, "Should parse alias with complex command")
	defer wayu.cleanup_entry(&entry)

	testing.expect_value(t, entry.name, "gc")
	testing.expect_value(t, entry.value, "git commit -m")
}

@(test)
test_constant_parse_unquoted_value :: proc(t: ^testing.T) {
	// parse_constant_line requires quoted values - unquoted should be rejected
	line := `export FOO=bar`
	_, ok := wayu.parse_constant_line(line)
	testing.expect(t, !ok, "Should reject unquoted constant value")
}

@(test)
test_constant_parse_empty_value :: proc(t: ^testing.T) {
	// parse_constant_line requires quoted values - empty value should be rejected
	line := `export EMPTY=`
	_, ok := wayu.parse_constant_line(line)
	testing.expect(t, !ok, "Should reject constant with empty/unquoted value")
}

// ============================================================================
// parse_args_to_entry tests
// ============================================================================

@(test)
test_parse_args_to_path_entry :: proc(t: ^testing.T) {
	args := []string{"/usr/local/bin"}
	entry := wayu.parse_args_to_entry(&wayu.PATH_SPEC, args)
	defer wayu.cleanup_entry(&entry)

	testing.expect_value(t, entry.type, wayu.ConfigEntryType.PATH)
	testing.expect_value(t, entry.name, "/usr/local/bin")
	testing.expect_value(t, entry.value, "")
}

@(test)
test_parse_args_to_alias_entry :: proc(t: ^testing.T) {
	args := []string{"ll", "ls -la"}
	entry := wayu.parse_args_to_entry(&wayu.ALIAS_SPEC, args)
	defer wayu.cleanup_entry(&entry)

	testing.expect_value(t, entry.type, wayu.ConfigEntryType.ALIAS)
	testing.expect_value(t, entry.name, "ll")
	testing.expect_value(t, entry.value, "ls -la")
}

@(test)
test_parse_args_to_constant_entry :: proc(t: ^testing.T) {
	args := []string{"MY_VAR", "my_value"}
	entry := wayu.parse_args_to_entry(&wayu.CONSTANTS_SPEC, args)
	defer wayu.cleanup_entry(&entry)

	testing.expect_value(t, entry.type, wayu.ConfigEntryType.CONSTANT)
	testing.expect_value(t, entry.name, "MY_VAR")
	testing.expect_value(t, entry.value, "my_value")
}

@(test)
test_parse_args_to_alias_with_spaces :: proc(t: ^testing.T) {
	args := []string{"gc", "git", "commit", "-m"}
	entry := wayu.parse_args_to_entry(&wayu.ALIAS_SPEC, args)
	defer wayu.cleanup_entry(&entry)

	testing.expect_value(t, entry.name, "gc")
	testing.expect_value(t, entry.value, "git commit -m")
}

@(test)
test_parse_args_to_entry_empty :: proc(t: ^testing.T) {
	args := []string{}
	entry := wayu.parse_args_to_entry(&wayu.PATH_SPEC, args)
	defer wayu.cleanup_entry(&entry)

	testing.expect_value(t, entry.name, "")
}

// ============================================================================
// is_entry_complete tests
// ============================================================================

@(test)
test_is_entry_complete_path :: proc(t: ^testing.T) {
	complete := wayu.ConfigEntry{type = .PATH, name = "/usr/bin", value = ""}
	testing.expect(t, wayu.is_entry_complete(complete), "PATH with name should be complete")

	incomplete := wayu.ConfigEntry{type = .PATH, name = "", value = ""}
	testing.expect(t, !wayu.is_entry_complete(incomplete), "PATH without name should be incomplete")
}

@(test)
test_is_entry_complete_alias :: proc(t: ^testing.T) {
	complete := wayu.ConfigEntry{type = .ALIAS, name = "ll", value = "ls -la"}
	testing.expect(t, wayu.is_entry_complete(complete), "Alias with name+value should be complete")

	no_value := wayu.ConfigEntry{type = .ALIAS, name = "ll", value = ""}
	testing.expect(t, !wayu.is_entry_complete(no_value), "Alias without value should be incomplete")

	no_name := wayu.ConfigEntry{type = .ALIAS, name = "", value = "ls -la"}
	testing.expect(t, !wayu.is_entry_complete(no_name), "Alias without name should be incomplete")
}

@(test)
test_is_entry_complete_constant :: proc(t: ^testing.T) {
	complete := wayu.ConfigEntry{type = .CONSTANT, name = "MY_VAR", value = "hello"}
	testing.expect(t, wayu.is_entry_complete(complete), "Constant with name+value should be complete")

	no_value := wayu.ConfigEntry{type = .CONSTANT, name = "MY_VAR", value = ""}
	testing.expect(t, !wayu.is_entry_complete(no_value), "Constant without value should be incomplete")
}

// ============================================================================
// ConfigEntrySpec contract verification
// ============================================================================

@(test)
test_path_spec_fields :: proc(t: ^testing.T) {
	spec := &wayu.PATH_SPEC
	testing.expect_value(t, spec.type, wayu.ConfigEntryType.PATH)
	testing.expect_value(t, spec.file_name, "path")
	testing.expect_value(t, spec.display_name, "PATH")
	testing.expect_value(t, spec.fields_count, 1)
	testing.expect(t, spec.has_clean, "PATH should support clean")
	testing.expect(t, spec.has_dedup, "PATH should support dedup")
	testing.expect(t, spec.parse_line != nil, "parse_line should be set")
	testing.expect(t, spec.format_line != nil, "format_line should be set")
	testing.expect(t, spec.validator != nil, "validator should be set")
}

@(test)
test_alias_spec_fields :: proc(t: ^testing.T) {
	spec := &wayu.ALIAS_SPEC
	testing.expect_value(t, spec.type, wayu.ConfigEntryType.ALIAS)
	testing.expect_value(t, spec.file_name, "aliases")
	testing.expect_value(t, spec.display_name, "Alias")
	testing.expect_value(t, spec.fields_count, 2)
	testing.expect(t, !spec.has_clean, "Alias should not support clean")
	testing.expect(t, !spec.has_dedup, "Alias should not support dedup")
}

@(test)
test_constants_spec_fields :: proc(t: ^testing.T) {
	spec := &wayu.CONSTANTS_SPEC
	testing.expect_value(t, spec.type, wayu.ConfigEntryType.CONSTANT)
	testing.expect_value(t, spec.file_name, "constants")
	testing.expect_value(t, spec.display_name, "Constant")
	testing.expect_value(t, spec.fields_count, 2)
	testing.expect(t, !spec.has_clean, "Constants should not support clean")
	testing.expect(t, !spec.has_dedup, "Constants should not support dedup")
}

// ============================================================================
// format_line with special characters
// ============================================================================

@(test)
test_alias_format_escapes_quotes :: proc(t: ^testing.T) {
	entry := wayu.ConfigEntry{
		type = .ALIAS,
		name = "greet",
		value = `echo "hello"`,
	}

	formatted := wayu.format_alias_line(entry)
	defer delete(formatted)

	testing.expect(t, strings.contains(formatted, `\"`), "Should escape quotes in alias command")
	testing.expect(t, strings.has_prefix(formatted, "alias greet="), "Should start with alias name=")
}

@(test)
test_constant_format_escapes_quotes :: proc(t: ^testing.T) {
	entry := wayu.ConfigEntry{
		type = .CONSTANT,
		name = "MSG",
		value = `say "hi"`,
	}

	formatted := wayu.format_constant_line(entry)
	defer delete(formatted)

	testing.expect(t, strings.contains(formatted, `\"`), "Should escape quotes in constant value")
	testing.expect(t, strings.has_prefix(formatted, "export MSG="), "Should start with export NAME=")
}

@(test)
test_path_format_with_spaces :: proc(t: ^testing.T) {
	entry := wayu.ConfigEntry{
		type = .PATH,
		name = "/path/with spaces/bin",
	}

	formatted := wayu.format_path_line(entry)
	defer delete(formatted)

	testing.expect_value(t, formatted, `  "/path/with spaces/bin"`)
}

// ============================================================================
// cleanup_entry memory safety
// ============================================================================

@(test)
test_cleanup_entry_with_empty_fields :: proc(t: ^testing.T) {
	entry := wayu.ConfigEntry{
		type = .PATH,
		name = "",
		value = "",
		line = "",
	}
	wayu.cleanup_entry(&entry)
}

@(test)
test_cleanup_entry_with_allocated_fields :: proc(t: ^testing.T) {
	entry := wayu.ConfigEntry{
		type = .ALIAS,
		name = strings.clone("test_name"),
		value = strings.clone("test_value"),
		line = strings.clone(`alias test_name="test_value"`),
	}
	wayu.cleanup_entry(&entry)
}

// ============================================================================
// g_current_spec global workaround
// ============================================================================

@(test)
test_g_current_spec_default_nil :: proc(t: ^testing.T) {
	testing.expect(t, wayu.g_current_spec == nil, "g_current_spec should be nil by default")
}
