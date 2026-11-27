package test_wayu

import wayu "../../src"
import "core:testing"

@(test)
test_native_region_rgb_and_attributes :: proc(t: ^testing.T) {
	testing.expect_value(t, wayu.native_region_style("bold,fg=#0102ff"), "\x1b[1;38;2;1;2;255m")
	testing.expect_value(t, wayu.native_region_style("fg=#zzzzzz"), "")
}
