package wayu

import "core:fmt"
import "core:os"
import "core:strings"
import "core:slice"

// Complete style system for PRP-07
// Note: Style, Alignment, and BorderStyle types are defined in types.odin

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

// Align text within a given width
align_text :: proc(text: string, width: int, alignment: Alignment) -> string {
	text_width := visible_width(text)

	// If text is already wider than target, truncate or return as-is
	if text_width >= width {
		// TODO: Implement proper text truncation with ellipsis
		return text
	}

	padding_needed := width - text_width

	#partial switch alignment {
	case .Left:
		// Add padding on the right
		return fmt.aprintf("%s%s", text, strings.repeat(" ", padding_needed))

	case .Center:
		// Add padding on both sides
		left_pad := padding_needed / 2
		right_pad := padding_needed - left_pad
		return fmt.aprintf("%s%s%s",
			strings.repeat(" ", left_pad),
			text,
			strings.repeat(" ", right_pad))

	case .Right:
		// Add padding on the left
		return fmt.aprintf("%s%s", strings.repeat(" ", padding_needed), text)

	case:
		// Default to left alignment
		return fmt.aprintf("%s%s", text, strings.repeat(" ", padding_needed))
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

// Helper functions for creating predefined styles
style_success :: proc() -> Style {
	return Style{foreground = "green"}
}

style_error :: proc() -> Style {
	return Style{foreground = "red", bold = true}
}

style_warning :: proc() -> Style {
	return Style{foreground = "yellow"}
}

style_info :: proc() -> Style {
	return Style{foreground = "blue"}
}

// ============================================================================
// COLOR UTILITIES
// ============================================================================

// Convert hex color to RGB values
hex_to_rgb :: proc(hex: string) -> (r: int, g: int, b: int) {
	hex_clean := hex
	if strings.has_prefix(hex, "#") {
		hex_clean = hex[1:]
	}

	if len(hex_clean) != 6 {
		return 0, 0, 0
	}

	// Parse hex values
	r_val, ok1 := parse_hex_byte(hex_clean[0:2])
	g_val, ok2 := parse_hex_byte(hex_clean[2:4])
	b_val, ok3 := parse_hex_byte(hex_clean[4:6])

	if !ok1 || !ok2 || !ok3 {
		return 0, 0, 0
	}

	return r_val, g_val, b_val
}

// Parse a 2-character hex string to an int
parse_hex_byte :: proc(hex: string) -> (result: int, ok: bool) #optional_ok {
	if len(hex) != 2 {
		return 0, false
	}

	result = 0
	for i in 0..<2 {
		c := hex[i]
		val: int
		switch c {
		case '0'..='9': val = int(c - '0')
		case 'a'..='f': val = int(c - 'a' + 10)
		case 'A'..='F': val = int(c - 'A' + 10)
		case: return 0, false
		}
		result = result * 16 + val
	}

	return result, true
}

// Check if terminal has dark background (heuristic-based)
is_dark_terminal :: proc() -> bool {
	// Check COLORFGBG environment variable (common in terminals)
	// Format: "foreground;background" where higher numbers = lighter
	colorfgbg := os.get_env("COLORFGBG")
	defer delete(colorfgbg)

	if len(colorfgbg) > 0 {
		parts := strings.split(colorfgbg, ";")
		defer delete(parts)

		if len(parts) >= 2 {
			// Background is the second number
			// 0-7 are dark, 8-15 are light in ANSI colors
			// Most terminals with dark bg set this to 0 or 8
			// Light terminals usually set it to 15
			if parts[1] == "0" || parts[1] == "8" {
				return true
			}
			if parts[1] == "15" || parts[1] == "7" {
				return false
			}
		}
	}

	// Default assumption: most developers use dark terminals
	return true
}

// Style builder methods (minimal set for compilation)
style_foreground :: proc(s: Style, color: string) -> Style {
	result := s
	result.foreground = color
	return result
}

style_background :: proc(s: Style, color: string) -> Style {
	result := s
	result.background = color
	return result
}

style_bold :: proc(s: Style, enable: bool = true) -> Style {
	result := s
	result.bold = enable
	return result
}

style_italic :: proc(s: Style, enable: bool = true) -> Style {
	result := s
	result.italic = enable
	return result
}

