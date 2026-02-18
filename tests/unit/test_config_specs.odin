package test_wayu

import "core:testing"
import "core:strings"
import wayu "../../src"

// ============================================================================
// Input Validator Tests (config_specs.odin)
// ============================================================================

@(test)
test_validate_path_input_empty :: proc(t: ^testing.T) {
	result := wayu.validate_path_input("")
	testing.expect(t, !result.valid, "Empty path should be invalid")
}

@(test)
test_validate_path_input_valid :: proc(t: ^testing.T) {
	result := wayu.validate_path_input("/usr/local/bin")
	testing.expect(t, result.valid, "Valid path should pass validation")
}

@(test)
test_validate_alias_name_input_empty :: proc(t: ^testing.T) {
	result := wayu.validate_alias_name_input("")
	testing.expect(t, !result.valid, "Empty alias name should be invalid")
}

@(test)
test_validate_alias_name_input_valid :: proc(t: ^testing.T) {
	result := wayu.validate_alias_name_input("ll")
	testing.expect(t, result.valid, "Valid alias name should pass validation")
}

@(test)
test_validate_alias_command_input_empty :: proc(t: ^testing.T) {
	result := wayu.validate_alias_command_input("")
	testing.expect(t, !result.valid, "Empty command should be invalid")
}

@(test)
test_validate_alias_command_input_whitespace_only :: proc(t: ^testing.T) {
	result := wayu.validate_alias_command_input("   ")
	testing.expect(t, !result.valid, "Whitespace-only command should be invalid")
}

@(test)
test_validate_constant_name_input_lowercase_warning :: proc(t: ^testing.T) {
	result := wayu.validate_constant_name_input("my_var")
	testing.expect(t, result.valid, "Lowercase constant name should be valid")
	testing.expect(t, len(result.warning) > 0, "Lowercase constant name should produce warning")
	if len(result.warning) > 0 {
		delete(result.warning)
	}
}

@(test)
test_validate_constant_name_input_uppercase :: proc(t: ^testing.T) {
	result := wayu.validate_constant_name_input("MY_VAR")
	testing.expect(t, result.valid, "Uppercase constant name should be valid")
	testing.expect_value(t, result.warning, "")
}

@(test)
test_validate_constant_value_input_valid :: proc(t: ^testing.T) {
	result := wayu.validate_constant_value_input("hello")
	testing.expect(t, result.valid, "Non-empty value should be valid")
}

@(test)
test_validate_constant_value_input_empty :: proc(t: ^testing.T) {
	result := wayu.validate_constant_value_input("")
	testing.expect(t, !result.valid, "Empty value should be invalid")
}

// ============================================================================
// Format with Quote Escaping Tests
// ============================================================================

@(test)
test_format_alias_line_escapes_quotes :: proc(t: ^testing.T) {
	entry := wayu.ConfigEntry{
		type = .ALIAS,
		name = "say",
		value = `echo "hi"`,
	}
	formatted := wayu.format_alias_line(entry)
	defer delete(formatted)
	testing.expect_value(t, formatted, `alias say="echo \"hi\""`)
}

@(test)
test_format_constant_line_escapes_quotes :: proc(t: ^testing.T) {
	entry := wayu.ConfigEntry{
		type = .CONSTANT,
		name = "MSG",
		value = `say "hi"`,
	}
	formatted := wayu.format_constant_line(entry)
	defer delete(formatted)
	testing.expect_value(t, formatted, `export MSG="say \"hi\""`)
}

// ============================================================================
// Additional Parse Edge Cases
// ============================================================================

@(test)
test_parse_alias_line_no_quotes :: proc(t: ^testing.T) {
	_, ok := wayu.parse_alias_line("alias ll=ls")
	testing.expect(t, !ok, "Alias without quotes should be rejected")
}

@(test)
test_parse_constant_line_empty_name :: proc(t: ^testing.T) {
	_, ok := wayu.parse_constant_line(`export ="value"`)
	testing.expect(t, !ok, "Export with empty name should be rejected")
}

@(test)
test_parse_constant_line_spaces_in_value :: proc(t: ^testing.T) {
	entry, ok := wayu.parse_constant_line(`export MSG="hello world"`)
	testing.expect(t, ok, "Should parse constant with spaces in value")
	defer wayu.cleanup_entry(&entry)

	testing.expect_value(t, entry.name, "MSG")
	testing.expect_value(t, entry.value, "hello world")
}
