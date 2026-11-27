package test_wayu

import wayu "../../src"
import "core:testing"

@(test)
test_commit_pin_length_boundaries :: proc(t: ^testing.T) {
	testing.expect(t, wayu.is_valid_commit_sha("abcdef0"))
	testing.expect(t, !wayu.is_valid_commit_sha("abcdef"))
	testing.expect(t, !wayu.is_valid_commit_sha("abcdeg0"))
}
