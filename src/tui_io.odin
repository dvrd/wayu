package wayu
import "core:fmt"
import "core:c"
import "core:os"
import "core:strconv"
import "core:strings"
import "base:intrinsics"
import "core:time"
foreign import libc "system:c"

foreign libc {
    ioctl :: proc(fd: c.int, request: c.ulong, arg: rawptr) -> c.int ---
    signal :: proc(sig: c.int, handler: proc "c" (i32)) -> proc "c" (i32) ---
    select :: proc(nfds: c.int, readfds: rawptr, writefds: rawptr, errorfds: rawptr, timeout: rawptr) -> c.int ---
}
// Platform-specific constants
when ODIN_OS == .Darwin {
    TIOCGWINSZ :: 0x40087468
} else when ODIN_OS == .Linux {
    TIOCGWINSZ :: 0x5413
}

// ANSI escape codes
ENTER_ALT_SCREEN :: "\x1b[?1049h"
EXIT_ALT_SCREEN  :: "\x1b[?1049l"
HIDE_CURSOR      :: "\x1b[?25l"
SHOW_CURSOR      :: "\x1b[?25h"
CLEAR_SCREEN     :: "\x1b[2J"
CURSOR_HOME      :: "\x1b[H"

// Terminal size structure
winsize :: struct {
    ws_row:    c.ushort,
    ws_col:    c.ushort,
    ws_xpixel: c.ushort,
    ws_ypixel: c.ushort,
}

// Foreign imports

// Signal constants
SIGWINCH :: 28  // Signal number for window resize (macOS/Linux)

// Global resize flag
terminal_resized: bool

// Get terminal dimensions.
// Tries three methods in order:
//   1. ioctl TIOCGWINSZ (most reliable when available)
//   2. $COLUMNS / $LINES environment variables (set by most shells)
//   3. ANSI cursor-position probe (works in any VT100-compatible terminal)
//   4. Fallback to 80x24
get_terminal_size :: proc() -> (width, height: int, ok: bool) {
    // Method 1: ioctl (fast, no I/O).
    ws: winsize
    if ioctl(1, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0 && ws.ws_row > 0 {
        return int(ws.ws_col), int(ws.ws_row), true
    }

    // Method 2: environment variables (shells like zsh/bash export these).
    // Use stack buffers to avoid heap allocation.
    {
        cols_buf: [16]byte
        rows_buf: [16]byte
        cols_str, cols_err := os.lookup_env_buf(cols_buf[:], "COLUMNS")
        rows_str, rows_err := os.lookup_env_buf(rows_buf[:], "LINES")
        if cols_err == nil && rows_err == nil {
            cols, cols_ok := strconv.parse_int(cols_str)
            rows, rows_ok := strconv.parse_int(rows_str)
            if cols_ok && rows_ok && cols > 0 && rows > 0 {
                return cols, rows, true
            }
        }
    }

    // Method 3: ANSI cursor-position probe.
    // Move cursor to bottom-right corner, then query position.
    // Response: ESC [ rows ; cols R
    {
        // Save cursor, move to 999;999, query position.
        os.write(os.stdout, transmute([]u8)string("\x1b[s\x1b[999;999H\x1b[6n\x1b[u"))

        // Read response (up to 32 bytes, format: ESC [ rows ; cols R).
        buf: [32]byte
        n, err := os.read(os.stdin, buf[:])
        if err == nil && n > 0 {
            response := string(buf[:n])
            // Parse ESC [ rows ; cols R
            if esc_idx := strings.index_byte(response, '['); esc_idx >= 0 {
                inner := response[esc_idx + 1:]
                if r_idx := strings.index_byte(inner, 'R'); r_idx >= 0 {
                    inner = inner[:r_idx]
                    if semi := strings.index_byte(inner, ';'); semi >= 0 {
                        rows, rows_ok := strconv.parse_int(inner[:semi])
                        cols, cols_ok := strconv.parse_int(inner[semi + 1:])
                        if rows_ok && cols_ok && cols > 0 && rows > 0 {
                            return cols, rows, true
                        }
                    }
                }
            }
        }
    }

    return 80, 24, false  // Last resort fallback.
}

// SIGWINCH handler (MUST be "c" convention)
// Uses volatile_store to ensure the write is visible to the main loop
sigwinch_handler :: proc "c" (sig: i32) {
    intrinsics.volatile_store(&terminal_resized, true)
}

// Setup resize signal handler
setup_resize_handler :: proc() {
    signal(SIGWINCH, sigwinch_handler)
}

// Enter alternate screen buffer
enter_alt_screen :: proc() {
    fmt.print(ENTER_ALT_SCREEN)
}

// Exit alternate screen buffer
exit_alt_screen :: proc() {
    fmt.print(EXIT_ALT_SCREEN)
}

// TUI lifecycle initialization
tui_lifecycle_init :: proc() {
    enter_alt_screen()
    fmt.print(HIDE_CURSOR)
    setup_resize_handler()
}

// TUI lifecycle cleanup
tui_lifecycle_cleanup :: proc() {
    // Clear the alt screen before exiting so no TUI content bleeds through
    fmt.print(CLEAR_SCREEN)
    fmt.print(CURSOR_HOME)
    fmt.print(SHOW_CURSOR)
    exit_alt_screen()
}
// timeval struct for select timeout
timeval :: struct {
    tv_sec:  c.long,
    tv_usec: c.long,
}

// fd_set manipulation for select
FD_SETSIZE :: 1024

@(private)
fd_set :: struct #raw_union {
    bits: [FD_SETSIZE / (8 * size_of(c.long))]c.long,
}

