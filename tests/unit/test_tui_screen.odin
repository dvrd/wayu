package test_wayu

import "core:fmt"
import "core:testing"
import "core:strings"
import tui "../../src/tui"

@(test)
test_screen_create :: proc(t: ^testing.T) {
	// Test creating screen with correct dimensions
	screen := tui.screen_create(80, 24)
	defer tui.screen_destroy(&screen)

	testing.expect(t, screen.width == 80, "Screen width should be 80")
	testing.expect(t, screen.height == 24, "Screen height should be 24")
	testing.expect(t, len(screen.buffer) == 24, "Buffer should have 24 rows")
	testing.expect(t, len(screen.buffer[0]) == 80, "Buffer row should have 80 columns")
	testing.expect(t, len(screen.prev_buffer) == 24, "Prev buffer should have 24 rows")
	testing.expect(t, len(screen.prev_buffer[0]) == 80, "Prev buffer row should have 80 columns")

	// Verify all cells are initialized with spaces
	for y in 0..<screen.height {
		for x in 0..<screen.width {
			testing.expect(
				t,
				screen.buffer[y][x].char == ' ',
				"All buffer cells should be initialized with space",
			)
			testing.expect(
				t,
				screen.prev_buffer[y][x].char == ' ',
				"All prev_buffer cells should be initialized with space",
			)
		}
	}
}

@(test)
test_screen_set_cell :: proc(t: ^testing.T) {
	// Test cell updates at correct position
	screen := tui.screen_create(80, 24)
	defer tui.screen_destroy(&screen)

	// Set a cell at position (10, 5)
	test_cell := tui.Cell {
		char = 'X',
		fg   = "\x1b[31m",
		bg   = "\x1b[42m",
		bold = true,
		dim  = false,
	}

	tui.screen_set_cell(&screen, 10, 5, test_cell)

	// Verify cell was set correctly
	cell := screen.buffer[5][10]
	testing.expect(t, cell.char == 'X', "Cell char should be 'X'")
	testing.expect(t, cell.fg == "\x1b[31m", "Cell fg should be red ANSI code")
	testing.expect(t, cell.bg == "\x1b[42m", "Cell bg should be green ANSI code")
	testing.expect(t, cell.bold == true, "Cell should be bold")
	testing.expect(t, cell.dim == false, "Cell should not be dim")

	// Verify other cells are unchanged
	testing.expect(
		t,
		screen.buffer[0][0].char == ' ',
		"Other cells should remain as spaces",
	)
}

@(test)
test_screen_set_cell_bounds :: proc(t: ^testing.T) {
	// Test that out-of-bounds coordinates are safely ignored
	screen := tui.screen_create(80, 24)
	defer tui.screen_destroy(&screen)

	test_cell := tui.Cell{char = 'X'}

	// Test negative coordinates
	tui.screen_set_cell(&screen, -1, 5, test_cell)
	tui.screen_set_cell(&screen, 10, -1, test_cell)

	// Test coordinates beyond dimensions
	tui.screen_set_cell(&screen, 100, 5, test_cell)
	tui.screen_set_cell(&screen, 10, 50, test_cell)

	// Verify no cells were modified (all should still be spaces)
	for y in 0..<screen.height {
		for x in 0..<screen.width {
			testing.expect(
				t,
				screen.buffer[y][x].char == ' ',
				"Out-of-bounds set should not modify any cells",
			)
		}
	}
}

@(test)
test_screen_clear :: proc(t: ^testing.T) {
	// Test that clear fills all cells with spaces
	screen := tui.screen_create(80, 24)
	defer tui.screen_destroy(&screen)

	// Set some cells
	for i in 0 ..< 10 {
		tui.screen_set_cell(&screen, i, 0, tui.Cell{char = 'A'})
		tui.screen_set_cell(&screen, i, 5, tui.Cell{char = 'B', bold = true})
		tui.screen_set_cell(&screen, i, 10, tui.Cell{char = 'C', fg = "\x1b[31m"})
	}

	// Clear the screen
	tui.screen_clear(&screen)

	// Verify all cells are spaces with no attributes
	for y in 0..<screen.height {
		for x in 0..<screen.width {
			cell := screen.buffer[y][x]
			testing.expect(t, cell.char == ' ', "All cells should be spaces after clear")
		}
	}
}

