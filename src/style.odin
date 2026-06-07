package wayu

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

// Complete style system for PRP-07
//
// Style, Alignment, BorderStyle, and the Color/COLOR_CONSTANTS bundle were
// previously parked in types.odin with a comment about "avoiding circular
// imports". There was no actual circular import — all consumers live in the
// same `wayu` package — so they're folded back in here as of 2026-04-24
// (code review L6).

// Style system types.
Style :: struct {
	foreground: string,
	background: string,
	bold: bool,
	italic: bool,
	underline: bool,
	strikethrough: bool,
	dim: bool,
	blink: bool,
	reverse: bool,
	faint: bool,
	padding_top: int,
	padding_right: int,
	padding_bottom: int,
	padding_left: int,
	margin_top: int,
	margin_right: int,
	margin_bottom: int,
	margin_left: int,
	width: int,
	height: int,
	max_width: int,
	max_height: int,
	align_horizontal: Alignment,
	align_vertical: Alignment,
	border_style: BorderStyle,
	border_top: bool,
	border_right: bool,
	border_bottom: bool,
	border_left: bool,
	border_fg: string,
	border_bg: string,
	foreground_dark: string,
	background_dark: string,
}

Alignment :: enum {
	Left,
	Center,
	Right,
	Top,
	Middle,
	Bottom,
}

BorderStyle :: enum {
	None,
	Normal,
	Rounded,
	Thick,
	Double,
	Hidden,
}

// Color constants bundle.
Color :: struct {
	Red: string,
	Green: string,
	Yellow: string,
	Blue: string,
	Magenta: string,
	Cyan: string,
	White: string,
	Black: string,
}

COLOR_CONSTANTS :: Color{
	Red = "31",
	Green = "32",
	Yellow = "33",
	Blue = "34",
	Magenta = "35",
	Cyan = "36",
	White = "37",
	Black = "30",
}


// Full render function with complete style pipeline
render :: proc(s: Style, text: string) -> string {
	if text == "" {
		return ""
	}

	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	// Split text into lines for processing
	lines := strings.split(text, "\n")
	defer delete(lines)

	// Apply top margin
	for _ in 0..<s.margin_top {
		strings.write_string(&builder, "\n")
	}

	// Calculate content width (considering width constraints)
	content_width := calculate_content_width(s, lines)

	// Render top border
	if s.border_top {
		render_style_border_line(&builder, s, .Top, content_width)
	}

	// Apply top padding
	for _ in 0..<s.padding_top {
		render_empty_line(&builder, s, content_width)
	}

	// Render content lines
	for line in lines {
		render_content_line(&builder, s, line, content_width)
	}

	// Apply bottom padding
	for _ in 0..<s.padding_bottom {
		render_empty_line(&builder, s, content_width)
	}

	// Render bottom border
	if s.border_bottom {
		render_style_border_line(&builder, s, .Bottom, content_width)
	}

	// Apply bottom margin
	for _ in 0..<s.margin_bottom {
		strings.write_string(&builder, "\n")
	}

	return strings.clone(strings.to_string(builder))
}

// ============================================================================
// RENDER PIPELINE HELPERS
// ============================================================================

BorderPosition :: enum {
	Top,
	Bottom,
	Left,
	Right,
	TopLeft,
	TopRight,
	BottomLeft,
	BottomRight,
}

// Calculate the actual width for rendering content
calculate_content_width :: proc(s: Style, lines: []string) -> int {
	// If width is explicitly set, use it
	if s.width > 0 {
		return s.width
	}

	// Otherwise, find the longest line
	max_len := 0
	for line in lines {
		line_len := visible_width(line)
		if line_len > max_len {
			max_len = line_len
		}
	}

	// Apply max_width constraint if set
	if s.max_width > 0 && max_len > s.max_width {
		return s.max_width
	}

	return max_len
}