@(private)
fd_zero :: proc(set: ^fd_set) {
    for i in 0..<len(set.bits) {
        set.bits[i] = 0
    }
}

@(private)
fd_set_bit :: proc(set: ^fd_set, fd: c.int) {
    set.bits[fd / (8 * size_of(c.long))] |= 1 << (uint(fd) % (8 * size_of(c.long)))
}

@(private)
fd_isset :: proc(set: ^fd_set, fd: c.int) -> bool {
    return (set.bits[fd / (8 * size_of(c.long))] >> (uint(fd) % (8 * size_of(c.long)))) & 1 != 0
}

// Poll for events with timeout (non-blocking)
// Returns: Event if available, nil if timeout or no data
poll_event :: proc() -> Event {
    // Use select with 50ms timeout to allow periodic resize checks
    readfds: fd_set
    fd_zero(&readfds)
    fd_set_bit(&readfds, c.int(STDIN_FILENO))

    timeout := timeval{
        tv_sec  = 0,
        tv_usec = 50_000,  // 50ms
    }

    ready := select(c.int(STDIN_FILENO) + 1, &readfds, nil, nil, &timeout)

    // No data available (timeout)
    if ready <= 0 {
        return nil
    }

    // Data available on stdin
    input_buf: [8]byte
    n, err := os.read(os.stdin, input_buf[:])

    if err != nil || n == 0 {
        return nil
    }

    if key, ok := parse_key_event(input_buf[:], n); ok {
        return key
    }

    return nil
}
// Field order is layout-optimized (data-oriented): the 8-byte-aligned
// strings come first, then the 4-byte rune, then the 1-byte bools. This
// packs Cell into 40 bytes instead of 48 (rune no longer forces 4 bytes of
// padding before `fg`). Cells are bulk-allocated as a width*height grid and
// touched every frame, so the 17% shrink improves render-loop cache density.
Cell :: struct {
	fg:    string,
	bg:    string,
	char:  rune,
	bold:  bool,
	dim:   bool,
}

Screen :: struct {
	buffer:      [][]Cell,
	prev_buffer: [][]Cell,
	width:       int,
	height:      int,
	cursor_x:    int,
	cursor_y:    int,
}

