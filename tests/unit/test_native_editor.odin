package test_wayu

import wayu "../../src"
import "core:strings"
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

// Undone edits stay charged while they can be redone. A new edit releases
// them, and undo then walks the remaining edits newest first.
@(test)
test_edit_redo_is_released_by_a_new_edit :: proc(t: ^testing.T) {
	e: wayu.Native_Editor
	defer wayu.native_edit_destroy(&e)

	record :: size_of(wayu.Native_Edit_Change)
	wayu.native_edit_replace(&e, 0, 0, "echo ")
	wayu.native_edit_replace(&e, 5, 5, "one")
	wayu.native_edit_replace(&e, 8, 8, " two")
	testing.expect_value(t, e.retained_bytes, 3 * record + 12)

	wayu.native_edit_undo(&e)
	wayu.native_edit_undo(&e)
	testing.expect_value(t, e.line, "echo ")
	testing.expect_value(t, e.cursor, 5)
	testing.expect_value(t, e.retained_bytes, 3 * record + 12)

	wayu.native_edit_replace(&e, 5, 5, "new")
	testing.expect_value(t, e.retained_bytes, 2 * record + 8)
	wayu.native_edit_redo(&e)
	testing.expect_value(t, e.line, "echo new")

	wayu.native_edit_undo(&e)
	testing.expect_value(t, e.line, "echo ")
	wayu.native_edit_undo(&e)
	wayu.native_edit_undo(&e)
	testing.expect_value(t, e.line, "")
	testing.expect_value(t, e.cursor, 0)

	wayu.native_edit_redo(&e)
	wayu.native_edit_redo(&e)
	wayu.native_edit_redo(&e)
	testing.expect_value(t, e.line, "echo new")
	testing.expect_value(t, e.cursor, 8)
}

// Replacing a multibyte range and inserting a newline are single edits that
// undo to the exact earlier bytes and cursor.
@(test)
test_edit_undo_restores_multibyte_and_multiline_text :: proc(t: ^testing.T) {
	e: wayu.Native_Editor
	defer wayu.native_edit_destroy(&e)

	wayu.native_edit_replace(&e, 0, 0, "a界b")
	e.cursor = 1
	wayu.native_edit_replace(&e, 1, 4, "世界")
	testing.expect_value(t, e.line, "a世界b")
	testing.expect_value(t, e.cursor, 7)
	wayu.native_edit_replace(&e, 7, 7, "\n")
	testing.expect_value(t, e.line, "a世界\nb")

	wayu.native_edit_undo(&e)
	testing.expect_value(t, e.line, "a世界b")
	wayu.native_edit_undo(&e)
	testing.expect_value(t, e.line, "a界b")
	testing.expect_value(t, e.cursor, 1)
	wayu.native_edit_redo(&e)
	wayu.native_edit_redo(&e)
	testing.expect_value(t, e.line, "a世界\nb")
	testing.expect_value(t, e.cursor, 8)
}

// The byte limit covers undo and redo together. The oldest edits expire
// first, and an edit larger than the whole limit still changes the line.
@(test)
test_edit_undo_limit_evicts_oldest_edits :: proc(t: ^testing.T) {
	record :: size_of(wayu.Native_Edit_Change)
	e := wayu.Native_Editor {
		undo_limit = 2 * record + 6,
	}
	defer wayu.native_edit_destroy(&e)

	wayu.native_edit_replace(&e, 0, 0, "aaaa")
	wayu.native_edit_replace(&e, 4, 4, "bb")
	testing.expect_value(t, e.retained_bytes, 2 * record + 6)
	wayu.native_edit_replace(&e, 6, 6, "c")
	testing.expect_value(t, e.retained_bytes, 2 * record + 3)

	wayu.native_edit_undo(&e)
	wayu.native_edit_undo(&e)
	wayu.native_edit_undo(&e)
	testing.expect_value(t, e.line, "aaaa")
	testing.expect_value(t, e.cursor, 4)

	// A new edit first releases the edits that were undone.
	wayu.native_edit_replace(&e, 4, 4, "dd")
	testing.expect_value(t, e.retained_bytes, record + 2)

	paste := strings.repeat("p", 3 * record, context.temp_allocator)
	wayu.native_edit_replace(&e, 0, len(e.line), paste)
	testing.expect_value(t, e.line, paste)
	testing.expect_value(t, e.cursor, len(paste))
	testing.expect_value(t, e.retained_bytes, 0)
	wayu.native_edit_undo(&e)
	testing.expect_value(t, e.line, paste)
}