// Get visible width of text (excluding ANSI codes)
visible_width :: proc(text: string) -> int {
	// Handle ANSI codes and approximate emoji width
	count := 0
	in_escape := false
	i := 0
	for i < len(text) {
		b := text[i]

		// ANSI escape sequence
		if b == '\x1b' {
			in_escape = true
			i += 1
			continue
		}

		if in_escape {
			if b == 'm' {
				in_escape = false
			}
			i += 1
			continue
		}

		// Count character width
		// Most emojis are in range U+1F300 to U+1F9FF (4-byte UTF-8)
		// They display as 2 characters wide
		if b >= 0xF0 && b <= 0xF4 { // 4-byte UTF-8 start byte
			// Emoji or other wide character - count as 2
			count += 2
			// Skip remaining bytes of UTF-8 sequence
			i += 4
		} else if b >= 0xE0 && b <= 0xEF { // 3-byte UTF-8
			// Check for special symbols that might be wide
			if b == 0xE2 && i + 2 < len(text) {
				// Common symbols like ✓, ✗, ▸, etc are in this range
				// Most are 1 char wide except emoji variants
				count += 1
			} else {
				count += 1
			}
			i += 3
		} else if b >= 0xC0 && b <= 0xDF { // 2-byte UTF-8
			count += 1
			i += 2
		} else { // ASCII
			count += 1
			i += 1
		}
	}
	return count
}

// Render a border line (top or bottom) for styled content
render_style_border_line :: proc(builder: ^strings.Builder, s: Style, pos: BorderPosition, width: int) {
	// Left margin
	write_spaces(builder, s.margin_left)

	// Apply border colors if set
	if s.border_fg != "" {
		apply_color(builder, s.border_fg, true)
	}
	if s.border_bg != "" {
		apply_color(builder, s.border_bg, false)
	}

	// Corner
	if s.border_left {
		corner_char := get_border_char(s.border_style, pos == .Top ? .TopLeft : .BottomLeft)
		strings.write_string(builder, corner_char)
	}

	// Horizontal line (accounting for left and right padding)
	total_width := width + s.padding_left + s.padding_right
	horizontal_char := get_border_char(s.border_style, pos)
	for _ in 0..<total_width {
		strings.write_string(builder, horizontal_char)
	}

	// Corner
	if s.border_right {
		corner_char := get_border_char(s.border_style, pos == .Top ? .TopRight : .BottomRight)
		strings.write_string(builder, corner_char)
	}

	// Reset colors
	if s.border_fg != "" || s.border_bg != "" {
		strings.write_string(builder, RESET)
	}

	strings.write_string(builder, "\n")
}

// Render an empty line with padding and borders
render_empty_line :: proc(builder: ^strings.Builder, s: Style, width: int) {
	// Left margin
	write_spaces(builder, s.margin_left)

	// Left border
	if s.border_left {
		if s.border_fg != "" {
			apply_color(builder, s.border_fg, true)
		}
		strings.write_string(builder, get_border_char(s.border_style, .Left))
		if s.border_fg != "" {
			strings.write_string(builder, RESET)
		}
	}

	// Left padding + content + right padding
	total_width := s.padding_left + width + s.padding_right
	write_spaces(builder, total_width)

	// Right border
	if s.border_right {
		if s.border_fg != "" {
			apply_color(builder, s.border_fg, true)
		}
		strings.write_string(builder, get_border_char(s.border_style, .Right))
		if s.border_fg != "" {
			strings.write_string(builder, RESET)
		}
	}

	strings.write_string(builder, "\n")
}

// Render a content line with full styling
render_content_line :: proc(builder: ^strings.Builder, s: Style, line: string, width: int) {
	// Left margin
	write_spaces(builder, s.margin_left)

	// Left border
	if s.border_left {
		if s.border_fg != "" {
			apply_color(builder, s.border_fg, true)
		}
		strings.write_string(builder, get_border_char(s.border_style, .Left))
		if s.border_fg != "" {
			strings.write_string(builder, RESET)
		}
	}

	// Left padding
	write_spaces(builder, s.padding_left)

	// Apply text styles and render content
	styled_content := apply_text_styles(s, line, width)
	strings.write_string(builder, styled_content)

	// Right padding
	write_spaces(builder, s.padding_right)

	// Right border
	if s.border_right {
		if s.border_fg != "" {
			apply_color(builder, s.border_fg, true)
		}
		strings.write_string(builder, get_border_char(s.border_style, .Right))
		if s.border_fg != "" {
			strings.write_string(builder, RESET)
		}
	}

	strings.write_string(builder, "\n")
}

