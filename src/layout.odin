package wayu

import "core:fmt"
import "core:strings"
import "core:math"
import "core:unicode/utf8"

// Layout helpers for PRP-07 (Phase 1 + Phase 4 advanced features)
visual_width :: proc(str: string) -> int {
	// Properly handle ANSI escape sequences and Unicode characters to get actual visual width
	visible_chars := 0
	runes := utf8.string_to_runes(str)
	defer delete(runes)

	i := 0
	for i < len(runes) {
		r := runes[i]

		// Check for ANSI escape sequences
		if r == '\x1b' && i + 1 < len(runes) {
			if runes[i + 1] == '[' {
				// CSI sequence (ESC[...m)
				i += 2 // Skip ESC[
				for i < len(runes) && runes[i] != 'm' && runes[i] != 'K' && runes[i] != 'J' && runes[i] != 'H' {
					i += 1
				}
				if i < len(runes) {
					i += 1 // Skip the terminator
				}
			} else if runes[i + 1] == ']' {
				// OSC sequence (ESC]...BEL or ESC]...ST)
				i += 2 // Skip ESC]
				for i < len(runes) {
					if runes[i] == '\x07' || (runes[i] == '\x1b' && i + 1 < len(runes) && runes[i + 1] == '\\') {
						if runes[i] == '\x1b' {
							i += 2 // Skip ESC\
						} else {
							i += 1 // Skip BEL
						}
						break
					}
					i += 1
				}
			} else {
				// Other escape sequences
				i += 2
			}
		} else {
			// Handle Unicode characters with proper width calculation
			width := get_rune_width(r)
			visible_chars += width
			i += 1
		}
	}

	return visible_chars
}

// Get display width of a Unicode character
get_rune_width :: proc(r: rune) -> int {
	// Control characters have zero width
	if r < 32 || (r >= 0x7F && r < 0xA0) {
		return 0
	}

	// Wide characters (CJK, emojis, etc.) take 2 columns
	if is_wide_character(r) {
		return 2
	}

	// Regular characters take 1 column
	return 1
}

// Check if a character is wide (takes 2 terminal columns)
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

join_horizontal :: proc(strs: ..string) -> string {
	return strings.concatenate(strs[:])
}

join_vertical :: proc(strs: ..string) -> string {
	return strings.join(strs[:], "\n")
}

width :: proc(str: string) -> int {
	return visual_width(str)
}

height :: proc(str: string) -> int {
	lines := strings.split_lines(str)
	defer delete(lines)
	return len(lines)
}

// Advanced layout utilities for Phase 4

// Layout container for flexible layout management
Layout :: struct {
	direction:      FlexDirection,
	justify:        JustifyContent,
	align_items:    AlignItems,
	wrap:          FlexWrap,
	gap:           int,
	padding:       Padding,
	margin:        Margin,
	width:         int,
	height:        int,
	max_width:     int,
	max_height:    int,
}

FlexDirection :: enum {
	Row,
	Column,
	RowReverse,
	ColumnReverse,
}

JustifyContent :: enum {
	Start,
	Center,
	End,
	SpaceBetween,
	SpaceAround,
	SpaceEvenly,
}

AlignItems :: enum {
	Start,
	Center,
	End,
	Stretch,
}

FlexWrap :: enum {
	NoWrap,
	Wrap,
	WrapReverse,
}

Padding :: struct {
	top, right, bottom, left: int,
}

Margin :: struct {
	top, right, bottom, left: int,
}

// Create a new layout container
new_layout :: proc() -> Layout {
	return Layout{
		direction   = .Column,
		justify     = .Start,
		align_items = .Start,
		wrap        = .NoWrap,
		gap         = 0,
		width       = 0,
		height      = 0,
		max_width   = 0,
		max_height  = 0,
	}
}

// Layout builder methods
layout_direction :: proc(layout: ^Layout, direction: FlexDirection) -> ^Layout {
	layout.direction = direction
	return layout
}

layout_justify :: proc(layout: ^Layout, justify: JustifyContent) -> ^Layout {
	layout.justify = justify
	return layout
}

layout_align :: proc(layout: ^Layout, align: AlignItems) -> ^Layout {
	layout.align_items = align
	return layout
}

layout_wrap :: proc(layout: ^Layout, wrap: FlexWrap) -> ^Layout {
	layout.wrap = wrap
	return layout
}

layout_gap :: proc(layout: ^Layout, gap: int) -> ^Layout {
	layout.gap = gap
	return layout
}

layout_padding :: proc(layout: ^Layout, padding: int) -> ^Layout {
	layout.padding = Padding{padding, padding, padding, padding}
	return layout
}

layout_padding_horizontal :: proc(layout: ^Layout, padding: int) -> ^Layout {
	layout.padding.left = padding
	layout.padding.right = padding
	return layout
}

layout_padding_vertical :: proc(layout: ^Layout, padding: int) -> ^Layout {
	layout.padding.top = padding
	layout.padding.bottom = padding
	return layout
}

layout_margin :: proc(layout: ^Layout, margin: int) -> ^Layout {
	layout.margin = Margin{margin, margin, margin, margin}
	return layout
}

layout_margin_horizontal :: proc(layout: ^Layout, margin: int) -> ^Layout {
	layout.margin.left = margin
	layout.margin.right = margin
	return layout
}

