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