package test_wayu

import "core:testing"
import "core:fmt"
import wayu "../src"

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
test_fuzzy_find_basic :: proc(t: ^testing.T) {
	items := []string{"hello", "world", "help", "held"}
	results := wayu.fuzzy_find(items, "hel")
	defer delete(results)

	testing.expect(t, len(results) >= 2, "Should find at least 2 matches")

	// Results should be sorted by score
	if len(results) >= 2 {
		testing.expect(t, results[0].score >= results[1].score, "Results should be sorted by score")
	}
}

@(test)
test_fuzzy_find_empty_query :: proc(t: ^testing.T) {
	items := []string{"hello", "world"}
	results := wayu.fuzzy_find(items, "")
	defer delete(results)

	testing.expect_value(t, len(results), len(items))
	for result in results {
		testing.expect_value(t, result.score, 0)
	}
}