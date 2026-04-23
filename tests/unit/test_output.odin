package test_wayu

import "core:testing"
import "core:strings"
import wayu "../../src"

// ============================================================================
// Output Format Tests
// ============================================================================

@(test)
test_output_format_default :: proc(t: ^testing.T) {
	format := wayu.output_get_current_format()
	// Default should be Plain
	testing.expect_value(t, format, wayu.OutputFormat.Plain)
}

@(test)
test_output_format_set :: proc(t: ^testing.T) {
	// Save original format
	original := wayu.output_get_current_format()

	// Set to JSON
	wayu.output_format_set(.JSON)
	testing.expect_value(t, wayu.output_get_current_format(), wayu.OutputFormat.JSON)

	// Set to YAML
	wayu.output_format_set(.YAML)
	testing.expect_value(t, wayu.output_get_current_format(), wayu.OutputFormat.YAML)

	// Restore original
	wayu.output_format_set(original)
}

// ============================================================================
// JSON Serialization Tests - Basic Types
// ============================================================================

@(test)
test_output_to_json_string :: proc(t: ^testing.T) {
	text := "hello world"
	result := wayu.output_to_json(&text)
	defer delete(result)

	testing.expect(t, strings.contains(result, "\"hello world\""), "String should be quoted")
}

@(test)
test_output_to_json_int :: proc(t: ^testing.T) {
	value := 42
	result := wayu.output_to_json(&value)
	defer delete(result)

	testing.expect_value(t, result, "42")
}

@(test)
test_output_to_json_bool_true :: proc(t: ^testing.T) {
	value := true
	result := wayu.output_to_json(&value)
	defer delete(result)

	testing.expect_value(t, result, "true")
}

@(test)
test_output_to_json_bool_false :: proc(t: ^testing.T) {
	value := false
	result := wayu.output_to_json(&value)
	defer delete(result)

	testing.expect_value(t, result, "false")
}

// ============================================================================
// JSON Serialization Tests - String Escaping
// ============================================================================

@(test)
test_output_to_json_string_with_quotes :: proc(t: ^testing.T) {
	text := `say "hello"`
	result := wayu.output_to_json(&text)
	defer delete(result)

	testing.expect(t, strings.contains(result, `\"`), "Double quotes should be escaped")
}

@(test)
test_output_to_json_string_with_newline :: proc(t: ^testing.T) {
	text := "line1\nline2"
	result := wayu.output_to_json(&text)
	defer delete(result)

	testing.expect(t, strings.contains(result, `\n`), "Newlines should be escaped")
}

@(test)
test_output_to_json_string_with_backslash :: proc(t: ^testing.T) {
	text := "path\\to\\file"
	result := wayu.output_to_json(&text)
	defer delete(result)

	testing.expect(t, strings.contains(result, `\\`), "Backslashes should be escaped")
}

// ============================================================================
// JSON Serialization Tests - Structs
// ============================================================================

@(test)
test_output_to_json_struct :: proc(t: ^testing.T) {
	entry := wayu.ConstantEntry{
		name   = "TEST_VAR",
		value  = "test_value",
		export = true,
	}

	result := wayu.output_to_json(&entry)
	defer delete(result)

	testing.expect(t, strings.contains(result, `"name"`), "Should contain name field")
	testing.expect(t, strings.contains(result, `"TEST_VAR"`), "Should contain name value")
	testing.expect(t, strings.contains(result, `"value"`), "Should contain value field")
	testing.expect(t, strings.contains(result, `"test_value"`), "Should contain value value")
}

@(test)
test_output_to_json_pretty_format :: proc(t: ^testing.T) {
	entry := wayu.ConstantEntry{
		name   = "TEST_VAR",
		value  = "test_value",
		export = true,
	}

	result := wayu.output_to_json_pretty(&entry)
	defer delete(result)

	// Pretty format should have newlines and indentation
	testing.expect(t, strings.contains(result, "\n"), "Pretty format should contain newlines")
}

// ============================================================================
// WAYU-Specific Output Tests - PATH Entries
// ============================================================================

@(test)
test_format_path_list_json_empty :: proc(t: ^testing.T) {
	entries := make([]wayu.ConfigEntry, 0)
	defer delete(entries)

	result := wayu.format_path_list_json(entries)
	defer delete(result)

	testing.expect(t, strings.contains(result, `"count"`), "Should contain count field")
	testing.expect(t, strings.contains(result, "0"), "Should show count of 0")
}

@(test)
test_format_path_list_json_with_entries :: proc(t: ^testing.T) {
	entries := make([]wayu.ConfigEntry, 2)
	entries[0] = wayu.ConfigEntry{
		type = .PATH,
		name = "/usr/local/bin",
		value = "",
		line = `  "/usr/local/bin"`,
	}
	entries[1] = wayu.ConfigEntry{
		type = .PATH,
		name = "/home/user/bin",
		value = "",
		line = `  "/home/user/bin"`,
	}
	defer delete(entries)

	result := wayu.format_path_list_json(entries)
	defer delete(result)

	testing.expect(t, strings.contains(result, `"path"`), "Should contain path field")
	testing.expect(t, strings.contains(result, "/usr/local/bin"), "Should contain first path")
	testing.expect(t, strings.contains(result, "/home/user/bin"), "Should contain second path")
}

