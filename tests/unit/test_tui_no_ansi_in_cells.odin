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

// Option A — defensive guard. Feed render_text_styled an ANSI-laden string
// (mimicking the pre-49bf668 state where callers concatenated color into the
// char stream). The render layer must strip ESC bytes so the scroll bug
// cannot reappear even if a caller regresses.
@(test)
test_render_text_styled_strips_ansi_escape_bytes :: proc(t: ^testing.T) {
	screen := tui.screen_create(30, 1)
	defer tui.screen_destroy(&screen)

	// "\x1b[32m●\x1b[0m /path" — green-colored glyph followed by a path,
	// exactly the shape that broke the diff renderer.
	poisoned := "\x1b[32m●\x1b[0m /path"
	tui.render_text_styled(&screen, 0, 0, poisoned, tui.TUI_MUTED)

	for x in 0..<screen.width {
		testing.expect(
			t,
			screen.buffer[0][x].char != 0x1b,
			"render_text_styled must strip ESC bytes from cells",
		)
	}

	// Visible runes that survive stripping: `[32m●[0m /path`.
	// We don't assert the full sequence (the stripped form is intentionally
	// ugly to signal the caller bug) — only that printable content landed
	// and the glyph `●` is present somewhere in the row.
	found_glyph := false
	for x in 0..<screen.width {
		if screen.buffer[0][x].char == '●' {
			found_glyph = true
			break
		}
	}
	testing.expect(t, found_glyph, "Printable glyph must survive ANSI stripping")
}

// Option B — caller-level test. render_list_item is the function that the
// original bug lived in: it used to receive "\x1b[32m●\x1b[0m /path" and
// write ESC bytes into cells. Post-fix, it receives "● /path" and uses
// split_list_item_glyph to map the glyph rune to Cell.fg. This test pins
// that contract so a future refactor can't re-introduce inline ANSI.
@(test)
test_render_list_item_maps_glyph_to_fg_not_char :: proc(t: ^testing.T) {
	screen := tui.screen_create(60, 1)
	defer tui.screen_destroy(&screen)

	// Realistic TUI input: glyph rune + space + text, no ANSI.
	tui.render_list_item(&screen, 2, 0, "● /some/path", 50, false)

	// No ESC byte may appear anywhere after rendering.
	for x in 0..<screen.width {
		testing.expect(
			t,
			screen.buffer[0][x].char != 0x1b,
			"render_list_item must not emit ESC bytes into the cell buffer",
		)
	}

	// The glyph must be rendered with the WAYU_ACTIVE source color via Cell.fg —
	// not via inline ANSI in Cell.char. Scan the row for the `●` cell.
	glyph_x := -1
	for x in 0..<screen.width {
		if screen.buffer[0][x].char == '●' {
			glyph_x = x
			break
		}
	}
	testing.expect(t, glyph_x >= 0, "Glyph `●` must be present as a Cell.char")
	if glyph_x >= 0 {
		testing.expect(
			t,
			screen.buffer[0][glyph_x].fg == tui.TUI_SOURCE_WAYU_ACTIVE,
			"Glyph cell must carry source color in Cell.fg, not inline ANSI",
		)
	}
}