// Apply text styles (colors, bold, italic, etc.) to content
apply_text_styles :: proc(s: Style, text: string, width: int) -> string {
	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	// Apply background color first (it should cover the whole width)
	if s.background != "" {
		apply_color(&builder, s.background, false)
	}

	// Apply text formatting
	if s.bold {
		strings.write_string(&builder, BOLD)
	}
	if s.italic {
		strings.write_string(&builder, ITALIC)
	}
	if s.underline {
		strings.write_string(&builder, UNDERLINE)
	}
	if s.dim {
		strings.write_string(&builder, DIM)
	}

	// Apply foreground color
	if s.foreground != "" {
		apply_color(&builder, s.foreground, true)
	}

	// Align and write the text
	aligned_text := align_text(text, width, s.align_horizontal)
	defer delete(aligned_text)
	strings.write_string(&builder, aligned_text)

	// Reset all styles
	strings.write_string(&builder, RESET)

	return strings.to_string(builder)
}

// Apply only text styles (colors, bold, italic) without layout (borders, padding, margins)
// This is used by table rendering to style individual cells without adding structure
apply_text_only_style :: proc(s: Style, text: string) -> string {
	if text == "" {
		return ""
	}

	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	// Apply text formatting
	if s.bold {
		strings.write_string(&builder, BOLD)
	}
	if s.italic {
		strings.write_string(&builder, ITALIC)
	}
	if s.underline {
		strings.write_string(&builder, UNDERLINE)
	}
	if s.dim {
		strings.write_string(&builder, DIM)
	}
	// Note: strikethrough not currently supported (no constant defined)

	// Apply colors
	if s.foreground != "" {
		apply_color(&builder, s.foreground, true)
	}
	if s.background != "" {
		apply_color(&builder, s.background, false)
	}

	// Write text as-is (no alignment or padding)
	strings.write_string(&builder, text)

	// Reset formatting
	strings.write_string(&builder, RESET)

	return strings.clone(strings.to_string(builder))
}

// Apply color (foreground or background)
apply_color :: proc(builder: ^strings.Builder, color: string, is_foreground: bool) {
	// Check if it's already a full ANSI code
	if strings.has_prefix(color, "\x1b[") {
		strings.write_string(builder, color)
		return
	}

	// Check if it's RGB format (r;g;b)
	if strings.contains(color, ";") {
		prefix := is_foreground ? "\x1b[38;2;" : "\x1b[48;2;"
		fmt.sbprintf(builder, "%s%sm", prefix, color)
		return
	}

	// Check if it's a named ANSI color
	code := ""
	switch color {
	case "black":   code = is_foreground ? "30" : "40"
	case "red":     code = is_foreground ? "31" : "41"
	case "green":   code = is_foreground ? "32" : "42"
	case "yellow":  code = is_foreground ? "33" : "43"
	case "blue":    code = is_foreground ? "34" : "44"
	case "magenta": code = is_foreground ? "35" : "45"
	case "cyan":    code = is_foreground ? "36" : "46"
	case "white":   code = is_foreground ? "37" : "47"
	}

	if code != "" {
		fmt.sbprintf(builder, "\x1b[%sm", code)
	}
}

// Get border character for a given position
get_border_char :: proc(style: BorderStyle, pos: BorderPosition) -> string {
	switch style {
	case .None, .Hidden:
		return " "

	case .Normal:
		switch pos {
		case .Top, .Bottom:      return "─"
		case .Left, .Right:      return "│"
		case .TopLeft:           return "┌"
		case .TopRight:          return "┐"
		case .BottomLeft:        return "└"
		case .BottomRight:       return "┘"
		}

	case .Rounded:
		switch pos {
		case .Top, .Bottom:      return "─"
		case .Left, .Right:      return "│"
		case .TopLeft:           return "╭"
		case .TopRight:          return "╮"
		case .BottomLeft:        return "╰"
		case .BottomRight:       return "╯"
		}

	case .Thick:
		switch pos {
		case .Top, .Bottom:      return "━"
		case .Left, .Right:      return "┃"
		case .TopLeft:           return "┏"
		case .TopRight:          return "┓"
		case .BottomLeft:        return "┗"
		case .BottomRight:       return "┛"
		}

	case .Double:
		switch pos {
		case .Top, .Bottom:      return "═"
		case .Left, .Right:      return "║"
		case .TopLeft:           return "╔"
		case .TopRight:          return "╗"
		case .BottomLeft:        return "╚"
		case .BottomRight:       return "╝"
		}
	}

	return " "
}

