package wayu

import "core:fmt"
import "core:os"
import "core:strings"

// Initialize TUI subsystems.
// Raw mode is entered BEFORE the alternate screen so a failure exits with the
// terminal untouched (os.exit skips deferred cleanup).
tui_init :: proc() {
	if !tui_enable_raw_mode() {
		fmt.eprintln("Error: Failed to enable raw mode")
		wayu_exit(EXIT_OSERR)
	}

	tui_install_signal_handlers()
	tui_load_esc_delay()
	tui_stderr_capture_begin() // replayed if the TUI dies (OKAMI-262)
	tui_lifecycle_init() // Enter alt screen, hide cursor, SIGWINCH handler
	tui_set_screen_active(true)
}

// Cleanup TUI subsystems
tui_cleanup :: proc() {
	tui_stderr_capture_end(replay = false)
	tui_lifecycle_cleanup() // Exit alt screen, show cursor
	tui_set_screen_active(false)
	tui_disable_raw_mode() // Restore cooked mode
	tui_uninstall_signal_handlers()
}

// Flush screen with differential rendering.
// force_full_render clears the terminal and repaints every cell — used for the
// first frame, after resizes, and after mutations that may have written to
// the terminal behind our back.
screen_flush :: proc(screen: ^Screen, force_full_render := false, output_file := os.stdout) {
	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	if force_full_render {
		strings.write_string(&builder, "\x1b[0m\x1b[2J")
		// Terminal cursor position is unknown: force a move before the first cell.
		screen.cursor_x = -1
		screen.cursor_y = -1
	}

	use_color := tui_color_mode != .ASCII

	// Track what ANSI state the terminal is currently in so we can
	// emit only the minimal escape sequences needed.
	active_fg: string
	active_bg: string
	active_bold: bool
	active_dim: bool

	for y in 0 ..< screen.height {
		for x in 0 ..< screen.width {
			curr := screen.buffer[y][x]
			prev := screen.prev_buffer[y][x]

			// Skip unchanged cells (KEY OPTIMIZATION)
			// But force render on first frame
			if !force_full_render && curr == prev do continue

			// Right half of a wide glyph: the lead cell already covered it.
			if curr.char == CELL_CONTINUATION do continue

			// Debug assertion: no ANSI escape bytes in cell buffer
			when ODIN_DEBUG {
				assert(curr.char != 0x1b, "ANSI escape in screen cell")
			}

			fg := tui_theme_color(curr.fg) if use_color else ""
			bg := tui_theme_color(curr.bg) if use_color else ""

			// Move cursor if needed (minimize cursor movement)
			if x != screen.cursor_x || y != screen.cursor_y {
				fmt.sbprintf(&builder, "\x1b[%d;%dH", y + 1, x + 1)
				screen.cursor_x = x
				screen.cursor_y = y
				// After a cursor jump we don't know what terminal state is,
				// so reset our tracking to force re-emission of attributes.
				active_fg = ""
				active_bg = ""
				active_bold = false
				active_dim = false
			}

			// Reset all attributes if the cell has none but terminal has some
			needs_reset := false
			if (active_bold && !curr.bold) ||
			   (active_dim && !curr.dim) ||
			   (active_fg != "" && fg == "") ||
			   (active_bg != "" && bg == "") {
				needs_reset = true
			}

			if needs_reset {
				strings.write_string(&builder, "\x1b[0m")
				active_fg = ""
				active_bg = ""
				active_bold = false
				active_dim = false
			}

			// Apply bold if needed
			if curr.bold && !active_bold {
				strings.write_string(&builder, "\x1b[1m")
				active_bold = true
			}

			// Apply dim if needed
			if curr.dim && !active_dim {
				strings.write_string(&builder, "\x1b[2m")
				active_dim = true
			}

			// Apply foreground color if needed (adapted to the color profile)
			if fg != "" && fg != active_fg {
				write_tui_color(&builder, fg)
				active_fg = fg
			}

			// Apply background color if needed
			if bg != "" && bg != active_bg {
				write_tui_color(&builder, bg)
				active_bg = bg
			}

			// Write character; wide glyphs advance the terminal cursor by two.
			ch := curr.char
			if ch < 0x20 do ch = ' '
			strings.write_rune(&builder, ch)
			if curr.comb != 0 do strings.write_rune(&builder, curr.comb) // zero columns
			screen.cursor_x += max(1, get_rune_width(ch))
		}
	}

	// Reset attributes at end of frame
	if active_fg != "" || active_bg != "" || active_bold || active_dim {
		strings.write_string(&builder, "\x1b[0m")
	}

	// Park the hidden cursor on the selected row (screen readers track it).
	if screen.has_focus &&
	   (screen.cursor_x != screen.focus_x || screen.cursor_y != screen.focus_y) {
		fmt.sbprintf(&builder, "\x1b[%d;%dH", screen.focus_y + 1, screen.focus_x + 1)
		screen.cursor_x, screen.cursor_y = screen.focus_x, screen.focus_y
	}

	// Single write to terminal (batch for performance)
	output := strings.to_string(builder)
	if len(output) > 0 {
		// Write raw bytes directly to stdout for reliability
		os.write(output_file, transmute([]u8)output)
	}

	// Copy current to previous for next frame
	for y in 0 ..< screen.height {
		copy(screen.prev_buffer[y], screen.buffer[y])
	}
}