layout_margin_vertical :: proc(layout: ^Layout, margin: int) -> ^Layout {
	layout.margin.top = margin
	layout.margin.bottom = margin
	return layout
}

layout_width :: proc(layout: ^Layout, width: int) -> ^Layout {
	layout.width = width
	return layout
}

layout_height :: proc(layout: ^Layout, height: int) -> ^Layout {
	layout.height = height
	return layout
}

layout_max_width :: proc(layout: ^Layout, max_width: int) -> ^Layout {
	layout.max_width = max_width
	return layout
}

layout_max_height :: proc(layout: ^Layout, max_height: int) -> ^Layout {
	layout.max_height = max_height
	return layout
}

// Text alignment utilities
center_text :: proc(text: string, width: int) -> string {
	text_width := visual_width(text)
	if text_width >= width {
		return text
	}

	padding := (width - text_width) / 2
	left_padding := strings.repeat(" ", padding)
	right_padding := strings.repeat(" ", width - text_width - padding)
	defer delete(left_padding)
	defer delete(right_padding)

	return fmt.aprintf("%s%s%s", left_padding, text, right_padding)
}

align_left :: proc(text: string, width: int) -> string {
	text_width := visual_width(text)
	if text_width >= width {
		return text
	}

	padding := strings.repeat(" ", width - text_width)
	defer delete(padding)

	return fmt.aprintf("%s%s", text, padding)
}

align_right :: proc(text: string, width: int) -> string {
	text_width := visual_width(text)
	if text_width >= width {
		return text
	}

	padding := strings.repeat(" ", width - text_width)
	defer delete(padding)

	return fmt.aprintf("%s%s", padding, text)
}

// Box model utilities
apply_padding :: proc(text: string, padding: Padding) -> string {
	if padding.top == 0 && padding.right == 0 && padding.bottom == 0 && padding.left == 0 {
		return text
	}

	lines := strings.split(text, "\n")
	defer delete(lines)

	result := strings.Builder{}
	defer strings.builder_destroy(&result)

	// Calculate maximum line width
	max_width := 0
	for line in lines {
		width := visual_width(line)
		if width > max_width {
			max_width = width
		}
	}

	// Add horizontal padding to max width
	content_width := max_width + padding.left + padding.right

	// Top padding
	for i in 0..<padding.top {
		spaces := strings.repeat(" ", content_width)
		defer delete(spaces)
		strings.write_string(&result, spaces)
		if i < padding.top - 1 {
			strings.write_string(&result, "\n")
		}
	}

	if padding.top > 0 && len(lines) > 0 {
		strings.write_string(&result, "\n")
	}

	// Content with left/right padding
	for line, i in lines {
		left_pad := strings.repeat(" ", padding.left)
		right_pad := strings.repeat(" ", padding.right)
		defer delete(left_pad)
		defer delete(right_pad)

		strings.write_string(&result, left_pad)
		strings.write_string(&result, line)
		strings.write_string(&result, right_pad)

		if i < len(lines) - 1 {
			strings.write_string(&result, "\n")
		}
	}

	// Bottom padding
	if padding.bottom > 0 && len(lines) > 0 {
		strings.write_string(&result, "\n")
	}

	for i in 0..<padding.bottom {
		spaces := strings.repeat(" ", content_width)
		defer delete(spaces)
		strings.write_string(&result, spaces)
		if i < padding.bottom - 1 {
			strings.write_string(&result, "\n")
		}
	}

	return strings.clone(strings.to_string(result))
}

apply_margin :: proc(text: string, margin: Margin) -> string {
	if margin.top == 0 && margin.right == 0 && margin.bottom == 0 && margin.left == 0 {
		return text
	}

	lines := strings.split(text, "\n")
	defer delete(lines)

	result := strings.Builder{}
	defer strings.builder_destroy(&result)

	// Top margin
	for i in 0..<margin.top {
		strings.write_string(&result, "\n")
	}

	// Content with left/right margin
	for line, i in lines {
		left_margin := strings.repeat(" ", margin.left)
		defer delete(left_margin)

		strings.write_string(&result, left_margin)
		strings.write_string(&result, line)

		if i < len(lines) - 1 {
			strings.write_string(&result, "\n")
		}
	}

	// Bottom margin
	for i in 0..<margin.bottom {
		strings.write_string(&result, "\n")
	}

	return strings.clone(strings.to_string(result))
}

// Terminal width detection (placeholder)
get_terminal_width :: proc() -> int {
	// Default to 80 columns if detection fails
	// In a real implementation, you'd use terminal APIs
	return 80
}

get_terminal_height :: proc() -> int {
	// Default to 24 rows if detection fails
	// In a real implementation, you'd use terminal APIs
	return 24
}

// Container utilities
create_container :: proc(content: string, width: int, padding: Padding = {}) -> string {
	padded_content := apply_padding(content, padding)
	defer delete(padded_content)

	lines := strings.split(padded_content, "\n")
	defer delete(lines)

	result := strings.Builder{}
	defer strings.builder_destroy(&result)

	for line, i in lines {
		formatted_line := align_left(line, width)
		defer delete(formatted_line)
		strings.write_string(&result, formatted_line)

		if i < len(lines) - 1 {
			strings.write_string(&result, "\n")
		}
	}

	return strings.clone(strings.to_string(result))
}