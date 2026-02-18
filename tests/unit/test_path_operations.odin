// test_path_operations.odin - Unit tests for PATH clean/dedup operations
//
// Tests the parsing, formatting, and duplicate detection logic used by
// clean_missing_paths() and remove_duplicate_paths(). The actual clean/dedup
// functions do file I/O and call os.exit(), so we test the underlying helpers
// and algorithms they rely on.

package test_wayu

import "core:os"
import "core:testing"
import "core:strings"
import wayu "../../src"

// ============================================================================
// parse_path_line tests (used by both clean and dedup to identify PATH entries)
// ============================================================================

@(test)
test_ops_parse_path_line_valid_entry :: proc(t: ^testing.T) {
	// parse_path_line extracts path from array element format: "  \"/usr/local/bin\""
	entry, ok := wayu.parse_path_line(`  "/usr/local/bin"`)
	defer if ok do wayu.cleanup_entry(&entry)

	testing.expect(t, ok, "Should parse valid path line")
	testing.expect_value(t, entry.name, "/usr/local/bin")
	testing.expect_value(t, entry.type, wayu.ConfigEntryType.PATH)
}

@(test)
test_ops_parse_path_line_with_env_var :: proc(t: ^testing.T) {
	// Lines with $HOME should be parsed as-is (expansion happens later)
	entry, ok := wayu.parse_path_line(`  "$HOME/go/bin"`)
	defer if ok do wayu.cleanup_entry(&entry)

	testing.expect(t, ok, "Should parse path with env var")
	testing.expect_value(t, entry.name, "$HOME/go/bin")
}

@(test)
test_ops_parse_path_line_rejects_comment :: proc(t: ^testing.T) {
	// Comments should not be parsed as path entries
	_, ok := wayu.parse_path_line("# This is a comment")
	testing.expect(t, !ok, "Should reject comment lines")
}

@(test)
test_ops_parse_path_line_rejects_array_declaration :: proc(t: ^testing.T) {
	// The WAYU_PATHS=( line itself should not be parsed as a path
	_, ok := wayu.parse_path_line("WAYU_PATHS=(")
	testing.expect(t, !ok, "Should reject array declaration line")
}

@(test)
test_ops_parse_path_line_rejects_closing_paren :: proc(t: ^testing.T) {
	// The closing ) should not be parsed as a path
	_, ok := wayu.parse_path_line(")")
	testing.expect(t, !ok, "Should reject closing paren")
}

@(test)
test_ops_parse_path_line_rejects_empty_line :: proc(t: ^testing.T) {
	_, ok := wayu.parse_path_line("")
	testing.expect(t, !ok, "Should reject empty line")
}

@(test)
test_ops_parse_path_line_rejects_unquoted :: proc(t: ^testing.T) {
	// Unquoted paths should not be parsed
	_, ok := wayu.parse_path_line("  /usr/local/bin")
	testing.expect(t, !ok, "Should reject unquoted path")
}

// ============================================================================
// format_path_line tests (used when writing back cleaned/deduped entries)
// ============================================================================

@(test)
test_ops_format_path_line_basic :: proc(t: ^testing.T) {
	entry := wayu.ConfigEntry{
		type = .PATH,
		name = "/usr/local/bin",
		value = "",
		line = "",
	}
	result := wayu.format_path_line(entry)
	defer delete(result)

	testing.expect_value(t, result, `  "/usr/local/bin"`)
}

@(test)
test_ops_format_path_line_with_spaces :: proc(t: ^testing.T) {
	entry := wayu.ConfigEntry{
		type = .PATH,
		name = "/path/with spaces/bin",
		value = "",
		line = "",
	}
	result := wayu.format_path_line(entry)
	defer delete(result)

	testing.expect_value(t, result, `  "/path/with spaces/bin"`)
}

@(test)
test_ops_format_path_line_roundtrip :: proc(t: ^testing.T) {
	// Format a path, then parse it back - should get the same name
	original_path := "/opt/homebrew/bin"
	entry := wayu.ConfigEntry{
		type = .PATH,
		name = original_path,
		value = "",
		line = "",
	}

	formatted := wayu.format_path_line(entry)
	defer delete(formatted)

	parsed, ok := wayu.parse_path_line(formatted)
	defer if ok do wayu.cleanup_entry(&parsed)

	testing.expect(t, ok, "Should parse formatted line")
	testing.expect_value(t, parsed.name, original_path)
}

// ============================================================================
// PATH array format parsing (full config content)
// ============================================================================