// Render text at position.
// ANSI escape bytes (0x1b) are silently skipped — color belongs in Cell.fg,
// not the char stream. See thoughts/scroll_bug_spec.md for why this matters.
// Wide runes (CJK, emoji) occupy two cells; a combining mark joins the
// previous cell; other zero-width runes (VS16, ZWJ) are dropped.
render_text :: proc(screen: ^Screen, x, y: int, text: string) {
	render_text_styled(screen, x, y, text)
}

// Render box at position
tui_render_box :: proc(screen: ^Screen, x, y, width, height: int) {
	if width < 2 || height < 2 do return

	// Top border
	screen_set_cell(screen, x, y, Cell{char = '┌'})
	for i in 1 ..< width - 1 {
		screen_set_cell(screen, x + i, y, Cell{char = '─'})
	}
	screen_set_cell(screen, x + width - 1, y, Cell{char = '┐'})

	// Sides
	for j in 1 ..< height - 1 {
		screen_set_cell(screen, x, y + j, Cell{char = '│'})
		screen_set_cell(screen, x + width - 1, y + j, Cell{char = '│'})
	}

	// Bottom border
	screen_set_cell(screen, x, y + height - 1, Cell{char = '└'})
	for i in 1 ..< width - 1 {
		screen_set_cell(screen, x + i, y + height - 1, Cell{char = '─'})
	}
	screen_set_cell(screen, x + width - 1, y + height - 1, Cell{char = '┘'})
}

// ============================================================================
// Styled Rendering Functions (Phase 1: Color System Foundation)
// ============================================================================

// Render text with color and formatting
// fg: Foreground color (ANSI escape code string)
// bg: Background color (ANSI escape code string)
// bold: Apply bold formatting
render_text_styled :: proc(
	screen: ^Screen,
	x, y: int,
	text: string,
	fg: string = "",
	bg: string = "",
	bold := false,
) {
	current_x := x
	last_x := -1 // lead cell of the last glyph written (for combining marks)
	style := Cell {
		fg   = fg,
		bg   = bg,
		bold = bold,
	}
	for c in text {
		ch := c
		if current_x >= screen.width do break
		// ESC bytes must never reach Cell.char — they inflate logical cursor_x
		// and drift the diff renderer. See thoughts/scroll_bug_spec.md.
		if ch == 0x1b do continue
		// Other control characters (C0, DEL, C1) show as a placeholder
		// glyph: never emitted to the terminal, never taken for a mark.
		if is_control_rune(ch) do ch = TUI_CONTROL_PLACEHOLDER
		if get_rune_width(ch) == 0 {
			screen_attach_combining(screen, last_x, y, ch)
			continue
		}

		w := screen_put_rune(screen, current_x, y, ch, style)
		if w == 0 do break // wide rune doesn't fit before the right edge
		last_x = current_x
		current_x += w
	}
}
