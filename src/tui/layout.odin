// tui_layout.odin - Layout Constants for TUI Views
//
// This file defines all layout-related constants to eliminate magic numbers
// and make the TUI layout calculations self-documenting.

package wayu_tui

// ============================================================================
// Border Layout Constants
// ============================================================================

// Border dimensions (box-drawing characters take 1 cell)
BORDER_TOP_HEIGHT    :: 1  // Top border line
BORDER_BOTTOM_HEIGHT :: 1  // Bottom border line
BORDER_LEFT_WIDTH    :: 1  // Left border column
BORDER_RIGHT_WIDTH   :: 1  // Right border column

// Total border overhead
BORDER_HORIZONTAL_TOTAL :: BORDER_LEFT_WIDTH + BORDER_RIGHT_WIDTH  // 2 cells
BORDER_VERTICAL_TOTAL   :: BORDER_TOP_HEIGHT + BORDER_BOTTOM_HEIGHT  // 2 cells

// ============================================================================
// Header Layout Constants
// ============================================================================

// Header line positions (inside border, 1-indexed from border top)
HEADER_TITLE_LINE  :: 1  // Line 1: Main title (e.g., "📂 PATH Configuration")
HEADER_COUNT_LINE  :: 2  // Line 2: Item count (e.g., "35 entries")
HEADER_HEIGHT      :: 2  // Total header height in lines

// Blank line after header before content starts
HEADER_CONTENT_GAP :: 1

// ============================================================================
// Footer Layout Constants
// ============================================================================

// Footer height and position
FOOTER_HEIGHT :: 1  // Footer takes 1 line
FOOTER_OFFSET_FROM_BOTTOM :: 2  // Footer is 2 lines from bottom (border + footer)

// Notification bar height (rendered between footer and bottom border)
NOTIFICATION_HEIGHT :: 1

// ============================================================================
// Content Area Layout Constants
// ============================================================================

// Content area offsets (relative to border)
CONTENT_PADDING_LEFT :: 2  // Indent content 2 cells from left border
CONTENT_PADDING_TOP  :: 1  // 1 line padding from border top

// List item positioning
LIST_ITEM_START_LINE :: CONTENT_PADDING_TOP + HEADER_HEIGHT + HEADER_CONTENT_GAP  // Line 4 (1 + 2 + 1)
LIST_ITEM_INDENT     :: CONTENT_PADDING_LEFT  // Indent items 2 cells from border

// Selection indicator
SELECTION_PREFIX_WIDTH :: 2  // "> " takes 2 characters

// Main menu item layout (dashboard-style with dividers)
MENU_ITEM_SPACING :: 2  // Each menu item occupies 2 rows (text + divider)
MENU_ACCENT_BAR_WIDTH :: 1  // ┃ accent bar is 1 cell
MENU_ACCENT_GAP :: 2  // Gap after accent bar before text

// ============================================================================
// Visible Height Calculation Constants
// ============================================================================

// Calculate visible height for scrollable lists
// Formula: terminal_height - (borders + header + gap + footer + margins)
//
// Breakdown:
// - BORDER_TOP_HEIGHT (1): Top border
// - CONTENT_PADDING_TOP (1): Padding after top border
// - HEADER_HEIGHT (2): Title + count lines
// - HEADER_CONTENT_GAP (1): Blank line after header
// - FOOTER_HEIGHT (1): Footer line
// - FOOTER_OFFSET_FROM_BOTTOM (2): Footer + bottom border
//
// Total overhead: 1 + 1 + 2 + 1 + 1 = 6 lines
// (border_top + padding_top + header_height + header_gap + footer+border_bottom)
// Notification is rendered outside the box — not counted in visible list height
VISIBLE_HEIGHT_OVERHEAD :: 6

// ============================================================================
// Helper Functions
// ============================================================================

// Calculate visible height for list items
calculate_visible_height :: proc(terminal_height: int) -> int {
	return terminal_height - VISIBLE_HEIGHT_OVERHEAD
}

// Calculate footer Y position
calculate_footer_y :: proc(terminal_height: int) -> int {
	return terminal_height - FOOTER_OFFSET_FROM_BOTTOM - 1  // -1 for border
}

// Calculate list item Y position
calculate_list_item_y :: proc(index_in_visible_area: int) -> int {
	return LIST_ITEM_START_LINE + index_in_visible_area
}

// Calculate border dimensions (responsive - fills terminal width)
calculate_border_dimensions :: proc(terminal_width, terminal_height: int) -> (width: int, height: int) {
	width = terminal_width - BORDER_HORIZONTAL_TOTAL
	height = terminal_height - BORDER_VERTICAL_TOTAL - NOTIFICATION_HEIGHT
	return
}

// Calculate max content width inside the border box (for text truncation)
calculate_content_width :: proc(border_width: int) -> int {
	// border_width includes left+right border chars
	// Inside: CONTENT_PADDING_LEFT + SELECTION_PREFIX_WIDTH + text + right margin
	return border_width - CONTENT_PADDING_LEFT - SELECTION_PREFIX_WIDTH - BORDER_RIGHT_WIDTH - 1
}

// Calculate notification bar Y position (below the border box)
calculate_notification_y :: proc(terminal_height: int) -> int {
	return terminal_height - NOTIFICATION_HEIGHT
}