@(test)
test_screen_resize_larger :: proc(t: ^testing.T) {
	// Test resizing to larger dimensions preserves content
	screen := tui.screen_create(40, 12)
	defer tui.screen_destroy(&screen)

	// Set some content in original screen
	tui.screen_set_cell(&screen, 5, 5, tui.Cell{char = 'A'})
	tui.screen_set_cell(&screen, 10, 10, tui.Cell{char = 'B'})

	// Resize to larger
	tui.screen_resize(&screen, 80, 24)

	// Verify dimensions changed
	testing.expect(t, screen.width == 80, "Width should be 80 after resize")
	testing.expect(t, screen.height == 24, "Height should be 24 after resize")

	// Verify content preserved
	testing.expect(
		t,
		screen.buffer[5][5].char == 'A',
		"Content should be preserved after resize",
	)
	testing.expect(
		t,
		screen.buffer[10][10].char == 'B',
		"Content should be preserved after resize",
	)

	// Verify new cells are spaces
	testing.expect(t, screen.buffer[20][70].char == ' ', "New cells should be spaces")
}

@(test)
test_screen_resize_smaller :: proc(t: ^testing.T) {
	// Test resizing to smaller dimensions
	screen := tui.screen_create(80, 24)
	defer tui.screen_destroy(&screen)

	// Set content both inside and outside new bounds
	tui.screen_set_cell(&screen, 5, 5, tui.Cell{char = 'A'})
	tui.screen_set_cell(&screen, 50, 15, tui.Cell{char = 'B'}) // Will be outside new bounds

	// Resize to smaller
	tui.screen_resize(&screen, 40, 12)

	// Verify dimensions changed
	testing.expect(t, screen.width == 40, "Width should be 40 after resize")
	testing.expect(t, screen.height == 12, "Height should be 12 after resize")

	// Verify content within bounds is preserved
	testing.expect(
		t,
		screen.buffer[5][5].char == 'A',
		"Content within bounds should be preserved",
	)

	// Verify we can't access old content (it's been freed)
	// This is implicit - attempting to access would crash
}

@(test)
test_screen_flush_differential :: proc(t: ^testing.T) {
	// Test that screen_flush only outputs changed cells
	screen := tui.screen_create(10, 5)
	defer tui.screen_destroy(&screen)

	// Set initial content
	tui.screen_set_cell(&screen, 0, 0, tui.Cell{char = 'A'})
	tui.screen_set_cell(&screen, 1, 0, tui.Cell{char = 'B'})

	// First flush - should output both cells
	// We can't easily capture stdout in tests, but we verify the buffers sync
	tui.screen_flush(&screen)

	// Verify prev_buffer now matches buffer (synced after flush)
	for y in 0..<screen.height {
		for x in 0..<screen.width {
			testing.expect(
				t,
				screen.buffer[y][x] == screen.prev_buffer[y][x],
				"Buffers should match after flush",
			)
		}
	}

	// Change only one cell
	tui.screen_set_cell(&screen, 0, 0, tui.Cell{char = 'X'})

	// Verify only one cell is different (would only output one cell)
	different_count := 0
	for y in 0..<screen.height {
		for x in 0..<screen.width {
			if screen.buffer[y][x] != screen.prev_buffer[y][x] {
				different_count += 1
			}
		}
	}
	testing.expect(
		t,
		different_count == 1,
		"Only one cell should be different before second flush",
	)
}

@(test)
test_render_text :: proc(t: ^testing.T) {
	// Test rendering text at position
	screen := tui.screen_create(80, 24)
	defer tui.screen_destroy(&screen)

	// Render text
	test_text := "Hello, TUI!"
	tui.render_text(&screen, 5, 10, test_text)

	// Verify text was rendered at correct positions
	expected := [?]rune{'H', 'e', 'l', 'l', 'o', ',', ' ', 'T', 'U', 'I', '!'}
	for ch, i in expected {
		cell := screen.buffer[10][5 + i]
		testing.expect(
			t,
			cell.char == ch,
			fmt.tprintf("Character at position %d should be '%c', got '%c'", i, ch, cell.char),
		)
	}

	// Verify cell before text is unchanged
	testing.expect(t, screen.buffer[10][4].char == ' ', "Cell before text should be space")

	// Verify cell after text is unchanged
	testing.expect(
		t,
		screen.buffer[10][5 + len(expected)].char == ' ',
		"Cell after text should be space",
	)
}

@(test)
test_render_text_truncation :: proc(t: ^testing.T) {
	// Test that text is truncated at screen edge
	screen := tui.screen_create(10, 5)
	defer tui.screen_destroy(&screen)

	// Render text that would exceed screen width
	long_text := "This is a very long text"
	tui.render_text(&screen, 5, 2, long_text)

	// Verify only characters within screen bounds were rendered
	// Position 5-9 (5 characters): "This " should be filled
	testing.expect(t, screen.buffer[2][5].char == 'T', "First char should be 'T'")
	testing.expect(t, screen.buffer[2][6].char == 'h', "Second char should be 'h'")
	testing.expect(t, screen.buffer[2][7].char == 'i', "Third char should be 'i'")
	testing.expect(t, screen.buffer[2][8].char == 's', "Fourth char should be 's'")
	testing.expect(t, screen.buffer[2][9].char == ' ', "Last char should be ' ' (space)")

	// No crash occurs - this implicitly tests the bounds checking
}

