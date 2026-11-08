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

// ============================================================================
// clean / dedup decision masks (OKAMI-168)
// ============================================================================

@(test)
test_ops_clean_mask_keeps_unresolved_and_env_paths :: proc(t: ^testing.T) {
	existing := os.get_env("HOME", context.temp_allocator)
	consts := []wayu.ConfigEntry{{type = .CONSTANT, name = "WAYU_OPS_ROOT", value = existing}}
	entries := []wayu.TomlPathEntry{
		{key = "unset", path = "$WAYU_OPS_SURELY_UNSET_VAR/bin"}, // unknown → kept
		{key = "toml_env", path = "${WAYU_OPS_ROOT}"},           // [env] → exists → kept
		{key = "gone", path = "/nonexistent/wayu_ops_clean_gone"},
		{key = "gone_env", path = "$WAYU_OPS_ROOT/wayu_ops_clean_gone"},
	}
	drop := wayu.path_clean_drop_mask(entries, consts)
	defer delete(drop)
	testing.expect_value(t, drop[0], false)
	testing.expect_value(t, drop[1], false)
	testing.expect_value(t, drop[2], true)
	testing.expect_value(t, drop[3], true)
}

@(test)
test_ops_dedup_mask_uses_toml_env :: proc(t: ^testing.T) {
	consts := []wayu.ConfigEntry{{type = .CONSTANT, name = "WAYU_OPS_TOOLS", value = "/opt/tools"}}
	entries := []wayu.TomlPathEntry{
		{key = "a", path = "$WAYU_OPS_TOOLS/bin"},
		{key = "b", path = "/opt/tools/bin"},                 // same dir via [env]
		{key = "c", path = "$WAYU_OPS_SURELY_UNSET_VAR/bin"},
		{key = "d", path = "$WAYU_OPS_SURELY_UNSET_VAR/bin"}, // byte-identical unresolved
		{key = "e", path = "$WAYU_OPS_SURELY_UNSET_VAR/x"},
	}
	drop := wayu.path_dedup_drop_mask(entries, consts)
	defer delete(drop)
	testing.expect_value(t, drop[0], false)
	testing.expect_value(t, drop[1], true)
	testing.expect_value(t, drop[2], false)
	testing.expect_value(t, drop[3], true)
	testing.expect_value(t, drop[4], false)
}

@(test)
test_ops_drop_key_conflict :: proc(t: ^testing.T) {
	entries := []wayu.TomlPathEntry{{key = "a", path = "/x"}, {key = "a", path = "/x"}, {key = "b", path = "/y"}}
	testing.expect_value(t, wayu.path_drop_key_conflict(entries, []bool{false, true, false}), "a")
	testing.expect_value(t, wayu.path_drop_key_conflict(entries, []bool{true, true, false}), "")
	testing.expect_value(t, wayu.path_drop_key_conflict(entries, []bool{false, false, true}), "")
}
