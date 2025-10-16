// tui_panel.odin - Panel Layout System for Multi-Panel TUI Views
//
// This module provides layout calculation functions for split-panel views
// where the screen is divided into list panel (left) and preview panel (right).
//
// Layout Pattern: 30/70 split (list takes 30%, preview takes 70%)

package wayu_tui

// Calculate split layout dimensions for list + preview panels
// Returns coordinates and dimensions for both panels
//
// Layout diagram (80x24 terminal):
// ┌─────────────────────┬────────────────────────────────────────────────────────┐
// │ List Panel (30%)    │ Preview Panel (70%)                                    │
// │ 24 chars wide       │ 54 chars wide                                          │
// │                     │                                                        │
// │ Items go here       │ Preview content goes here                              │
// │                     │                                                        │
// └─────────────────────┴────────────────────────────────────────────────────────┘
//
// Border layout reserves:
// - Top border: 1 line
// - Bottom border: 1 line
// - Left border: 1 char
// - Right border: 1 char
// - Vertical divider: 1 char between panels
//
// Returns: list_x, list_y, list_w, list_h, preview_x, preview_y, preview_w, preview_h
calculate_split_layout :: proc(screen_width, screen_height: int) -> (
	list_x, list_y, list_w, list_h: int,
	preview_x, preview_y, preview_w, preview_h: int,
) {
	// Calculate split position (30% of total width)
	// Subtract 2 for left/right borders
	content_width := screen_width - 2
	split_x := content_width * 30 / 100

	// Border coordinates (1-based, accounting for outer border)
	border_top := 1
	border_bottom := screen_height - 2
	border_left := 1
	border_right := screen_width - 2

	// List panel dimensions (left 30%)
	list_x = border_left + 1  // +1 for border
	list_y = border_top + 1   // +1 for border
	list_w = split_x - 1      // -1 to avoid overlapping divider
	list_h = border_bottom - border_top - 1  // Height between borders

	// Preview panel dimensions (right 70%)
	preview_x = border_left + split_x + 1  // Start after divider
	preview_y = border_top + 1
	preview_w = content_width - split_x - 1  // Remaining width after list and divider
	preview_h = list_h  // Same height as list panel

	return
}

// Render vertical divider between panels
// Used to separate list panel from preview panel in split layouts
render_panel_divider :: proc(screen: ^Screen, x, y, height: int, color: string = TUI_BORDER_NORMAL) {
	// Top T-junction
	screen_set_cell(screen, x, y, Cell{char = BOX_HORIZONTAL_DOWN, fg = color})

	// Vertical line
	for i in 1..<height-1 {
		screen_set_cell(screen, x, y+i, Cell{char = BOX_VERTICAL, fg = color})
	}

	// Bottom T-junction
	screen_set_cell(screen, x, y+height-1, Cell{char = BOX_HORIZONTAL_UP, fg = color})
}

// Helper: Render panel title bar (horizontal line with text)
render_panel_title :: proc(screen: ^Screen, x, y, width: int, title: string, color: string = TUI_PRIMARY) {
	// Left T-junction
	screen_set_cell(screen, x, y, Cell{char = BOX_VERTICAL_RIGHT, fg = color})

	// Title text with padding
	render_text_styled(screen, x+2, y, title, color, "", true)

	// Horizontal line (fill rest of width)
	title_len := len(title)
	for i in title_len+3..<width-1 {
		screen_set_cell(screen, x+i, y, Cell{char = BOX_HORIZONTAL, fg = color})
	}

	// Right T-junction
	screen_set_cell(screen, x+width-1, y, Cell{char = BOX_VERTICAL_LEFT, fg = color})
}