// Truncate text to fit within a given visual width, adding ellipsis if needed
// Handles ANSI escape sequences properly (doesn't count them as visible width)
truncate_to_width :: proc(text: string, max_width: int) -> string {
	if max_width <= 0 {
		return ""
	}

	text_width := visual_width(text)

	// No truncation needed
	if text_width <= max_width {
		return text
	}

	// Need at least 4 chars for truncation to make sense (1 char + "...")
	if max_width < 4 {
		// Just return dots up to max_width
		dots := strings.repeat(".", max_width)
		return dots
	}

	// Build truncated string character by character
	result := strings.Builder{}
	strings.builder_init(&result)
	defer strings.builder_destroy(&result)

	target_width := max_width - 3 // Reserve space for "..."
	current_width := 0
	in_escape := false
	i := 0

	for i < len(text) {
		b := text[i]

		// Handle ANSI escape sequences - copy them without counting width
		if b == '\x1b' {
			in_escape = true
			strings.write_byte(&result, b)
			i += 1
			continue
		}

		if in_escape {
			strings.write_byte(&result, b)
			if b == 'm' {
				in_escape = false
			}
			i += 1
			continue
		}

		// Determine character width
		char_width := 1
		char_len := 1

		if b >= 0xF0 && b <= 0xF4 { // 4-byte UTF-8 (emoji)
			char_width = 2
			char_len = 4
		} else if b >= 0xE0 && b <= 0xEF { // 3-byte UTF-8
			char_width = 1
			char_len = 3
		} else if b >= 0xC0 && b <= 0xDF { // 2-byte UTF-8
			char_width = 1
			char_len = 2
		}

		// Check if adding this character would exceed target width
		if current_width + char_width > target_width {
			break
		}

		// Copy the character bytes
		for j in 0..<char_len {
			if i + j < len(text) {
				strings.write_byte(&result, text[i + j])
			}
		}

		current_width += char_width
		i += char_len
	}

	// Add ellipsis
	strings.write_string(&result, "...")

	// Close any open ANSI sequences
	strings.write_string(&result, RESET)

	return strings.clone(strings.to_string(result))
}

// Align text within a given width
// NOTE: Always returns an ALLOCATED string — caller must delete()
align_text :: proc(text: string, width: int, alignment: Alignment) -> string {
	text_width := visible_width(text)

	// If text is already wider than target, truncate to fit
	if text_width >= width {
		truncated := truncate_to_width(text, width)
		// truncate_to_width returns the original string (no alloc) when it fits,
		// or a cloned string when it truncates. We need consistent ownership.
		if raw_data(truncated) == raw_data(text) {
			return strings.clone(text)
		}
		return truncated
	}

	padding_needed := width - text_width

	#partial switch alignment {
	case .Left:
		// Add padding on the right
		pad := strings.repeat(" ", padding_needed)
		defer delete(pad)
		return fmt.aprintf("%s%s", text, pad)

	case .Center:
		// Add padding on both sides
		left_pad := padding_needed / 2
		right_pad := padding_needed - left_pad
		left_pad_str := strings.repeat(" ", left_pad)
		defer delete(left_pad_str)
		right_pad_str := strings.repeat(" ", right_pad)
		defer delete(right_pad_str)
		return fmt.aprintf("%s%s%s",
			left_pad_str,
			text,
			right_pad_str)

	case .Right:
		// Add padding on the left
		pad := strings.repeat(" ", padding_needed)
		defer delete(pad)
		return fmt.aprintf("%s%s", pad, text)

	case:
		// Default to left alignment
		pad := strings.repeat(" ", padding_needed)
		defer delete(pad)
		return fmt.aprintf("%s%s", text, pad)
	}
}