// Create screen with dimensions
screen_create :: proc(width, height: int) -> Screen {
	buffer := make([][]Cell, height)
	prev_buffer := make([][]Cell, height)

	for y in 0..<height {
		buffer[y] = make([]Cell, width)
		prev_buffer[y] = make([]Cell, width)

		// Initialize with space cells
		for x in 0..<width {
			buffer[y][x] = Cell{char = ' '}
			prev_buffer[y][x] = Cell{char = ' '}
		}
	}

	return Screen{
		buffer = buffer,
		prev_buffer = prev_buffer,
		width = width,
		height = height,
	}
}

// Free only the cell buffers (used by screen_resize to preserve other fields).
screen_free_buffers :: proc(screen: ^Screen) {
	for y in 0..<len(screen.buffer) {
		delete(screen.buffer[y])
		delete(screen.prev_buffer[y])
	}
	delete(screen.buffer)
	delete(screen.prev_buffer)
}

// Destroy screen and free memory
screen_destroy :: proc(screen: ^Screen) {
	screen_free_buffers(screen)
}

// Resize screen, preserving content
screen_resize :: proc(screen: ^Screen, new_width, new_height: int) {
	// Allocate new buffers
	new_buffer := make([][]Cell, new_height)
	new_prev_buffer := make([][]Cell, new_height)

	for y in 0..<new_height {
		new_buffer[y] = make([]Cell, new_width)
		new_prev_buffer[y] = make([]Cell, new_width)

		// Initialize with spaces
		for x in 0..<new_width {
			new_buffer[y][x] = Cell{char = ' '}
			new_prev_buffer[y][x] = Cell{char = ' '}
		}

		// Copy existing content
		if y < screen.height {
			copy_width := min(new_width, screen.width)
			copy(new_buffer[y][:copy_width], screen.buffer[y][:copy_width])
			copy(new_prev_buffer[y][:copy_width], screen.prev_buffer[y][:copy_width])
		}
	}

	// Free old buffers only (preserve cursor and any future fields)
	screen_free_buffers(screen)

	// Update screen
	screen.buffer = new_buffer
	screen.prev_buffer = new_prev_buffer
	screen.width = new_width
	screen.height = new_height
}

// Set cell at position
screen_set_cell :: proc(screen: ^Screen, x, y: int, cell: Cell) {
	if x >= 0 && x < screen.width && y >= 0 && y < screen.height {
		screen.buffer[y][x] = cell
	}
}

// Clear screen (fill with spaces, reset all formatting)
screen_clear :: proc(screen: ^Screen) {
	for y in 0..<screen.height {
		for x in 0..<screen.width {
			// Clear cell completely - char AND all formatting fields
			screen.buffer[y][x] = Cell{char = ' ', fg = "", bg = "", bold = false, dim = false}
		}
	}
}

// Convert screen buffer to plain text string (no ANSI codes)
// Used for component testing and golden file generation
screen_to_string :: proc(screen: ^Screen) -> string {
	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	for y in 0..<screen.height {
		for x in 0..<screen.width {
			cell := screen.buffer[y][x]
			fmt.sbprintf(&builder, "%c", cell.char)
		}
		// Add newline after each row except the last
		if y < screen.height - 1 {
			fmt.sbprintf(&builder, "\n")
		}
	}

	// Clone the string before builder is destroyed
	return strings.clone(strings.to_string(builder))
}
// Event types
Event :: union {
    KeyEvent,
    MouseEvent,
    ResizeEvent,
}

KeyEvent :: struct {
    key:       Key,
    char:      rune,
    modifiers: KeyModifiers,
}

MouseEvent :: struct {
    x, y:      int,
    button:    int,
}

ResizeEvent :: struct {
    width, height: int,
}

Key :: enum {
    None,
    Char,
    Enter,
    Tab,
    Backspace,
    Delete,
    Escape,
    Up,
    Down,
    Left,
    Right,
    Home,
    End,
    PageUp,
    PageDown,
    F1, F2, F3, F4, F5, F6,
    F7, F8, F9, F10, F11, F12,
}

KeyModifiers :: bit_set[KeyModifier]
KeyModifier :: enum {
    Shift,
    Ctrl,
    Alt,
}