@(test)
test_ops_path_array_format_parsing :: proc(t: ^testing.T) {
	// Test parsing a complete WAYU_PATHS array config
	test_config := `#!/usr/bin/env zsh

# Centralized PATH registry
WAYU_PATHS=(
  "/usr/local/bin"
  "/opt/homebrew/bin"
  "$HOME/go/bin"
)

# Export all paths
for p in "${WAYU_PATHS[@]}"; do
  export PATH="$p:$PATH"
done`

	lines := strings.split(test_config, "\n")
	defer delete(lines)

	parsed_paths := make([dynamic]string)
	defer {
		for p in parsed_paths {
			delete(p)
		}
		delete(parsed_paths)
	}

	for line in lines {
		entry, ok := wayu.parse_path_line(line)
		if ok {
			append(&parsed_paths, strings.clone(entry.name))
			wayu.cleanup_entry(&entry)
		}
	}

	testing.expect_value(t, len(parsed_paths), 3)
	testing.expect_value(t, parsed_paths[0], "/usr/local/bin")
	testing.expect_value(t, parsed_paths[1], "/opt/homebrew/bin")
	testing.expect_value(t, parsed_paths[2], "$HOME/go/bin")
}

@(test)
test_ops_path_array_format_empty :: proc(t: ^testing.T) {
	// Test parsing an empty WAYU_PATHS array
	test_config := `#!/usr/bin/env zsh
WAYU_PATHS=(
)
`
	lines := strings.split(test_config, "\n")
	defer delete(lines)

	count := 0
	for line in lines {
		entry, ok := wayu.parse_path_line(line)
		if ok {
			wayu.cleanup_entry(&entry)
			count += 1
		}
	}

	testing.expect_value(t, count, 0)
}

@(test)
test_ops_path_array_format_single_entry :: proc(t: ^testing.T) {
	test_config := `WAYU_PATHS=(
  "/usr/local/bin"
)`

	lines := strings.split(test_config, "\n")
	defer delete(lines)

	count := 0
	for line in lines {
		entry, ok := wayu.parse_path_line(line)
		if ok {
			defer wayu.cleanup_entry(&entry)
			testing.expect_value(t, entry.name, "/usr/local/bin")
			count += 1
		}
	}

	testing.expect_value(t, count, 1)
}

// ============================================================================
// Duplicate detection logic (algorithm used by remove_duplicate_paths)
// ============================================================================

@(test)
test_ops_dedup_detection_finds_duplicates :: proc(t: ^testing.T) {
	// Replicate the duplicate detection algorithm from remove_duplicate_paths()
	paths := []string{"/usr/local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/home/user/bin"}

	duplicate_indices := make([dynamic]int)
	defer delete(duplicate_indices)

	for i in 0..<len(paths) {
		for j in i + 1..<len(paths) {
			if paths[i] == paths[j] {
				append(&duplicate_indices, j)
			}
		}
	}

	testing.expect_value(t, len(duplicate_indices), 1)
	testing.expect_value(t, duplicate_indices[0], 2) // Index 2 is the duplicate of index 0
}

@(test)
test_ops_dedup_detection_no_duplicates :: proc(t: ^testing.T) {
	paths := []string{"/usr/local/bin", "/opt/homebrew/bin", "/home/user/bin"}

	duplicate_indices := make([dynamic]int)
	defer delete(duplicate_indices)

	for i in 0..<len(paths) {
		for j in i + 1..<len(paths) {
			if paths[i] == paths[j] {
				append(&duplicate_indices, j)
			}
		}
	}

	testing.expect_value(t, len(duplicate_indices), 0)
}

@(test)
test_ops_dedup_detection_multiple_duplicates :: proc(t: ^testing.T) {
	// Three occurrences of the same path - should find 2 duplicates
	paths := []string{"/usr/local/bin", "/usr/local/bin", "/opt/bin", "/usr/local/bin"}

	duplicate_indices := make([dynamic]int)
	defer delete(duplicate_indices)

	for i in 0..<len(paths) {
		for j in i + 1..<len(paths) {
			if paths[i] == paths[j] {
				append(&duplicate_indices, j)
			}
		}
	}

	// Index 0 matches index 1 and index 3
	// Index 1 matches index 3
	// So duplicates are at indices: 1, 3, 3 (but 3 appears twice)
	testing.expect(t, len(duplicate_indices) >= 2, "Should find at least 2 duplicate indices")
}