// Write N spaces to builder
write_spaces :: proc(builder: ^strings.Builder, count: int) {
	for _ in 0..<count {
		strings.write_string(builder, " ")
	}
}

// ============================================================================
// STYLE CREATION AND BUILDERS
// ============================================================================

// Basic style creation
new_style :: proc() -> Style {
	return Style{}
}

// Style builder methods
style_foreground :: proc(s: Style, color: string) -> Style {
	result := s
	result.foreground = color
	return result
}

style_bold :: proc(s: Style, enable: bool = true) -> Style {
	result := s
	result.bold = enable
	return result
}

// ============================================================================
// UNICODE WIDTH UTILITIES (moved from layout.odin)
// ============================================================================

// visual_width returns the number of terminal columns a string occupies.
// It correctly handles ANSI escape sequences (zero width) and wide Unicode
// characters such as CJK ideographs and emoji (two columns each).
// Zero-allocation: iterates runes in-place via utf8.decode_rune.
visual_width :: proc(str: string) -> int {
	visible_chars := 0
	i := 0
	raw := transmute([]u8)str

	for i < len(raw) {
		b := raw[i]

		// Fast path: ANSI escape sequences
		if b == 0x1B && i + 1 < len(raw) {
			next := raw[i + 1]
			if next == '[' {
				// CSI sequence (ESC[...m/K/J/H)
				i += 2
				for i < len(raw) && raw[i] != 'm' && raw[i] != 'K' && raw[i] != 'J' && raw[i] != 'H' {
					i += 1
				}
				if i < len(raw) {
					i += 1 // Skip terminator
				}
			} else if next == ']' {
				// OSC sequence (ESC]...BEL or ESC]...ST)
				i += 2
				for i < len(raw) {
					if raw[i] == 0x07 {
						i += 1
						break
					}
					if raw[i] == 0x1B && i + 1 < len(raw) && raw[i + 1] == '\\' {
						i += 2
						break
					}
					i += 1
				}
			} else {
				i += 2
			}
		} else {
			// Decode one UTF-8 rune in-place (no allocation)
			r, size := utf8.decode_rune(raw[i:])
			if size == 0 { size = 1 } // skip invalid byte
			visible_chars += get_rune_width(r)
			i += size
		}
	}

	return visible_chars
}

// get_rune_width returns the display width of a single Unicode rune.
// Control characters return 0; wide characters (CJK, emoji) return 2;
// all other printable characters return 1.
get_rune_width :: proc(r: rune) -> int {
	// Control characters have zero width
	if r < 32 || (r >= 0x7F && r < 0xA0) {
		return 0
	}

	// Authoritative per-glyph widths (Ghostty-tuned) for the specific symbols,
	// box-drawing characters, and emoji used across the app. This table is the
	// single source of truth shared with the form/TUI width path; it overrides
	// the coarse range checks below for known characters (e.g. ⚠ is width 1).
	if w, ok := special_char_width(r); ok {
		return w
	}

	// Wide characters (CJK, emojis, etc.) take 2 columns
	if is_wide_character(r) {
		return 2
	}

	// Regular characters take 1 column
	return 1
}