// Parse key event from input buffer
parse_key_event :: proc(input_buf: []byte, n: int) -> (KeyEvent, bool) {
    if n == 0 do return {}, false

    ch := input_buf[0]

    // Escape sequences (arrow keys, function keys)
    if ch == 27 {
        if n == 1 {
            return KeyEvent{key = .Escape}, true
        }

        // Arrow keys: ESC [ A/B/C/D
        if n >= 3 && input_buf[1] == '[' {
            switch input_buf[2] {
            case 'A': return KeyEvent{key = .Up}, true
            case 'B': return KeyEvent{key = .Down}, true
            case 'C': return KeyEvent{key = .Right}, true
            case 'D': return KeyEvent{key = .Left}, true
            case 'H': return KeyEvent{key = .Home}, true
            case 'F': return KeyEvent{key = .End}, true
            }

            // Function keys: ESC [ 1 5 ~ (F5), etc.
            if n >= 4 && input_buf[3] == '~' {
                code := int(input_buf[2] - '0')
                switch code {
                case 5: return KeyEvent{key = .F5}, true
                case 7: return KeyEvent{key = .F6}, true
                case 8: return KeyEvent{key = .F7}, true
                case 9: return KeyEvent{key = .F8}, true
                }
            }
        }

        // Function keys F1-F4: ESC O P/Q/R/S
        if n >= 3 && input_buf[1] == 'O' {
            switch input_buf[2] {
            case 'P': return KeyEvent{key = .F1}, true
            case 'Q': return KeyEvent{key = .F2}, true
            case 'R': return KeyEvent{key = .F3}, true
            case 'S': return KeyEvent{key = .F4}, true
            }
        }

        return {}, false
    }

    // Special keys (must check before Ctrl keys to avoid conflicts)
    switch ch {
    case 10, 13: return KeyEvent{key = .Enter}, true
    case 9:      return KeyEvent{key = .Tab}, true
    case 127, 8: return KeyEvent{key = .Backspace}, true
    }

    // Control keys (Ctrl+A = 1, Ctrl+C = 3, etc.)
    // Note: Tab (9), LF (10), CR (13) are handled above
    if ch >= 1 && ch <= 26 {
        char := rune('a' + ch - 1)
        return KeyEvent{
            key = .Char,
            char = char,
            modifiers = {.Ctrl},
        }, true
    }

    // Printable characters
    if ch >= 32 && ch <= 126 {
        return KeyEvent{
            key = .Char,
            char = rune(ch),
        }, true
    }

    return {}, false
}
// ============================================================================
// Primary Colors
// ============================================================================

// Hot pink - Main accent color for highlights, selected items, focused borders
TUI_PRIMARY :: "\x1b[38;2;228;0;80m"  // #E40050

// Teal-cyan - Secondary elements, success indicators
TUI_SECONDARY :: "\x1b[38;2;14;116;144m"  // #0E7490

// ============================================================================
// Semantic Colors
// ============================================================================

// Success color - Teal (same as secondary)
TUI_SUCCESS :: "\x1b[38;2;14;116;144m"  // #0E7490

// Error color - Dark red
TUI_ERROR :: "\x1b[38;2;153;27;27m"  // #991B1B

// Warning color - Amber
TUI_WARNING :: "\x1b[38;2;217;119;6m"  // #D97706

// Bright orange - Focused button highlight, active form field cursor
TUI_ORANGE :: "\x1b[38;2;255;140;0m"  // #FF8C00

// Info color - Teal-cyan (same as secondary)
TUI_INFO :: "\x1b[38;2;14;116;144m"  // #0E7490

// Source indicators - Green for wayu active, Yellow for inactive, Blue for external
TUI_SOURCE_WAYU_ACTIVE :: "\x1b[38;2;34;197;94m"    // #22C55E (green)
TUI_SOURCE_WAYU_INACTIVE :: "\x1b[38;2;217;119;6m"  // #D97706 (amber/yellow)
TUI_SOURCE_EXTERNAL :: "\x1b[38;2;59;130;246m"      // #3B82F6 (blue)
TUI_SOURCE_SHADOWED :: "\x1b[38;2;168;85;247m"      // #A855F7 (purple)