@(test)
test_ops_dedup_detection_empty_list :: proc(t: ^testing.T) {
	paths := []string{}

	duplicate_indices := make([dynamic]int)
	defer delete(duplicate_indices)

	for i in 0..<len(paths) {
		for j in i + 1..<len(paths) {
			if paths[i] == paths[j] {
				append(&duplicate_indices, j)
			}
		}
	}

	testing.expect_value(t, len(duplicate_indices), 0)
}

@(test)
test_ops_dedup_detection_all_same :: proc(t: ^testing.T) {
	// All entries are the same path
	paths := []string{"/usr/local/bin", "/usr/local/bin", "/usr/local/bin"}

	duplicate_indices := make([dynamic]int)
	defer delete(duplicate_indices)

	for i in 0..<len(paths) {
		for j in i + 1..<len(paths) {
			if paths[i] == paths[j] {
				append(&duplicate_indices, j)
			}
		}
	}

	// 0 matches 1, 0 matches 2, 1 matches 2 => indices 1, 2, 2
	testing.expect(t, len(duplicate_indices) >= 2, "Should find duplicates for all-same list")
}

// ============================================================================
// Duplicate filtering logic (line-by-line filtering used by dedup)
// ============================================================================

@(test)
test_ops_dedup_filtering_removes_correct_lines :: proc(t: ^testing.T) {
	// Simulate the filtering logic from remove_duplicate_paths:
	// Given a config with duplicates, filter out the duplicate lines
	test_config := `WAYU_PATHS=(
  "/usr/local/bin"
  "/opt/homebrew/bin"
  "/usr/local/bin"
)`

	lines := strings.split(test_config, "\n")
	defer delete(lines)

	// First pass: collect all paths and find duplicates
	all_paths := make([dynamic]string)
	defer {
		for p in all_paths {
			delete(p)
		}
		delete(all_paths)
	}

	for line in lines {
		entry, ok := wayu.parse_path_line(line)
		if ok {
			append(&all_paths, strings.clone(entry.name))
			wayu.cleanup_entry(&entry)
		}
	}

	// Find duplicate indices
	duplicate_names := make([dynamic]string)
	defer {
		for n in duplicate_names {
			delete(n)
		}
		delete(duplicate_names)
	}

	for i in 0..<len(all_paths) {
		for j in i + 1..<len(all_paths) {
			if all_paths[i] == all_paths[j] {
				append(&duplicate_names, strings.clone(all_paths[j]))
			}
		}
	}

	// Second pass: filter out duplicates (keep first occurrence)
	new_lines := make([dynamic]string)
	defer {
		for l in new_lines {
			delete(l)
		}
		delete(new_lines)
	}

	names_to_remove := make([dynamic]string)
	defer {
		for n in names_to_remove {
			delete(n)
		}
		delete(names_to_remove)
	}
	for n in duplicate_names {
		append(&names_to_remove, strings.clone(n))
	}

	for line in lines {
		entry, ok := wayu.parse_path_line(line)
		if ok {
			is_dup := false
			for name, idx in names_to_remove {
				if entry.name == name {
					is_dup = true
					// Remove from list (only skip once)
					last_idx := len(names_to_remove) - 1
					if idx != last_idx {
						delete(names_to_remove[idx])
						names_to_remove[idx] = names_to_remove[last_idx]
					} else {
						delete(names_to_remove[idx])
					}
					resize(&names_to_remove, last_idx)
					break
				}
			}
			wayu.cleanup_entry(&entry)
			if is_dup { continue }
		}
		append(&new_lines, strings.clone(line))
	}

	// Count remaining path entries
	remaining_paths := 0
	for line in new_lines {
		entry, ok := wayu.parse_path_line(line)
		if ok {
			wayu.cleanup_entry(&entry)
			remaining_paths += 1
		}
	}

	testing.expect_value(t, remaining_paths, 2) // /usr/local/bin (first) + /opt/homebrew/bin
}

// ============================================================================
// Clean filtering logic (missing path detection)
// ============================================================================

@(test)
test_ops_clean_filtering_identifies_missing :: proc(t: ^testing.T) {
	// Simulate the missing path detection from clean_missing_paths:
	// Parse paths and check which ones don't exist on the filesystem
	test_paths := []string{
		"/usr/local/bin",                    // likely exists
		"/nonexistent/path/that/wont/exist", // definitely doesn't exist
		"/another/fake/path/12345",          // definitely doesn't exist
	}

	missing_count := 0
	existing_count := 0
	for path in test_paths {
		if !os.exists(path) {
			missing_count += 1
		} else {
			existing_count += 1
		}
	}

	// At minimum, the fake paths should be missing
	testing.expect(t, missing_count >= 2, "Should detect at least 2 missing paths")
}