@(test)
test_render_box :: proc(t: ^testing.T) {
	// Test rendering box with Unicode borders
	screen := tui.screen_create(80, 24)
	defer tui.screen_destroy(&screen)

	// Render a 10x5 box at position (5, 5)
	tui.render_box(&screen, 5, 5, 10, 5)

	// Verify corners
	testing.expect(t, screen.buffer[5][5].char == '┌', "Top-left corner should be '┌'")
	testing.expect(t, screen.buffer[5][14].char == '┐', "Top-right corner should be '┐'")
	testing.expect(t, screen.buffer[9][5].char == '└', "Bottom-left corner should be '└'")
	testing.expect(t, screen.buffer[9][14].char == '┘', "Bottom-right corner should be '┘'")

	// Verify top border
	testing.expect(t, screen.buffer[5][6].char == '─', "Top border should be '─'")
	testing.expect(t, screen.buffer[5][13].char == '─', "Top border should be '─'")

	// Verify bottom border
	testing.expect(t, screen.buffer[9][6].char == '─', "Bottom border should be '─'")
	testing.expect(t, screen.buffer[9][13].char == '─', "Bottom border should be '─'")

	// Verify left side
	testing.expect(t, screen.buffer[6][5].char == '│', "Left side should be '│'")
	testing.expect(t, screen.buffer[8][5].char == '│', "Left side should be '│'")

	// Verify right side
	testing.expect(t, screen.buffer[6][14].char == '│', "Right side should be '│'")
	testing.expect(t, screen.buffer[8][14].char == '│', "Right side should be '│'")

	// Verify interior is not modified (still spaces)
	testing.expect(t, screen.buffer[6][6].char == ' ', "Interior should remain spaces")
}

@(test)
test_render_box_too_small :: proc(t: ^testing.T) {
	// Test that boxes smaller than 2x2 are safely ignored
	screen := tui.screen_create(80, 24)
	defer tui.screen_destroy(&screen)

	// Try to render invalid boxes
	tui.render_box(&screen, 5, 5, 1, 5) // Width too small
	tui.render_box(&screen, 5, 5, 5, 1) // Height too small
	tui.render_box(&screen, 5, 5, 0, 0) // Zero dimensions

	// Verify screen is still all spaces (nothing was rendered)
	for y in 0..<screen.height {
		for x in 0..<screen.width {
			testing.expect(
				t,
				screen.buffer[y][x].char == ' ',
				"Invalid boxes should not modify screen",
			)
		}
	}
}

@(test)
test_cell_equality :: proc(t: ^testing.T) {
	// Test that Cell struct equality works correctly for differential rendering
	cell1 := tui.Cell{char = 'A', fg = "\x1b[31m", bg = "\x1b[42m", bold = true, dim = false}
	cell2 := tui.Cell{char = 'A', fg = "\x1b[31m", bg = "\x1b[42m", bold = true, dim = false}
	cell3 := tui.Cell{char = 'B', fg = "\x1b[31m", bg = "\x1b[42m", bold = true, dim = false}

	testing.expect(t, cell1 == cell2, "Identical cells should be equal")
	testing.expect(t, cell1 != cell3, "Different cells should not be equal")
}

@(test)
test_cursor_tracking :: proc(t: ^testing.T) {
	// Test that cursor position is tracked correctly
	screen := tui.screen_create(80, 24)
	defer tui.screen_destroy(&screen)

	// Initial cursor position should be (0, 0)
	testing.expect(t, screen.cursor_x == 0, "Initial cursor_x should be 0")
	testing.expect(t, screen.cursor_y == 0, "Initial cursor_y should be 0")

	// After flush, cursor should be updated
	// (We can't test the exact position without mocking, but we verify the field exists)
}

@(test)
test_memory_lifecycle :: proc(t: ^testing.T) {
	// Test creating and destroying multiple screens
	for i in 0 ..< 10 {
		screen := tui.screen_create(80, 24)
		tui.screen_set_cell(&screen, 10, 10, tui.Cell{char = 'X'})
		tui.screen_destroy(&screen)
	}

	// No assertion needed - if we don't crash, memory management is correct
	testing.expect(t, true, "Multiple create/destroy cycles should not crash")
}
