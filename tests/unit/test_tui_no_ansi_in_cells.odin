package test_wayu

import wayu "../../src"
import "core:testing"

@(test)
test_render_text_styled_stores_no_ansi_bytes :: proc(t: ^testing.T) {
	screen := wayu.screen_create(80, 3)
	defer wayu.screen_destroy(&screen)

	// If callers accidentally pass an ANSI-laden string as `text`, the cells
	// will contain ESC bytes — which is exactly the bug we must never
	// reintroduce. This test asserts the happy path: a plain rune string
	// produces only printable cells.
	wayu.render_text_styled(&screen, 0, 0, "○ /some/path", wayu.TUI_MUTED)

	for y in 0 ..< screen.height {
		for x in 0 ..< screen.width {
			ch := screen.buffer[y][x].char
			testing.expect(t, ch != 0x1b, "ANSI escape byte found in screen cell")
		}
	}
}

@(test)
test_cell_char_is_single_rune_per_column :: proc(t: ^testing.T) {
	// The diff renderer assumes one cell == one terminal column. Verify that
	// rendering a plain string advances the logical cursor by exactly one
	// column per rune, with no cell holding a multi-byte control sequence.
	screen := wayu.screen_create(20, 1)
	defer wayu.screen_destroy(&screen)

	input := "abc123"
	wayu.render_text_styled(&screen, 0, 0, input, wayu.TUI_PRIMARY)

	expected := []rune{'a', 'b', 'c', '1', '2', '3'}
	for i in 0 ..< len(expected) {
		testing.expect(
			t,
			screen.buffer[0][i].char == expected[i],
			"Cell char should match input rune at same column",
		)
	}
	// Columns beyond the string must remain untouched (space).
	for i in len(expected) ..< screen.width {
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
	screen := wayu.screen_create(30, 1)
	defer wayu.screen_destroy(&screen)

	// "\x1b[32m●\x1b[0m /path" — green-colored glyph followed by a path,
	// exactly the shape that broke the diff renderer.
	poisoned := "\x1b[32m●\x1b[0m /path"
	wayu.render_text_styled(&screen, 0, 0, poisoned, wayu.TUI_MUTED)

	for x in 0 ..< screen.width {
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
	for x in 0 ..< screen.width {
		if screen.buffer[0][x].char == '●' {
			found_glyph = true
			break
		}
	}
	testing.expect(t, found_glyph, "Printable glyph must survive ANSI stripping")
}

// Security audit: no control rune (C0, DEL, C1) may reach the screen buffer,
// as a cell's char or as an attached combining mark, whatever the writer.
@(private = "file")
expect_no_control_cells :: proc(t: ^testing.T, screen: ^wayu.Screen, what: string) {
	for row in screen.buffer {
		for cell in row {
			if cell.char != wayu.CELL_CONTINUATION {
				testing.expectf(
					t,
					!wayu.is_control_rune(cell.char),
					"%s: control char %x in cell",
					what,
					cell.char,
				)
			}
			testing.expectf(
				t,
				cell.comb == 0 || !wayu.is_control_rune(cell.comb),
				"%s: control comb %x",
				what,
				cell.comb,
			)
		}
	}
}

@(test)
test_tui_cells_never_hold_control_runes :: proc(t: ^testing.T) {
	screen := wayu.screen_create(60, 1)
	defer wayu.screen_destroy(&screen)

	// BEL, DEL and an 8-bit CSI used to be zero-width and got attached to the
	// previous glyph as a "combining mark", then emitted raw.
	wayu.render_text_styled(&screen, 0, 0, "a\x07b\x7fc\u009b31md")
	expect_no_control_cells(t, &screen, "render_text_styled")
	testing.expect_value(t, screen.buffer[0][0].comb, 0)
	testing.expect_value(t, screen.buffer[0][1].char, wayu.TUI_CONTROL_PLACEHOLDER)

	wayu.screen_clear(&screen)
	wayu.screen_attach_combining(&screen, 0, 0, 0x07)
	wayu.screen_put_rune(&screen, 1, 0, 0x9d, wayu.Cell{})
	wayu.screen_set_cell(&screen, 2, 0, wayu.Cell{char = 0x1b, comb = 0x07})
	expect_no_control_cells(t, &screen, "cell writers")
	testing.expect_value(t, screen.buffer[0][1].char, wayu.TUI_CONTROL_PLACEHOLDER)
}
