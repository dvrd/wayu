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
	foreground:       string,
	background:       string,
	bold:             bool,
	italic:           bool,
	underline:        bool,
	strikethrough:    bool,
	dim:              bool,
	blink:            bool,
	reverse:          bool,
	faint:            bool,
	// border_* bools grouped here with the other style bools so all 12 share
	// 8-byte slots instead of stranding 4 bytes of padding before border_fg.
	border_top:       bool,
	border_right:     bool,
	border_bottom:    bool,
	border_left:      bool,
	padding_top:      int,
	padding_right:    int,
	padding_bottom:   int,
	padding_left:     int,
	margin_top:       int,
	margin_right:     int,
	margin_bottom:    int,
	margin_left:      int,
	width:            int,
	height:           int,
	max_width:        int,
	max_height:       int,
	align_horizontal: Alignment,
	align_vertical:   Alignment,
	border_style:     BorderStyle,
	border_fg:        string,
	border_bg:        string,
	foreground_dark:  string,
	background_dark:  string,
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
	Red:     string,
	Green:   string,
	Yellow:  string,
	Blue:    string,
	Magenta: string,
	Cyan:    string,
	White:   string,
	Black:   string,
}

COLOR_CONSTANTS :: Color {
	Red     = "31",
	Green   = "32",
	Yellow  = "33",
	Blue    = "34",
	Magenta = "35",
	Cyan    = "36",
	White   = "37",
	Black   = "30",
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
	for _ in 0 ..< s.margin_top {
		strings.write_string(&builder, "\n")
	}

	// Calculate content width (considering width constraints)
	content_width := calculate_content_width(s, lines)

	// Render top border
	if s.border_top {
		render_style_border_line(&builder, s, .Top, content_width)
	}

	// Apply top padding
	for _ in 0 ..< s.padding_top {
		render_empty_line(&builder, s, content_width)
	}

	// Render content lines
	for line in lines {
		render_content_line(&builder, s, line, content_width)
	}

	// Apply bottom padding
	for _ in 0 ..< s.padding_bottom {
		render_empty_line(&builder, s, content_width)
	}

	// Render bottom border
	if s.border_bottom {
		render_style_border_line(&builder, s, .Bottom, content_width)
	}

	// Apply bottom margin
	for _ in 0 ..< s.margin_bottom {
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

// Get visible width of text (excluding ANSI codes).
// Alias of visual_width — kept so every width measurement in the style
// pipeline (align, truncate, content width) agrees on CJK/emoji widths.
visible_width :: proc(text: string) -> int {
	return visual_width(text)
}

// Render a border line (top or bottom) for styled content
render_style_border_line :: proc(
	builder: ^strings.Builder,
	s: Style,
	pos: BorderPosition,
	width: int,
) {
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
	for _ in 0 ..< total_width {
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
	defer delete(styled_content)
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

// Apply text styles (colors, bold, italic, etc.) to content.
// Returns an allocated string — caller must delete().
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

	// Clone: the builder's buffer is freed by the deferred builder_destroy.
	return strings.clone(strings.to_string(builder))
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
	// NO_COLOR / --no-color / non-TTY: styles keep their text, drop colors.
	if CURRENT_COLOR_PROFILE == .ASCII {
		return
	}
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
	case "black":
		code = is_foreground ? "30" : "40"
	case "red":
		code = is_foreground ? "31" : "41"
	case "green":
		code = is_foreground ? "32" : "42"
	case "yellow":
		code = is_foreground ? "33" : "43"
	case "blue":
		code = is_foreground ? "34" : "44"
	case "magenta":
		code = is_foreground ? "35" : "45"
	case "cyan":
		code = is_foreground ? "36" : "46"
	case "white":
		code = is_foreground ? "37" : "47"
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
		case .Top, .Bottom:
			return "─"
		case .Left, .Right:
			return "│"
		case .TopLeft:
			return "┌"
		case .TopRight:
			return "┐"
		case .BottomLeft:
			return "└"
		case .BottomRight:
			return "┘"
		}

	case .Rounded:
		switch pos {
		case .Top, .Bottom:
			return "─"
		case .Left, .Right:
			return "│"
		case .TopLeft:
			return "╭"
		case .TopRight:
			return "╮"
		case .BottomLeft:
			return "╰"
		case .BottomRight:
			return "╯"
		}

	case .Thick:
		switch pos {
		case .Top, .Bottom:
			return "━"
		case .Left, .Right:
			return "┃"
		case .TopLeft:
			return "┏"
		case .TopRight:
			return "┓"
		case .BottomLeft:
			return "┗"
		case .BottomRight:
			return "┛"
		}

	case .Double:
		switch pos {
		case .Top, .Bottom:
			return "═"
		case .Left, .Right:
			return "║"
		case .TopLeft:
			return "╔"
		case .TopRight:
			return "╗"
		case .BottomLeft:
			return "╚"
		case .BottomRight:
			return "╝"
		}
	}

	return " "
}

// Truncate text to fit within a given visual width, adding ellipsis if needed.
// ANSI escape sequences are copied through without counting toward width;
// rune widths come from get_rune_width (CJK/emoji = 2 columns), matching
// visual_width. Returns `text` itself when it fits, otherwise an allocated
// string.
truncate_to_width :: proc(text: string, max_width: int) -> string {
	if max_width <= 0 {
		return ""
	}

	// No truncation needed
	if visual_width(text) <= max_width {
		return text
	}

	// Need at least 4 columns for truncation to make sense (1 char + "...")
	if max_width < 4 {
		return strings.repeat(".", max_width)
	}

	result := strings.builder_make()
	defer strings.builder_destroy(&result)

	target_width := max_width - 3 // Reserve space for "..."
	current_width := 0
	i := 0

	for i < len(text) {
		// Copy CSI sequences (ESC [ ... final) verbatim, zero width.
		if text[i] == 0x1B && i + 1 < len(text) && text[i + 1] == '[' {
			j := i + 2
			for j < len(text) && !(text[j] >= 0x40 && text[j] <= 0x7E) {
				j += 1
			}
			if j < len(text) do j += 1
			strings.write_string(&result, text[i:j])
			i = j
			continue
		}

		r, size := utf8.decode_rune_in_string(text[i:])
		if size <= 0 do size = 1
		w := get_rune_width(r)
		if current_width + w > target_width {
			break
		}
		strings.write_string(&result, text[i:i + size])
		current_width += w
		i += size
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
		return fmt.aprintf("%s%s%s", left_pad_str, text, right_pad_str)

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
	for _ in 0 ..< count {
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
				for i < len(raw) &&
				    raw[i] != 'm' &&
				    raw[i] != 'K' &&
				    raw[i] != 'J' &&
				    raw[i] != 'H' {
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
			if size == 0 {
				size = 1
			} // skip invalid byte
			visible_chars += get_rune_width(r)
			i += size
		}
	}

	return visible_chars
}


// get_rune_width returns the number of terminal columns a single rune takes,
// using the same Unicode data as terminals (wcwidth: EastAsianWidth +
// Emoji_Presentation, see src/rune_width_table.odin):
//   0 — C0/C1 controls, combining marks, variation selectors (VS16), ZWJ
//       and other format characters;
//   2 — East Asian Wide/Fullwidth and emoji with default emoji presentation
//       (🚀 ✨ ✅ — not text-default symbols like ➜ ✔ ★ ❤ ⚠, which are 1);
//   1 — everything else.
// Grapheme clusters are not merged: an emoji ZWJ sequence counts (and the
// TUI renders it) as its individual emoji, so every terminal agrees.
get_rune_width :: proc(r: rune) -> int {
	if r < 0x20 || (r >= 0x7F && r < 0xA0) do return 0
	if r < 0x300 do return 1 // fast path: ASCII, Latin-1, Latin Extended
	if rune_in_ranges(r, RUNE_WIDTH_ZERO[:]) do return 0
	if rune_in_ranges(r, RUNE_WIDTH_WIDE[:]) do return 2
	return 1
}

// is_wide_character reports whether a rune occupies two terminal columns.
is_wide_character :: proc(r: rune) -> bool {
	return get_rune_width(r) == 2
}

// True for zero-width runes that only change how the neighbouring glyphs are
// presented or joined (variation selectors, ZWJ/ZWNJ, bidi marks, word
// joiners, BOM, tag characters). The TUI drops these instead of attaching
// them to a cell: a VS16 or ZWJ sequence widens the glyph in some terminals
// and not in others, so emitting one would desync the cell grid.
is_presentation_selector :: proc(r: rune) -> bool {
	switch r {
	case 0x200B ..=
	     0x200F,
	     0x2028 ..=
	     0x202E,
	     0x2060 ..=
	     0x206F,
	     0xFE00 ..=
	     0xFE0F,
	     0xFEFF,
	     0xE0000 ..=
	     0xE007F,
	     0xE0100 ..=
	     0xE01EF:
		return true
	}
	return false
}

// Binary search over sorted, non-overlapping inclusive [lo, hi] ranges.
@(private = "file")
rune_in_ranges :: proc(r: rune, ranges: [][2]rune) -> bool {
	lo, hi := 0, len(ranges) - 1
	if hi < 0 || r < ranges[0][0] || r > ranges[hi][1] do return false
	for lo <= hi {
		mid := (lo + hi) / 2
		switch {
		case r < ranges[mid][0]:
			hi = mid - 1
		case r > ranges[mid][1]:
			lo = mid + 1
		case:
			return true
		}
	}
	return false
}
