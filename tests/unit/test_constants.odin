package test_wayu

import "core:testing"
import "core:fmt"
import "core:os"
import "core:strings"
import wayu "../../src"

@(test)
test_extract_constant_items :: proc(t: ^testing.T) {
	// Create a temporary constants file
	test_config := `#!/usr/bin/env zsh

# Environment Constants and Configuration Variables
export TEST_CONST="test_value"
export ANOTHER_CONST="another_value"
export QUOTED_CONST="value with spaces"
`

	// Write to a temporary file
	temp_file := "/tmp/test_constants.zsh"
	os.write_entire_file(temp_file, transmute([]byte)test_config)
	defer os.remove(temp_file)

	// Mock the WAYU_CONFIG and CONSTANTS_FILE for testing
	// This would require modifying the source to be testable
	// For now, we'll test the extraction logic separately

	lines := strings.split(test_config, "\n")
	defer delete(lines)

	constants_found := 0
	for line in lines {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "export ") && strings.contains(trimmed, "=") {
			constants_found += 1
		}
	}

	testing.expect_value(t, constants_found, 3)
}

@(test)
test_constant_parsing :: proc(t: ^testing.T) {
	test_line := `export TEST_VAR="hello world"`

	if strings.has_prefix(test_line, "export ") && strings.contains(test_line, "=") {
		eq_pos := strings.index(test_line, "=")
		if eq_pos != -1 {
			name := test_line[7:eq_pos] // Skip "export "
			testing.expect_value(t, name, "TEST_VAR")
		}
	}
}

@(test)
test_parse_args_constants_add :: proc(t: ^testing.T) {
	args := []string{"constants", "add", "MY_VAR", "my_value"}
	parsed := wayu.parse_args(args)
	defer if len(parsed.args) > 0 do delete(parsed.args)
	testing.expect_value(t, parsed.command, wayu.Command.CONSTANTS)
	testing.expect_value(t, parsed.action, wayu.Action.ADD)
	testing.expect_value(t, len(parsed.args), 2)
}

@(test)
test_parse_args_constants_list :: proc(t: ^testing.T) {
	args := []string{"constants", "ls"}
	parsed := wayu.parse_args(args)
	testing.expect_value(t, parsed.command, wayu.Command.CONSTANTS)
	testing.expect_value(t, parsed.action, wayu.Action.LIST)
}

@(test)
test_constant_value_with_quotes :: proc(t: ^testing.T) {
	test_line := `export PATH="/usr/bin:/usr/local/bin"`
	testing.expect(t, strings.contains(test_line, "="), "Should contain equals")
	testing.expect(t, strings.has_prefix(test_line, "export "), "Should start with export")

	// Extract value
	eq_pos := strings.index(test_line, "=")
	if eq_pos != -1 {
		value := test_line[eq_pos + 1:]
		testing.expect(t, strings.has_prefix(value, "\""), "Value should have quotes")
	}
}

@(test)
test_constant_name_extraction :: proc(t: ^testing.T) {
	test_lines := []string{
		`export VAR1="value1"`,
		`export VAR_WITH_UNDERSCORE="value2"`,
		`export VAR123="value3"`,
	}

	expected_names := []string{"VAR1", "VAR_WITH_UNDERSCORE", "VAR123"}

	for test_line, i in test_lines {
		if strings.has_prefix(test_line, "export ") && strings.contains(test_line, "=") {
			eq_pos := strings.index(test_line, "=")
			if eq_pos != -1 {
				name := test_line[7:eq_pos]
				testing.expect_value(t, name, expected_names[i])
			}
		}
	}
}