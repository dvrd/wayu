// special_chars.odin - Special character definitions and width calculations
//
// This module provides accurate visual width calculations for all special
// characters used in wayu's UI, including emojis, symbols, and box-drawing
// characters. Each character is explicitly mapped to avoid terminal rendering
// inconsistencies.

package wayu

// SpecialChar represents a special character with its visual width
SpecialChar :: struct {
	char:         rune,
	visual_width: int,
	description:  string,
}

// All special characters used in wayu with their accurate visual widths
// Width is determined by actual terminal rendering behavior
// Note: Different terminals render these characters differently:
// - Ghostty terminal: Width 1 for nerd font symbols, Width 2 for emojis
// - Legacy terminals: May vary
// These mappings are based on Ghostty terminal behavior
SPECIAL_CHARS :: [?]SpecialChar{
	// Status and UI symbols - Width 1 (nerd font icons in Ghostty)
	{char = '⚠', visual_width = 1, description = "Warning Sign (U+26A0)"},
	{char = '✓', visual_width = 1, description = "Check Mark (U+2713)"},
	{char = '✗', visual_width = 1, description = "Ballot X (U+2717)"},
	{char = '⌨', visual_width = 1, description = "Keyboard (U+2328)"},
	{char = 'ℹ', visual_width = 1, description = "Information Source (U+2139)"},

	// Emojis - Width 2 (true emojis in Ghostty)
	{char = '✨', visual_width = 2, description = "Sparkles (U+2728)"},
	{char = '📝', visual_width = 2, description = "Memo (U+1F4DD)"},
	{char = '💾', visual_width = 2, description = "Floppy Disk (U+1F4BE)"},
	{char = '🚀', visual_width = 2, description = "Rocket (U+1F680)"},
	{char = '⛰', visual_width = 2, description = "Mountain (U+26F0)"},
	{char = '🔧', visual_width = 2, description = "Wrench (U+1F527)"},
	{char = '🎯', visual_width = 2, description = "Direct Hit (U+1F3AF)"},

	// Box drawing characters (Width 1 - ASCII-like)
	{char = '╭', visual_width = 1, description = "Box Drawings Light Arc Down and Right"},
	{char = '╮', visual_width = 1, description = "Box Drawings Light Arc Down and Left"},
	{char = '╰', visual_width = 1, description = "Box Drawings Light Arc Up and Right"},
	{char = '╯', visual_width = 1, description = "Box Drawings Light Arc Up and Left"},
	{char = '│', visual_width = 1, description = "Box Drawings Light Vertical"},
	{char = '─', visual_width = 1, description = "Box Drawings Light Horizontal"},
	{char = '┌', visual_width = 1, description = "Box Drawings Light Down and Right"},
	{char = '┐', visual_width = 1, description = "Box Drawings Light Down and Left"},
	{char = '└', visual_width = 1, description = "Box Drawings Light Up and Right"},
	{char = '┘', visual_width = 1, description = "Box Drawings Light Up and Left"},
	{char = '├', visual_width = 1, description = "Box Drawings Light Vertical and Right"},
	{char = '┤', visual_width = 1, description = "Box Drawings Light Vertical and Left"},
	{char = '┬', visual_width = 1, description = "Box Drawings Light Down and Horizontal"},
	{char = '┴', visual_width = 1, description = "Box Drawings Light Up and Horizontal"},
	{char = '┼', visual_width = 1, description = "Box Drawings Light Vertical and Horizontal"},

	// Additional symbols used in the app
	{char = '•', visual_width = 1, description = "Bullet (U+2022)"},
	{char = '◦', visual_width = 1, description = "White Bullet (U+25E6)"},
	{char = '→', visual_width = 1, description = "Rightwards Arrow (U+2192)"},
	{char = '←', visual_width = 1, description = "Leftwards Arrow (U+2190)"},
	{char = '↑', visual_width = 1, description = "Upwards Arrow (U+2191)"},
	{char = '↓', visual_width = 1, description = "Downwards Arrow (U+2193)"},
	{char = '█', visual_width = 1, description = "Full Block (U+2588)"},
	{char = '▌', visual_width = 1, description = "Left Half Block (U+258C)"},
	{char = '▐', visual_width = 1, description = "Right Half Block (U+2590)"},
}

// Build a lookup map for O(1) character width lookups
@(private)
special_char_widths: map[rune]int

@(private)
special_chars_initialized := false

// Initialize the special character width map
init_special_chars :: proc() {
	if special_chars_initialized {
		return
	}

	special_char_widths = make(map[rune]int)
	for char in SPECIAL_CHARS {
		special_char_widths[char.char] = char.visual_width
	}

	special_chars_initialized = true
}

// Get the visual width of a single rune
// Returns the accurate width based on:
// 1. Special character mapping (for known characters)
// 2. Unicode ranges for CJK and emojis (for unmapped characters)
// 3. Default to width 1 for everything else
get_rune_visual_width :: proc(r: rune) -> int {
	// Ensure special chars are initialized
	if !special_chars_initialized {
		init_special_chars()
	}

	// Check if it's a known special character
	if width, ok := special_char_widths[r]; ok {
		return width
	}

	// Fallback: Use Unicode ranges for unmapped characters
	// CJK, Fullwidth, and Emojis are width 2 in Ghostty
	if (r >= 0x3000 && r <= 0x303F) ||     // CJK Symbols and Punctuation
	   (r >= 0xFF00 && r <= 0xFFEF) ||     // Fullwidth Forms
	   (r >= 0x1F300 && r <= 0x1F9FF) {    // Emoji range
		return 2
	}

	// Default: most characters are width 1 (symbols, box drawing, etc.)
	return 1
}

// Calculate the visual width of a string
// This accounts for:
// - Special characters with explicit width mappings
// - Wide characters (CJK, emojis)
// - Regular ASCII characters
get_string_visual_width :: proc(s: string) -> int {
	width := 0
	for r in s {
		width += get_rune_visual_width(r)
	}
	return width
}

// Calculate the visual width of a string, ignoring ANSI escape codes
// This strips color codes and formatting before calculating width
get_visual_width_no_ansi :: proc(s: string) -> int {
	width := 0
	in_escape := false

	for r in s {
		if r == '\x1b' {
			in_escape = true
		} else if in_escape && r == 'm' {
			in_escape = false
		} else if !in_escape {
			width += get_rune_visual_width(r)
		}
	}

	return width
}

// Cleanup procedure for special chars map
destroy_special_chars :: proc() {
	if special_chars_initialized {
		delete(special_char_widths)
		special_chars_initialized = false
	}
}