// ============================================================================
// UI Element Colors
// ============================================================================

// Highlight color - Hot pink (same as primary)
TUI_HIGHLIGHT :: "\x1b[38;2;228;0;80m"  // #E40050

// Muted text - Light gray for secondary text
TUI_MUTED :: "\x1b[38;2;208;208;208m"  // #D0D0D0

// Dim text - Dimmer gray for disabled/subtle text
TUI_DIM :: "\x1b[38;2;100;100;100m"  // #646464

// Divider line - Very dim gray for horizontal separators between menu items
TUI_DIVIDER :: "\x1b[38;2;51;51;51m"  // #333333

// ============================================================================
// Background Colors
// ============================================================================

// Normal background - Dark purple-blue
TUI_BG_NORMAL :: "\x1b[48;2;24;24;37m"  // #181825

// Selected item background - Almost black for maximum contrast
TUI_BG_SELECTED :: "\x1b[48;2;9;9;11m"  // #09090B

// Header/footer background - Slightly lighter than normal
TUI_BG_HEADER :: "\x1b[48;2;18;18;27m"  // #12121B

// ============================================================================
// Border Colors
// ============================================================================

// Normal border color - Gray for inactive panels
TUI_BORDER_NORMAL :: "\x1b[38;2;100;100;100m"  // #646464

// Focused border color - Hot pink for active panel
TUI_BORDER_FOCUSED :: "\x1b[38;2;228;0;80m"  // #E40050

// ============================================================================
// Box Drawing Characters (Unicode)
// ============================================================================

// Light single-line box drawing (standard style)
BOX_HORIZONTAL     :: '─'  // U+2500
BOX_VERTICAL       :: '│'  // U+2502
BOX_TOP_LEFT       :: '┌'  // U+250C
BOX_TOP_RIGHT      :: '┐'  // U+2510
BOX_BOTTOM_LEFT    :: '└'  // U+2514
BOX_BOTTOM_RIGHT   :: '┘'  // U+2518
BOX_VERTICAL_RIGHT :: '├'  // U+251C (left T-junction)
BOX_VERTICAL_LEFT  :: '┤'  // U+2524 (right T-junction)
BOX_HORIZONTAL_DOWN :: '┬'  // U+252C (top T-junction)
BOX_HORIZONTAL_UP   :: '┴'  // U+2534 (bottom T-junction)
BOX_CROSS          :: '┼'  // U+253C (4-way intersection)

// Rounded corners (softer appearance)
BOX_ROUND_TOP_LEFT     :: '╭'  // U+256D
BOX_ROUND_TOP_RIGHT    :: '╮'  // U+256E
BOX_ROUND_BOTTOM_LEFT  :: '╰'  // U+256F
BOX_ROUND_BOTTOM_RIGHT :: '╯'  // U+2570

// Heavy/thick box drawing (for emphasis)
BOX_HEAVY_HORIZONTAL     :: '━'  // U+2501
BOX_HEAVY_VERTICAL       :: '┃'  // U+2503
BOX_HEAVY_TOP_LEFT       :: '┏'  // U+250F
BOX_HEAVY_TOP_RIGHT      :: '┓'  // U+2513
BOX_HEAVY_BOTTOM_LEFT    :: '┗'  // U+2517
BOX_HEAVY_BOTTOM_RIGHT   :: '┛'  // U+251B

// Double-line box drawing (for strong emphasis)
BOX_DBL_HORIZONTAL     :: '═'  // U+2550
BOX_DBL_VERTICAL       :: '║'  // U+2551
BOX_DBL_TOP_LEFT       :: '╔'  // U+2554
BOX_DBL_TOP_RIGHT      :: '╗'  // U+2557
BOX_DBL_BOTTOM_LEFT    :: '╚'  // U+255A
BOX_DBL_BOTTOM_RIGHT   :: '╝'  // U+255D

