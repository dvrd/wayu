package test_wayu

// Regression test for the TUI scroll bug fixed in commit 49bf668.
// See thoughts/scroll_bug_spec.md for the full diagnosis.
//
// Root cause: ANSI escape bytes embedded in list-item strings were written
// into Screen.Cell.char, drifting the diff renderer's logical cursor from
// the PTY cursor. Invariant: no cell in Screen.buffer may hold 0x1b as .char;
// color must live exclusively in .fg / .bg.

import "core:testing"
import tui "../../src/tui"

@(test)
test_render_text_styled_stores_no_ansi_bytes :: proc(t: ^testing.T) {
	screen := tui.screen_create(80, 3)
	defer tui.screen_destroy(&screen)

	// If callers accidentally pass an ANSI-laden string as `text`, the cells
	// will contain ESC bytes — which is exactly the bug we must never
	// reintroduce. This test asserts the happy path: a plain rune string
	// produces only printable cells.
	tui.render_text_styled(&screen, 0, 0, "○ /some/path", tui.TUI_MUTED)

	for y in 0..<screen.height {
		for x in 0..<screen.width {
			ch := screen.buffer[y][x].char
			testing.expect(
				t,
				ch != 0x1b,
				"ANSI escape byte found in screen cell — see thoughts/scroll_bug_spec.md",
			)
		}
	}
}

@(test)
test_cell_char_is_single_rune_per_column :: proc(t: ^testing.T) {
	// The diff renderer assumes one cell == one terminal column. Verify that
	// rendering a plain string advances the logical cursor by exactly one
	// column per rune, with no cell holding a multi-byte control sequence.
	screen := tui.screen_create(20, 1)
	defer tui.screen_destroy(&screen)

	input := "abc123"
	tui.render_text_styled(&screen, 0, 0, input, tui.TUI_PRIMARY)

	expected := []rune{'a', 'b', 'c', '1', '2', '3'}
	for i in 0..<len(expected) {
		testing.expect(
			t,
			screen.buffer[0][i].char == expected[i],
			"Cell char should match input rune at same column",
		)
	}
	// Columns beyond the string must remain untouched (space).
	for i in len(expected)..<screen.width {
		testing.expect(
			t,
			screen.buffer[0][i].char == ' ',
			"Cells past end of text should still be spaces",
		)
	}
}
