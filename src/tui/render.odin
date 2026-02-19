package wayu_tui

import "core:fmt"
import "core:os"
import "core:strings"

// Flush screen with differential rendering
screen_flush :: proc(screen: ^Screen, force_full_render := false) {
	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	// Track what ANSI state the terminal is currently in so we can
	// emit only the minimal escape sequences needed.
	active_fg:   string
	active_bg:   string
	active_bold: bool
	active_dim:  bool

	for y in 0..<screen.height {
		for x in 0..<screen.width {
			curr := screen.buffer[y][x]
			prev := screen.prev_buffer[y][x]

			// Skip unchanged cells (KEY OPTIMIZATION)
			// But force render on first frame
			if !force_full_render && curr == prev do continue

			// Move cursor if needed (minimize cursor movement)
			if x != screen.cursor_x || y != screen.cursor_y {
				fmt.sbprintf(&builder, "\x1b[%d;%dH", y+1, x+1)
				screen.cursor_x = x
				screen.cursor_y = y
				// After a cursor jump we don't know what terminal state is,
				// so reset our tracking to force re-emission of attributes.
				active_fg   = ""
				active_bg   = ""
				active_bold = false
				active_dim  = false
			}

			// Reset all attributes if the cell has none but terminal has some
			needs_reset := false
			if (active_bold && !curr.bold) || (active_dim && !curr.dim) ||
			   (active_fg != "" && curr.fg == "") || (active_bg != "" && curr.bg == "") {
				needs_reset = true
			}

			if needs_reset {
				fmt.sbprintf(&builder, "\x1b[0m")
				active_fg   = ""
				active_bg   = ""
				active_bold = false
				active_dim  = false
			}

			// Apply bold if needed
			if curr.bold && !active_bold {
				fmt.sbprintf(&builder, "\x1b[1m")
				active_bold = true
			}

			// Apply dim if needed
			if curr.dim && !active_dim {
				fmt.sbprintf(&builder, "\x1b[2m")
				active_dim = true
			}

			// Apply foreground color if needed
			if curr.fg != "" && curr.fg != active_fg {
				fmt.sbprintf(&builder, "%s", curr.fg)
				active_fg = curr.fg
			}

			// Apply background color if needed
			if curr.bg != "" && curr.bg != active_bg {
				fmt.sbprintf(&builder, "%s", curr.bg)
				active_bg = curr.bg
			}

			// Write character
			fmt.sbprintf(&builder, "%c", curr.char)
			screen.cursor_x += 1
		}
	}

	// Reset attributes at end of frame
	if active_fg != "" || active_bg != "" || active_bold || active_dim {
		fmt.sbprintf(&builder, "\x1b[0m")
	}

	// Single write to terminal (batch for performance)
	output := strings.to_string(builder)
	if len(output) > 0 {
		// Write raw bytes directly to stdout for reliability
		os.write(os.stdout, transmute([]u8)output)
	}

	// Copy current to previous for next frame
	for y in 0..<screen.height {
		copy(screen.prev_buffer[y], screen.buffer[y])
	}
}

// Render text at position
render_text :: proc(screen: ^Screen, x, y: int, text: string) {
	current_x := x
	for ch in text {
		if current_x >= screen.width do break

		screen_set_cell(screen, current_x, y, Cell{char = ch})
		current_x += 1
	}
}

// Render box at position
render_box :: proc(screen: ^Screen, x, y, width, height: int) {
	if width < 2 || height < 2 do return

	// Top border
	screen_set_cell(screen, x, y, Cell{char = '┌'})
	for i in 1..<width-1 {
		screen_set_cell(screen, x+i, y, Cell{char = '─'})
	}
	screen_set_cell(screen, x+width-1, y, Cell{char = '┐'})

	// Sides
	for j in 1..<height-1 {
		screen_set_cell(screen, x, y+j, Cell{char = '│'})
		screen_set_cell(screen, x+width-1, y+j, Cell{char = '│'})
	}

	// Bottom border
	screen_set_cell(screen, x, y+height-1, Cell{char = '└'})
	for i in 1..<width-1 {
		screen_set_cell(screen, x+i, y+height-1, Cell{char = '─'})
	}
	screen_set_cell(screen, x+width-1, y+height-1, Cell{char = '┘'})
}

// ============================================================================
// Styled Rendering Functions (Phase 1: Color System Foundation)
// ============================================================================

// Render text with color and formatting
// fg: Foreground color (ANSI escape code string)
// bg: Background color (ANSI escape code string)
// bold: Apply bold formatting
render_text_styled :: proc(screen: ^Screen, x, y: int, text: string, fg: string = "", bg: string = "", bold := false) {
	current_x := x
	for ch in text {
		if current_x >= screen.width do break

		screen_set_cell(screen, current_x, y, Cell{
			char = ch,
			fg = fg,
			bg = bg,
			bold = bold,
		})
		current_x += 1
	}
}

// Render box with colored borders
// fg: Border color (defaults to TUI_BORDER_NORMAL)
render_box_styled :: proc(screen: ^Screen, x, y, width, height: int, fg: string = TUI_BORDER_NORMAL) {
	if width < 2 || height < 2 do return

	// Top border
	screen_set_cell(screen, x, y, Cell{char = BOX_TOP_LEFT, fg = fg})
	for i in 1..<width-1 {
		screen_set_cell(screen, x+i, y, Cell{char = BOX_HORIZONTAL, fg = fg})
	}
	screen_set_cell(screen, x+width-1, y, Cell{char = BOX_TOP_RIGHT, fg = fg})

	// Sides
	for j in 1..<height-1 {
		screen_set_cell(screen, x, y+j, Cell{char = BOX_VERTICAL, fg = fg})
		screen_set_cell(screen, x+width-1, y+j, Cell{char = BOX_VERTICAL, fg = fg})
	}

	// Bottom border
	screen_set_cell(screen, x, y+height-1, Cell{char = BOX_BOTTOM_LEFT, fg = fg})
	for i in 1..<width-1 {
		screen_set_cell(screen, x+i, y+height-1, Cell{char = BOX_HORIZONTAL, fg = fg})
	}
	screen_set_cell(screen, x+width-1, y+height-1, Cell{char = BOX_BOTTOM_RIGHT, fg = fg})
}