// ============================================================================
// WAYU-Specific Output Tests - Alias Entries
// ============================================================================

@(test)
test_format_alias_list_json_empty :: proc(t: ^testing.T) {
	entries := make([]wayu.ConfigEntry, 0)
	defer delete(entries)

	result := wayu.format_alias_list_json(entries)
	defer delete(result)

	testing.expect(t, strings.contains(result, `"count"`), "Should contain count field")
	testing.expect(t, strings.contains(result, "0"), "Should show count of 0")
}

@(test)
test_format_alias_list_json_with_entries :: proc(t: ^testing.T) {
	entries := make([]wayu.ConfigEntry, 2)
	entries[0] = wayu.ConfigEntry{
		type = .ALIAS,
		name = "ll",
		value = "ls -la",
		line = `alias ll="ls -la"`,
	}
	entries[1] = wayu.ConfigEntry{
		type = .ALIAS,
		name = "gc",
		value = "git commit",
		line = `alias gc="git commit"`,
	}
	defer delete(entries)

	result := wayu.format_alias_list_json(entries)
	defer delete(result)

	testing.expect(t, strings.contains(result, `"name"`), "Should contain name field")
	testing.expect(t, strings.contains(result, `"ll"`), "Should contain first alias name")
	testing.expect(t, strings.contains(result, `"gc"`), "Should contain second alias name")
	testing.expect(t, strings.contains(result, `"command"`), "Should contain command field")
	testing.expect(t, strings.contains(result, "ls -la"), "Should contain first command")
}

// ============================================================================
// WAYU-Specific Output Tests - Constant Entries
// ============================================================================

@(test)
test_format_constant_list_json_empty :: proc(t: ^testing.T) {
	entries := make([]wayu.ConfigEntry, 0)
	defer delete(entries)

	result := wayu.format_constant_list_json(entries)
	defer delete(result)

	testing.expect(t, strings.contains(result, `"count"`), "Should contain count field")
	testing.expect(t, strings.contains(result, "0"), "Should show count of 0")
}

@(test)
test_format_constant_list_json_with_entries :: proc(t: ^testing.T) {
	entries := make([]wayu.ConfigEntry, 2)
	entries[0] = wayu.ConfigEntry{
		type = .CONSTANT,
		name = "EDITOR",
		value = "nvim",
		line = `export EDITOR="nvim"`,
	}
	entries[1] = wayu.ConfigEntry{
		type = .CONSTANT,
		name = "HOME_DIR",
		value = "/home/user",
		line = `HOME_DIR="/home/user"`,
	}
	defer delete(entries)

	result := wayu.format_constant_list_json(entries)
	defer delete(result)

	testing.expect(t, strings.contains(result, `"name"`), "Should contain name field")
	testing.expect(t, strings.contains(result, "EDITOR"), "Should contain first constant")
	testing.expect(t, strings.contains(result, "HOME_DIR"), "Should contain second constant")
	testing.expect(t, strings.contains(result, `"export"`), "Should contain export field")
}

@(test)
test_format_constant_get_json :: proc(t: ^testing.T) {
	result := wayu.format_constant_get_json("TEST_VAR", "test_value", true)
	defer delete(result)

	testing.expect(t, strings.contains(result, `"name"`), "Should contain name field")
	testing.expect(t, strings.contains(result, `"TEST_VAR"`), "Should contain name value")
	testing.expect(t, strings.contains(result, `"value"`), "Should contain value field")
	testing.expect(t, strings.contains(result, "test_value"), "Should contain value")
	testing.expect(t, strings.contains(result, `"export"`), "Should contain export field")
}

// ============================================================================
// YAML Output Tests (returns JSON-like format for now)
// ============================================================================

@(test)
test_output_to_yaml_basic :: proc(t: ^testing.T) {
	entry := wayu.ConstantEntry{
		name   = "TEST",
		value  = "value",
		export = false,
	}

	result := wayu.output_to_yaml(&entry)
	defer delete(result)

	// YAML should return a formatted string
	testing.expect(t, len(result) > 0, "YAML output should not be empty")
}

// ============================================================================
// JSON Parsing Tests (Basic)
// ============================================================================

@(test)
test_output_from_json_empty :: proc(t: ^testing.T) {
	// Test that empty string returns false
	target: wayu.ConstantEntry
	target_any := any{&target, typeid_of(wayu.ConstantEntry)}
	result := wayu.output_from_json("", &target_any)
	testing.expect(t, !result, "Empty string should return false")
}

@(test)
test_output_from_json_whitespace :: proc(t: ^testing.T) {
	// Test that whitespace-only string returns false
	target: wayu.ConstantEntry
	target_any := any{&target, typeid_of(wayu.ConstantEntry)}
	result := wayu.output_from_json("   \n\t  ", &target_any)
	testing.expect(t, !result, "Whitespace-only string should return false")
}