// ============================================================================
// Helper: Color Aliases for Backward Compatibility
// ============================================================================

// These aliases map new naming to old code expecting different names
TUI_FG_NORMAL    :: TUI_MUTED      // Normal text
TUI_FG_SELECTED  :: TUI_PRIMARY    // Selected item text
TUI_FG_HIGHLIGHT :: TUI_HIGHLIGHT  // Highlighted text
TUI_FG_MUTED     :: TUI_DIM        // Muted text
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
tui_calculate_content_width :: proc(border_width: int) -> int {
	// border_width includes left+right border chars
	// Inside: CONTENT_PADDING_LEFT + SELECTION_PREFIX_WIDTH + text + right margin
	return border_width - CONTENT_PADDING_LEFT - SELECTION_PREFIX_WIDTH - BORDER_RIGHT_WIDTH - 1
}

// Calculate notification bar Y position (below the border box)
calculate_notification_y :: proc(terminal_height: int) -> int {
	return terminal_height - NOTIFICATION_HEIGHT
}

// ============================================================================
// Responsive Breakpoints
// ============================================================================

// Minimum terminal dimensions the TUI supports.
// Below these the layout still renders but content may truncate.
MIN_TERMINAL_WIDTH  :: 40
MIN_TERMINAL_HEIGHT :: 12

// Width thresholds for layout adaptations.
BREAKPOINT_COMPACT  :: 60  // compact footers, reduced padding
BREAKPOINT_NARROW   :: 50  // minimal layout

// is_compact returns true when the terminal is narrow enough to use
// shortened footer strings and tighter padding.
is_compact :: proc(terminal_width: int) -> bool {
	return terminal_width < BREAKPOINT_COMPACT
}

// is_narrow returns true when the terminal is very narrow.
is_narrow :: proc(terminal_width: int) -> bool {
	return terminal_width < BREAKPOINT_NARROW
}

// Calculate the actual number of item rows the renderer draws in the current view.
//
// Each view subtracts rows from calculate_visible_height():
//   - All list views: -1 for the divider row below the header
//   - All list views: -1 for the scroll-indicator / bottom-margin row
//     (the renderer always reserves this row at content_start + visible_height,
//      so the last visible item is at content_start + visible_height - 1)
//   - Filter active:  -1 for the filter bar row
//   - Alias/Constants: -2 for column header + its divider (col_header_offset)
//
// This must stay in sync with the visible_height calculation inside each
// render_*_view proc in the view_*.odin files so that tui_state_move_selection tracks
// exactly the same drawable rows that the renderer uses.
get_view_visible_height :: proc(state: ^TUIState) -> int {
	base := calculate_visible_height(state.terminal_height)

	#partial switch state.current_view {
	case .MAIN_MENU:
		// Menu items start at LIST_ITEM_START_LINE + 2 (divider + blank).
		// Each item takes MENU_ITEM_SPACING rows. Footer must stay clear.
		// footer_y = terminal_height - FOOTER_OFFSET_FROM_BOTTOM - 1
		menu_start_y  := LIST_ITEM_START_LINE + 2
		footer_y      := state.terminal_height - FOOTER_OFFSET_FROM_BOTTOM - 1
		available     := footer_y - 1 - menu_start_y + 1  // -1: leave one row above footer
		visible_count := available / MENU_ITEM_SPACING
		if visible_count < 1 { visible_count = 1 }
		return visible_count

	case .ALIAS_VIEW, .CONSTANTS_VIEW:
		// filter bar row (when filter is active or has text)
		filter_offset := 0
		if state.filter.active || len(state.filter.text) > 0 {
			filter_offset = 1
		}
		// column header row + its divider (only when items exist)
		col_header_offset := 0
		has_items := false
		if state.filter.active || len(state.filter.text) > 0 {
			has_items = len(state.filter.indices) > 0
		} else {
			view := state.current_view
			if state.data_cache[view] != nil {
				items := cast(^[dynamic]string)state.data_cache[view]
				has_items = len(items) > 0
			}
		}
		if has_items {
			col_header_offset = 2
		}
		// -1 divider, -1 scroll-indicator row, -filter_offset, -col_header_offset
		return base - 2 - filter_offset - col_header_offset

	case:
		// PATH_VIEW, COMPLETIONS_VIEW, BACKUPS_VIEW
		filter_offset := 0
		if state.filter.active || len(state.filter.text) > 0 {
			filter_offset = 1
		}
		// -1 divider, -1 scroll-indicator row, -filter_offset
		return base - 2 - filter_offset
	}
}