// is_wide_character reports whether a rune occupies two terminal columns.
// Covers emoji, CJK unified ideographs, Hangul, Katakana, Hiragana, and
// related Unicode blocks. Common single-width symbols (✓ ✗) are excluded.
is_wide_character :: proc(r: rune) -> bool {
	// Special handling for problematic characters that appear in our tables
	// These specific characters are often rendered as single-width in modern terminals
	if r == 0x2713 || r == 0x2717 { // ✓ ✗ - Check mark and X mark
		return false // These are actually single-width in most terminals
	}

	// Emoji ranges (simplified)
	if (r >= 0x1F600 && r <= 0x1F64F) || // Emoticons
	   (r >= 0x1F300 && r <= 0x1F5FF) || // Misc Symbols and Pictographs
	   (r >= 0x1F680 && r <= 0x1F6FF) || // Transport and Map
	   (r >= 0x1F700 && r <= 0x1F77F) || // Alchemical Symbols
	   (r >= 0x1F780 && r <= 0x1F7FF) || // Geometric Shapes Extended
	   (r >= 0x1F800 && r <= 0x1F8FF) || // Supplemental Arrows-C
	   (r >= 0x1F900 && r <= 0x1F9FF) || // Supplemental Symbols and Pictographs
	   (r >= 0x1FA00 && r <= 0x1FA6F) || // Chess Symbols
	   (r >= 0x1FA70 && r <= 0x1FAFF) || // Symbols and Pictographs Extended-A
	   (r >= 0x2600 && r <= 0x26FF) ||   // Miscellaneous Symbols
	   (r >= 0x1F000 && r <= 0x1F02F) || // Mahjong Tiles
	   (r >= 0x1F0A0 && r <= 0x1F0FF) {  // Playing Cards
		return true
	}

	// Dingbats range but excluding specific single-width characters
	if r >= 0x2700 && r <= 0x27BF {
		// Most dingbats are wide, but some common ones are single-width
		if r == 0x2713 || r == 0x2717 || r == 0x2718 || r == 0x2719 ||
		   r == 0x271A || r == 0x271B || r == 0x271C || r == 0x271D {
			return false
		}
		return true
	}

	// CJK ranges
	if (r >= 0x1100 && r <= 0x115F) ||   // Hangul Jamo
	   (r >= 0x2E80 && r <= 0x2EFF) ||   // CJK Radicals Supplement
	   (r >= 0x2F00 && r <= 0x2FDF) ||   // Kangxi Radicals
	   (r >= 0x3000 && r <= 0x303F) ||   // CJK Symbols and Punctuation
	   (r >= 0x3040 && r <= 0x309F) ||   // Hiragana
	   (r >= 0x30A0 && r <= 0x30FF) ||   // Katakana
	   (r >= 0x3100 && r <= 0x312F) ||   // Bopomofo
	   (r >= 0x3130 && r <= 0x318F) ||   // Hangul Compatibility Jamo
	   (r >= 0x3190 && r <= 0x319F) ||   // Kanbun
	   (r >= 0x31A0 && r <= 0x31BF) ||   // Bopomofo Extended
	   (r >= 0x31C0 && r <= 0x31EF) ||   // CJK Strokes
	   (r >= 0x31F0 && r <= 0x31FF) ||   // Katakana Phonetic Extensions
	   (r >= 0x3200 && r <= 0x32FF) ||   // Enclosed CJK Letters and Months
	   (r >= 0x3300 && r <= 0x33FF) ||   // CJK Compatibility
	   (r >= 0x3400 && r <= 0x4DBF) ||   // CJK Extension A
	   (r >= 0x4E00 && r <= 0x9FFF) ||   // CJK Unified Ideographs
	   (r >= 0xA000 && r <= 0xA48F) ||   // Yi Syllables
	   (r >= 0xA490 && r <= 0xA4CF) ||   // Yi Radicals
	   (r >= 0xAC00 && r <= 0xD7AF) ||   // Hangul Syllables
	   (r >= 0xF900 && r <= 0xFAFF) ||   // CJK Compatibility Ideographs
	   (r >= 0xFE10 && r <= 0xFE1F) ||   // Vertical Forms
	   (r >= 0xFE30 && r <= 0xFE4F) ||   // CJK Compatibility Forms
	   (r >= 0xFF00 && r <= 0xFFEF) ||   // Halfwidth and Fullwidth Forms
	   (r >= 0x20000 && r <= 0x2A6DF) || // CJK Extension B
	   (r >= 0x2A700 && r <= 0x2B73F) || // CJK Extension C
	   (r >= 0x2B740 && r <= 0x2B81F) || // CJK Extension D
	   (r >= 0x2B820 && r <= 0x2CEAF) || // CJK Extension E
	   (r >= 0x2CEB0 && r <= 0x2EBEF) {  // CJK Extension F
		return true
	}

	return false
}