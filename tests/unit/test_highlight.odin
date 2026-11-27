package test_wayu

import wayu "../../src"
import "core:testing"

@(test)
test_highlight_names_round_trip :: proc(t: ^testing.T) {
	for style, index in wayu.HIGHLIGHT_STYLES {
		testing.expect_value(t, wayu.highlight_style_index(style.name), index)
	}

	testing.expect_value(t, wayu.highlight_style_index("missing-style"), -1)
}
