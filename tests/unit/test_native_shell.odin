package test_wayu

import wayu "../../src"
import "core:testing"

@(test)
test_continuation_for_unfinished_if :: proc(t: ^testing.T) {
	testing.expect(t, wayu.native_incomplete("if true; then"))
	testing.expect(t, !wayu.native_incomplete("if true; then echo yes; fi"))
}
