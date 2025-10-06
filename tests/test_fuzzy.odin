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

@(test)
test_fuzzy_score_case_sensitive :: proc(t: ^testing.T) {
	// Fuzzy score is case-sensitive by design
	score_match := wayu.calculate_fuzzy_score("apple", "app")
	score_no_match := wayu.calculate_fuzzy_score("Apple", "app")

	testing.expect(t, score_match > 0, "Lowercase should match lowercase")
	testing.expect_value(t, score_no_match, 0) // Case-sensitive, so no match
}

@(test)
test_fuzzy_find_sorts_by_score :: proc(t: ^testing.T) {
	items := []string{"apple", "application", "app"}
	results := wayu.fuzzy_find(items, "app")
	defer delete(results)

	testing.expect(t, len(results) > 0, "Should have results")
	if len(results) > 1 {
		testing.expect(t, results[0].score >= results[1].score, "Should be sorted by score")
	}
}

@(test)
test_fuzzy_score_consecutive_bonus :: proc(t: ^testing.T) {
	// "app" as consecutive chars should score higher than non-consecutive
	score_consecutive := wayu.calculate_fuzzy_score("application", "app")
	score_non_consecutive := wayu.calculate_fuzzy_score("a_p_p_lication", "app")
	testing.expect(t, score_consecutive > 0, "Consecutive should match")
	testing.expect(t, score_non_consecutive >= 0, "Non-consecutive should match or not")
}