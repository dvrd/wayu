package test_wayu

import "core:testing"
import "core:fmt"
import "core:os"
import "core:strings"
import wayu "../src"

@(test)
test_path_parsing :: proc(t: ^testing.T) {
	test_config := `#!/usr/bin/env zsh

add_to_path() {
    local dir="$1"
    if [ ! -d "$dir" ]; then return 1; fi
}

add_to_path "/usr/local/bin"
add_to_path "/opt/homebrew/bin"
add_to_path "$HOME/go/bin"
`

	lines := strings.split(test_config, "\n")
	defer delete(lines)

	paths_found := 0
	for line in lines {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "add_to_path") {
			start := strings.index(trimmed, "\"")
			if start != -1 {
				end := strings.last_index(trimmed, "\"")
				if end != -1 && end > start {
					path := trimmed[start + 1:end]
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
	}

	testing.expect_value(t, paths_found, 3)
}

@(test)
test_path_extraction_edge_cases :: proc(t: ^testing.T) {
	// Test edge cases in path extraction
	test_cases := []string{
		`add_to_path "/path/with spaces"`,
		`add_to_path "/path/with/quotes'"`,
		`    add_to_path    "/path/with/whitespace"   `,
		`add_to_path ""`,  // Empty path
	}

	expected_paths := []string{
		"/path/with spaces",
		"/path/with/quotes'",
		"/path/with/whitespace",
		"",
	}

	for test_case, i in test_cases {
		trimmed := strings.trim_space(test_case)
		if strings.has_prefix(trimmed, "add_to_path") {
			start := strings.index(trimmed, "\"")
			if start != -1 {
				end := strings.last_index(trimmed, "\"")
				if end != -1 && end > start {
					path := trimmed[start + 1:end]
					testing.expect_value(t, path, expected_paths[i])
				}
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
	// Test that path lines follow the expected format
	valid_line := `add_to_path "/usr/local/bin"`
	testing.expect(t, strings.has_prefix(valid_line, "add_to_path"), "Should start with add_to_path")
	testing.expect(t, strings.contains(valid_line, "\""), "Should contain quotes")
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

@(test)
test_count_duplicates :: proc(t: ^testing.T) {
	// Test counting duplicate paths
	duplicate_indices := []bool{false, true, false, true, true}
	count := wayu.count_duplicates(duplicate_indices)
	testing.expect_value(t, count, 3)
}

@(test)
test_count_duplicates_empty :: proc(t: ^testing.T) {
	// Test counting with no duplicates
	duplicate_indices := []bool{false, false, false}
	count := wayu.count_duplicates(duplicate_indices)
	testing.expect_value(t, count, 0)
}

@(test)
test_count_missing_paths :: proc(t: ^testing.T) {
	// Test counting missing paths
	paths := []string{"/nonexistent/path1", "/nonexistent/path2", "/tmp"}
	count := wayu.count_missing_paths(paths)
	testing.expect(t, count >= 2, "Should count at least 2 missing paths")
}

@(test)
test_analyze_paths :: proc(t: ^testing.T) {
	// Test path analysis
	paths := []string{"/tmp", "/tmp", "/nonexistent"}
	analysis := wayu.analyze_paths(paths)
	defer wayu.cleanup_path_analysis(&analysis)

	testing.expect(t, len(analysis.duplicate_indices) == 3, "Should have duplicate indices for all paths")
	testing.expect(t, len(analysis.expanded_paths) == 3, "Should have expanded paths")
}

@(test)
test_cleanup_path_analysis :: proc(t: ^testing.T) {
	// Test cleanup of path analysis
	paths := []string{"/tmp", "/tmp"}
	analysis := wayu.analyze_paths(paths)
	wayu.cleanup_path_analysis(&analysis)
	// Just verify it doesn't crash
	testing.expect(t, true, "Cleanup should not crash")
}

@(test)
test_print_path_help :: proc(t: ^testing.T) {
	// Test that help printing doesn't crash
	wayu.print_path_help()
	testing.expect(t, true, "Help printing should not crash")
}