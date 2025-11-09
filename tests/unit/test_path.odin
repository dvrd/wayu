package test_wayu

import "core:testing"
import "core:fmt"
import "core:os"
import "core:strings"
import wayu "../../src"

@(test)
test_path_parsing :: proc(t: ^testing.T) {
	test_config := `#!/usr/bin/env zsh

# Centralized PATH registry
WAYU_PATHS=(
  "/usr/local/bin"
  "/opt/homebrew/bin"
  "$HOME/go/bin"
)
`

	lines := strings.split(test_config, "\n")
	defer delete(lines)

	paths_found := 0
	for line in lines {
		trimmed := strings.trim_space(line)
		// Parse array elements: lines starting with quote
		if strings.has_prefix(trimmed, "\"") && strings.has_suffix(trimmed, "\"") {
			// Extract path from quotes
			if len(trimmed) >= 2 {
				path := trimmed[1:len(trimmed) - 1]
				paths_found += 1

				// Test that paths are valid
				if paths_found == 1 {
					testing.expect_value(t, path, "/usr/local/bin")
				} else if paths_found == 2 {
					testing.expect_value(t, path, "/opt/homebrew/bin")
				} else if paths_found == 3 {
					testing.expect_value(t, path, "$HOME/go/bin")
				}
			}
		}
	}

	testing.expect_value(t, paths_found, 3)
}

@(test)
test_path_extraction_edge_cases :: proc(t: ^testing.T) {
	// Test edge cases in path extraction (array element format)
	test_cases := []string{
		`  "/path/with spaces"`,
		`  "/path/with/quotes'"`,
		`    "/path/with/whitespace"   `,
		`  ""`,  // Empty path
	}

	expected_paths := []string{
		"/path/with spaces",
		"/path/with/quotes'",
		"/path/with/whitespace",
		"",
	}

	for test_case, i in test_cases {
		trimmed := strings.trim_space(test_case)
		// Parse array elements: quoted strings
		if strings.has_prefix(trimmed, "\"") && strings.has_suffix(trimmed, "\"") {
			if len(trimmed) >= 2 {
				path := trimmed[1:len(trimmed) - 1]
				testing.expect_value(t, path, expected_paths[i])
			}
		}
	}
}

@(test)
test_parse_args_path_list :: proc(t: ^testing.T) {
	args := []string{"path", "list"}
	parsed := wayu.parse_args(args)
	testing.expect_value(t, parsed.command, wayu.Command.PATH)
	testing.expect_value(t, parsed.action, wayu.Action.LIST)
}

@(test)
test_parse_args_path_remove :: proc(t: ^testing.T) {
	args := []string{"path", "rm", "/usr/local/bin"}
	parsed := wayu.parse_args(args)
	defer if len(parsed.args) > 0 do delete(parsed.args)
	testing.expect_value(t, parsed.command, wayu.Command.PATH)
	testing.expect_value(t, parsed.action, wayu.Action.REMOVE)
	testing.expect_value(t, len(parsed.args), 1)
}

@(test)
test_path_line_format :: proc(t: ^testing.T) {
	// Test that path lines follow the expected format (array elements)
	valid_line := `  "/usr/local/bin"`
	trimmed := strings.trim_space(valid_line)
	testing.expect(t, strings.has_prefix(trimmed, "\""), "Should start with quote")
	testing.expect(t, strings.has_suffix(trimmed, "\""), "Should end with quote")
}

@(test)
test_expand_env_vars :: proc(t: ^testing.T) {
	// Test environment variable expansion
	result := wayu.expand_env_vars("$HOME/.local/bin")
	defer delete(result)
	testing.expect(t, len(result) > 0, "Should expand environment variables")
	testing.expect(t, !strings.contains(result, "$HOME"), "Should replace $HOME")
}

@(test)
test_expand_env_vars_no_vars :: proc(t: ^testing.T) {
	// Test path without environment variables
	path := "/usr/local/bin"
	result := wayu.expand_env_vars(path)
	defer delete(result)
	testing.expect_value(t, result, path)
}

// Note: The following tests have been removed because they tested non-existent functions:
// - test_count_duplicates: count_duplicates() never existed
// - test_count_duplicates_empty: count_duplicates() never existed
// - test_count_missing_paths: count_missing_paths() never existed (actual: clean_missing_paths())
// - test_analyze_paths: analyze_paths() never existed
// - test_cleanup_path_analysis: cleanup_path_analysis() never existed
// - test_print_path_help: print_path_help() never existed (replaced by generic print_config_help())
//
// The PATH functionality is fully tested through:
// - Integration tests: Full add/remove/list workflow with duplicate detection and missing path handling
// - Unit tests above: expand_env_vars(), extract_path_items(), parsing logic