// ============================================================================
// Responsive Footer Strings
// ============================================================================

// Compact footer variants for narrow terminals.
// Each returns the appropriate string based on terminal width.

get_footer_filter_active :: proc(width: int) -> string {
	if width < BREAKPOINT_NARROW {
		return "Type filter  Esc Cancel"
	}
	if width < BREAKPOINT_COMPACT {
		return "Type to filter   Esc Cancel   Enter Accept"
	}
	return FOOTER_FILTER_ACTIVE
}

get_footer_data_view :: proc(width: int) -> string {
	if width < BREAKPOINT_NARROW {
		return "/ Filter   a Add   h Back"
	}
	if width < BREAKPOINT_COMPACT {
		return "/ Filter   a Add   d Del   h Back   j/k Nav"
	}
	return FOOTER_DATA_VIEW
}

get_footer_readonly_view :: proc(width: int) -> string {
	if width < BREAKPOINT_NARROW {
		return "/ Filter   h Back"
	}
	if width < BREAKPOINT_COMPACT {
		return "/ Filter   h Back   j/k Navigate"
	}
	return FOOTER_READONLY_VIEW
}

get_footer_backup_view :: proc(width: int) -> string {
	if width < BREAKPOINT_NARROW {
		return "/ Filter   c Clean   h Back"
	}
	if width < BREAKPOINT_COMPACT {
		return "/ Filter   c Cleanup   h Back   j/k Nav"
	}
	return FOOTER_BACKUP_VIEW
}

get_footer_static_view :: proc(width: int) -> string {
	return FOOTER_STATIC_VIEW
}

get_footer_plugins_installed :: proc(width: int) -> string {
	if width < BREAKPOINT_NARROW {
		return "Tab Switch   / Filter   h Back"
	}
	if width < BREAKPOINT_COMPACT {
		return "Tab Switch   / Filter   e Ena   d Dis   h Back"
	}
	return FOOTER_PLUGINS_INSTALLED
}

get_footer_plugins_registry :: proc(width: int) -> string {
	if width < BREAKPOINT_NARROW {
		return "Tab Switch   / Filter   h Back"
	}
	if width < BREAKPOINT_COMPACT {
		return "Tab Switch   / Filter   Enter Install   h Back"
	}
	return FOOTER_PLUGINS_REGISTRY
}

get_footer_main_menu :: proc(width: int) -> string {
	if width < BREAKPOINT_NARROW {
		return "j/k Nav   l Sel   q Quit"
	}
	if width < BREAKPOINT_COMPACT {
		return "j/k Navigate   l Select   q Quit"
	}
	return "j/k Navigate   l Select   q Quit"
}
// Component types available for testing
ComponentType :: enum {
	BOX,
	LIST_ITEM,
	HEADER,
	FOOTER,
	SCROLL_INDICATOR,
	EMPTY_STATE,
}

// Arguments for component rendering
ComponentArgs :: struct {
	// Common args
	width:    int,
	height:   int,

	// Text content
	text:     string,
	title:    string,
	message:  string,

	// State
	selected: bool,

	// Numeric data
	count:    int,
	start:    int,  // For scroll indicator
	end:      int,
	total:    int,

	// Visual elements
	emoji:    string,
	shortcuts: string,  // Comma-separated "key=action" pairs
}

