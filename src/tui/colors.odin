// tui_colors.odin - TUI Color System (Phase 1: Color Foundation)
//
// ANSI TrueColor (24-bit RGB) palette for terminal UI.
// Uses \x1b[38;2;R;G;Bm for foreground, \x1b[48;2;R;G;Bm for background.
//
// Color palette: Zellij "dvrd" inspired theme
// - Hot pink primary for highlights and focus
// - Teal-cyan secondary for success and info
// - Dark backgrounds for readability
// - High contrast for accessibility
//
// NOTE: Duplicated from src/colors.odin to avoid circular dependency

package wayu_tui

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
// Control Codes
// ============================================================================

// Reset all attributes
TUI_RESET :: "\x1b[0m"

// Bold text
TUI_BOLD :: "\x1b[1m"

// Dim text (lower intensity)
TUI_DIM_CODE :: "\x1b[2m"

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