style_underline :: proc(s: Style, enable: bool = true) -> Style {
	result := s
	result.underline = enable
	return result
}

style_strikethrough :: proc(s: Style, enable: bool = true) -> Style {
	result := s
	result.strikethrough = enable
	return result
}

style_padding :: proc(s: Style, i: int) -> Style {
	result := s
	result.padding_top = i
	result.padding_right = i
	result.padding_bottom = i
	result.padding_left = i
	return result
}

style_padding_top :: proc(s: Style, i: int) -> Style {
	result := s
	result.padding_top = i
	return result
}

style_padding_right :: proc(s: Style, i: int) -> Style {
	result := s
	result.padding_right = i
	return result
}

style_padding_bottom :: proc(s: Style, i: int) -> Style {
	result := s
	result.padding_bottom = i
	return result
}

style_padding_left :: proc(s: Style, i: int) -> Style {
	result := s
	result.padding_left = i
	return result
}

style_margin :: proc(s: Style, i: int) -> Style {
	result := s
	result.margin_top = i
	result.margin_right = i
	result.margin_bottom = i
	result.margin_left = i
	return result
}

style_margin_top :: proc(s: Style, i: int) -> Style {
	result := s
	result.margin_top = i
	return result
}

style_margin_right :: proc(s: Style, i: int) -> Style {
	result := s
	result.margin_right = i
	return result
}

style_margin_bottom :: proc(s: Style, i: int) -> Style {
	result := s
	result.margin_bottom = i
	return result
}

style_margin_left :: proc(s: Style, i: int) -> Style {
	result := s
	result.margin_left = i
	return result
}

style_width :: proc(s: Style, w: int) -> Style {
	result := s
	result.width = w
	return result
}

style_height :: proc(s: Style, h: int) -> Style {
	result := s
	result.height = h
	return result
}

style_max_width :: proc(s: Style, w: int) -> Style {
	result := s
	result.max_width = w
	return result
}

style_max_height :: proc(s: Style, h: int) -> Style {
	result := s
	result.max_height = h
	return result
}

style_border :: proc(s: Style, border_type: BorderStyle = .Normal) -> Style {
	result := s
	result.border_style = border_type
	// Enable all borders by default
	result.border_top = true
	result.border_right = true
	result.border_bottom = true
	result.border_left = true
	return result
}

style_border_top :: proc(s: Style, enable: bool = true) -> Style {
	result := s
	result.border_top = enable
	return result
}

style_border_right :: proc(s: Style, enable: bool = true) -> Style {
	result := s
	result.border_right = enable
	return result
}

style_border_bottom :: proc(s: Style, enable: bool = true) -> Style {
	result := s
	result.border_bottom = enable
	return result
}

style_border_left :: proc(s: Style, enable: bool = true) -> Style {
	result := s
	result.border_left = enable
	return result
}

style_border_foreground :: proc(s: Style, color: string) -> Style {
	result := s
	result.border_fg = color
	return result
}

style_border_background :: proc(s: Style, color: string) -> Style {
	result := s
	result.border_bg = color
	return result
}

style_align_horizontal :: proc(s: Style, a: Alignment) -> Style {
	result := s
	result.align_horizontal = a
	return result
}

style_align_vertical :: proc(s: Style, a: Alignment) -> Style {
	result := s
	result.align_vertical = a
	return result
}

style_foreground_rgb :: proc(s: Style, r: int, g: int, b: int) -> Style {
	result := s
	result.foreground = fmt.aprintf("%d;%d;%d", r, g, b)
	return result
}

style_background_rgb :: proc(s: Style, r: int, g: int, b: int) -> Style {
	result := s
	result.background = fmt.aprintf("%d;%d;%d", r, g, b)
	return result
}

style_foreground_hex :: proc(s: Style, hex: string) -> Style {
	r, g, b := hex_to_rgb(hex)
	return style_foreground_rgb(s, r, g, b)
}

style_background_hex :: proc(s: Style, hex: string) -> Style {
	r, g, b := hex_to_rgb(hex)
	return style_background_rgb(s, r, g, b)
}

style_foreground_adaptive :: proc(s: Style, light: string, dark: string) -> Style {
	result := s
	result.foreground = light
	result.foreground_dark = dark
	return result
}