@(test)
test_ops_clean_filtering_all_missing :: proc(t: ^testing.T) {
	// All paths are nonexistent
	test_paths := []string{
		"/nonexistent/aaa/111",
		"/nonexistent/bbb/222",
		"/nonexistent/ccc/333",
	}

	missing_count := 0
	for path in test_paths {
		if !os.exists(path) {
			missing_count += 1
		}
	}

	testing.expect_value(t, missing_count, 3)
}

@(test)
test_ops_clean_filtering_none_missing :: proc(t: ^testing.T) {
	// Use paths that definitely exist on any system
	test_paths := []string{
		"/usr",
		"/tmp",
	}

	missing_count := 0
	for path in test_paths {
		if !os.exists(path) {
			missing_count += 1
		}
	}

	testing.expect_value(t, missing_count, 0)
}

// ============================================================================
// expand_env_vars tests (used by both clean and dedup for path comparison)
// ============================================================================

@(test)
test_ops_expand_env_vars_home :: proc(t: ^testing.T) {
	result := wayu.expand_env_vars("$HOME/.local/bin")
	defer delete(result)

	testing.expect(t, !strings.contains(result, "$HOME"), "Should expand $HOME")
	testing.expect(t, len(result) > 0, "Result should not be empty")
}

@(test)
test_ops_expand_env_vars_no_expansion_needed :: proc(t: ^testing.T) {
	result := wayu.expand_env_vars("/usr/local/bin")
	defer delete(result)

	testing.expect_value(t, result, "/usr/local/bin")
}

@(test)
test_ops_expand_env_vars_multiple_vars :: proc(t: ^testing.T) {
	result := wayu.expand_env_vars("$HOME")
	defer delete(result)

	testing.expect(t, !strings.contains(result, "$HOME"), "Should expand $HOME")
	testing.expect(t, len(result) > 1, "Expanded HOME should be a real path")
}

// ============================================================================
// ConfigEntry helpers (used throughout clean/dedup)
// ============================================================================

@(test)
test_ops_entry_complete_path_with_name :: proc(t: ^testing.T) {
	// PATH entries only need a name (no value)
	entry := wayu.ConfigEntry{
		type = .PATH,
		name = "/usr/local/bin",
		value = "",
		line = "",
	}
	testing.expect(t, wayu.is_entry_complete(entry), "PATH entry with name should be complete")
}

@(test)
test_ops_entry_complete_path_empty_name :: proc(t: ^testing.T) {
	entry := wayu.ConfigEntry{
		type = .PATH,
		name = "",
		value = "",
		line = "",
	}
	testing.expect(t, !wayu.is_entry_complete(entry), "PATH entry without name should be incomplete")
}

@(test)
test_ops_path_spec_has_clean :: proc(t: ^testing.T) {
	// Verify PATH_SPEC supports clean action
	testing.expect(t, wayu.PATH_SPEC.has_clean, "PATH_SPEC should support clean")
}

@(test)
test_ops_path_spec_has_dedup :: proc(t: ^testing.T) {
	// Verify PATH_SPEC supports dedup action
	testing.expect(t, wayu.PATH_SPEC.has_dedup, "PATH_SPEC should support dedup")
}

@(test)
test_ops_path_spec_fields_count :: proc(t: ^testing.T) {
	// PATH entries have 1 field (the path itself)
	testing.expect_value(t, wayu.PATH_SPEC.fields_count, 1)
}

@(test)
test_ops_path_spec_type :: proc(t: ^testing.T) {
	testing.expect_value(t, wayu.PATH_SPEC.type, wayu.ConfigEntryType.PATH)
}

@(test)
test_ops_alias_spec_no_clean :: proc(t: ^testing.T) {
	// Verify ALIAS_SPEC does NOT support clean (only PATH does)
	testing.expect(t, !wayu.ALIAS_SPEC.has_clean, "ALIAS_SPEC should not support clean")
}

@(test)
test_ops_alias_spec_no_dedup :: proc(t: ^testing.T) {
	// Verify ALIAS_SPEC does NOT support dedup (only PATH does)
	testing.expect(t, !wayu.ALIAS_SPEC.has_dedup, "ALIAS_SPEC should not support dedup")
}
