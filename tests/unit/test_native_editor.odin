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

@(test)
test_edit_storage_growth :: proc(t: ^testing.T) {
	e: wayu.Native_Editor
	defer wayu.native_edit_destroy(&e)

	for i in 0 ..< 4096 {
		wayu.native_edit_replace(&e, i, i, "x")
		if i == 1023 || i == 4095 {
			testing.expect_value(
				t,
				e.retained_bytes,
				(i + 1) * (size_of(wayu.Native_Edit_Change) + 1),
			)
		}
	}

	e.cursor = 7
	wayu.native_edit_undo(&e)
	testing.expect_value(t, len(e.line), 4095)
	wayu.native_edit_redo(&e)
	testing.expect_value(t, e.cursor, 7)
	e.undo_limit = size_of(wayu.Native_Edit_Change) + 1
	wayu.native_edit_replace(&e, 0, 0, "世")
	testing.expect_value(t, e.retained_bytes, 0)
}