// Parse component type from string
parse_component_type :: proc(name: string) -> (ComponentType, bool) {
	switch name {
	case "box":
		return .BOX, true
	case "list-item", "list_item":
		return .LIST_ITEM, true
	case "header":
		return .HEADER, true
	case "footer":
		return .FOOTER, true
	case "scroll", "scroll-indicator", "scroll_indicator":
		return .SCROLL_INDICATOR, true
	case "empty", "empty-state", "empty_state":
		return .EMPTY_STATE, true
	case:
		return .BOX, false  // Default, but signal error
	}
}

// Parse component arguments from CLI
parse_component_args :: proc(args: []string) -> ComponentArgs {
	result := ComponentArgs{
		width = 80,   // Default terminal width
		height = 24,  // Default terminal height
		selected = false,
	}

	for arg in args {
		if !strings.contains(arg, "=") do continue

		parts := strings.split(arg, "=")
		defer delete(parts)

		if len(parts) != 2 do continue

		key := strings.trim_space(parts[0])
		value := strings.trim_space(parts[1])

		switch key {
		case "width":
			result.width, _ = strconv.parse_int(value)
		case "height":
			result.height, _ = strconv.parse_int(value)
		case "text":
			result.text = strings.clone(value)
		case "title":
			result.title = strings.clone(value)
		case "message":
			result.message = strings.clone(value)
		case "selected":
			result.selected = (value == "true" || value == "1")
		case "count":
			result.count, _ = strconv.parse_int(value)
		case "start":
			result.start, _ = strconv.parse_int(value)
		case "end":
			result.end, _ = strconv.parse_int(value)
		case "total":
			result.total, _ = strconv.parse_int(value)
		case "emoji":
			result.emoji = strings.clone(value)
		case "shortcuts":
			result.shortcuts = strings.clone(value)
		}
	}

	return result
}

// Free component args memory
component_args_destroy :: proc(args: ^ComponentArgs) {
	if args.text != "" do delete(args.text)
	if args.title != "" do delete(args.title)
	if args.message != "" do delete(args.message)
	if args.emoji != "" do delete(args.emoji)
	if args.shortcuts != "" do delete(args.shortcuts)
}

// Render component to plain text string (headless)
render_component :: proc(type: ComponentType, args: ComponentArgs) -> string {
	// Create headless screen buffer
	screen := screen_create(args.width, args.height)
	defer screen_destroy(&screen)

	// Clear to spaces
	screen_clear(&screen)

	// Render based on component type
	switch type {
	case .BOX:
		// Render box filling entire screen
		tui_render_box(&screen, 0, 0, args.width, args.height)

	case .LIST_ITEM:
		// Render list item with selection indicator
		prefix: string
		if args.selected {
			prefix = "> "
		} else {
			prefix = "  "
		}
		text := fmt.tprintf("%s%s", prefix, args.text)
		// Note: tprintf() uses temp buffer, do NOT delete
		render_text(&screen, 0, 0, text)

	case .HEADER:
		// Render header with emoji and title
		header_line: string
		if args.emoji != "" {
			header_line = fmt.tprintf("%s %s", args.emoji, args.title)
		} else {
			header_line = args.title
		}
		// Note: tprintf() uses temp buffer, do NOT delete
		render_text(&screen, 2, 0, header_line)

		// Render count if provided
		if args.count > 0 {
			count_line := fmt.tprintf("%d entries", args.count)
			// Note: tprintf() uses temp buffer, do NOT delete
			render_text(&screen, 2, 1, count_line)
		}

	case .FOOTER:
		// Render footer at bottom
		render_text(&screen, 2, args.height - 1, args.shortcuts)

	case .SCROLL_INDICATOR:
		// Render scroll position
		scroll_text := fmt.tprintf("Showing %d-%d of %d",
			args.start, args.end, args.total)
		// Note: tprintf() uses temp buffer, do NOT delete
		render_text(&screen, 2, 0, scroll_text)

	case .EMPTY_STATE:
		// Center message vertically and horizontally
		message := args.message
		if message == "" {
			message = "No items found"
		}
		y := args.height / 2
		x := (args.width - len(message)) / 2
		render_text(&screen, x, y, message)
	}

	// Convert to plain text
	output := screen_to_string(&screen)
	return output
}
