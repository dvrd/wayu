package test_wayu

import wayu "../../src"
import "core:testing"

@(test)
test_search_match_labels :: proc(t: ^testing.T) {
	testing.expect_value(t, wayu.match_type_to_string_short(.Prefix), "prefix")
	testing.expect_value(t, wayu.match_type_to_string_short(.Acronym), "acronym")
}
