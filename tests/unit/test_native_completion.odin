package test_wayu

import wayu "../../src"
import "core:testing"

@(test)
test_completion_preserves_following_pipeline :: proc(t: ^testing.T) {
	line := `cat "two words"|sort`
	testing.expect_value(t, wayu.native_completion_end(line, 7, '"'), 15)
	testing.expect_value(t, wayu.native_completion_end(`cat two\ words next`, 5, 0), 14)
}
