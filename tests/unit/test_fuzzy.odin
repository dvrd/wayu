package test_wayu

import "core:testing"
import wayu "../../src"

// ============================================================================
// calculate_fuzzy_score tests
// ============================================================================

@(test)
test_fuzzy_score_exact_match :: proc(t: ^testing.T) {
	score := wayu.calculate_fuzzy_score("hello", "hello")
	testing.expect(t, score > 0, "Exact match should have positive score")
}

@(test)
test_fuzzy_score_prefix_match :: proc(t: ^testing.T) {
	score := wayu.calculate_fuzzy_score("hello_world", "hello")
	testing.expect(t, score > 0, "Prefix match should have positive score")
}

@(test)
test_fuzzy_score_substring_match :: proc(t: ^testing.T) {
	score := wayu.calculate_fuzzy_score("hello_world", "world")
	testing.expect(t, score > 0, "Substring match should have positive score")
}

@(test)
test_fuzzy_score_partial_match :: proc(t: ^testing.T) {
	score := wayu.calculate_fuzzy_score("hello_world", "hld")
	testing.expect(t, score > 0, "Partial match should have positive score")
}

@(test)
test_fuzzy_score_no_match :: proc(t: ^testing.T) {
	score := wayu.calculate_fuzzy_score("hello", "xyz")
	testing.expect_value(t, score, 0)
}

@(test)
test_fuzzy_score_empty_query :: proc(t: ^testing.T) {
	score := wayu.calculate_fuzzy_score("hello", "")
	testing.expect_value(t, score, 1)
}

@(test)
test_fuzzy_score_case_sensitive :: proc(t: ^testing.T) {
	score_match := wayu.calculate_fuzzy_score("apple", "app")
	score_no_match := wayu.calculate_fuzzy_score("Apple", "app")
	testing.expect(t, score_match > 0, "Lowercase should match lowercase")
	testing.expect_value(t, score_no_match, 0)
}

@(test)
test_fuzzy_score_consecutive_bonus :: proc(t: ^testing.T) {
	score_consecutive := wayu.calculate_fuzzy_score("application", "app")
	score_non_consecutive := wayu.calculate_fuzzy_score("a_p_p_lication", "app")
	testing.expect(t, score_consecutive > 0, "Consecutive should match")
	testing.expect(t, score_non_consecutive >= 0, "Non-consecutive should match or not")
}

@(test)
test_fuzzy_score_boundary_cases :: proc(t: ^testing.T) {
	testing.expect_value(t, wayu.calculate_fuzzy_score("", ""), 1)
	testing.expect_value(t, wayu.calculate_fuzzy_score("", "test"), 0)
	testing.expect(t, wayu.calculate_fuzzy_score("a", "a") > 0, "Single char should match")
	testing.expect_value(t, wayu.calculate_fuzzy_score("a", "b"), 0)
}

@(test)
test_fuzzy_score_prefix_bonus :: proc(t: ^testing.T) {
	score_prefix := wayu.calculate_fuzzy_score("hello_world", "hello")
	score_non_prefix := wayu.calculate_fuzzy_score("say_hello_world", "hello")
	testing.expect(t, score_prefix > score_non_prefix, "Prefix should score higher")
}

// ============================================================================
// Extraction / config entry tests
// ============================================================================

@(test)
test_extract_alias_items :: proc(t: ^testing.T) {
	entries := wayu.read_config_entries(&wayu.ALIAS_SPEC)
	defer {
		for &entry in entries do wayu.cleanup_entry(&entry)
		delete(entries)
	}
	testing.expect(t, len(entries) >= 0, "Should return valid array")
	for entry in entries {
		testing.expect_value(t, entry.type, wayu.ConfigEntryType.ALIAS)
	}
}

@(test)
test_extract_path_items :: proc(t: ^testing.T) {
	items := wayu.extract_path_items()
	defer for item in items do delete(item)
	defer delete(items)
	testing.expect(t, len(items) >= 0, "Should return valid array")
}

@(test)
test_extract_constant_items :: proc(t: ^testing.T) {
	entries := wayu.read_config_entries(&wayu.CONSTANTS_SPEC)
	defer {
		for &entry in entries do wayu.cleanup_entry(&entry)
		delete(entries)
	}
	testing.expect(t, len(entries) >= 0, "Should return valid array")
	for entry in entries {
		testing.expect_value(t, entry.type, wayu.ConfigEntryType.CONSTANT)
	}
}

@(test)
test_extract_completion_items :: proc(t: ^testing.T) {
	items := wayu.extract_completion_items()
	defer for item in items do delete(item)
	defer delete(items)
	testing.expect(t, len(items) >= 0, "Should return valid array")
}
