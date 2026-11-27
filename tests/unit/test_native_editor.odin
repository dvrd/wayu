package test_wayu

import wayu "../../src"
import "core:testing"

@(test)
test_editor_moves_across_utf8 :: proc(t: ^testing.T) {
	edit := wayu.Native_Edit{"a界", 1}
	edit.cursor = wayu.native_forward(edit)
	testing.expect_value(t, edit.cursor, len(edit.line))
	testing.expect_value(t, wayu.native_back(edit), 1)
}
