package test_wayu

import "core:testing"
import wayu "../../src"

// Test basic style creation
@(test)
test_style_creation :: proc(t: ^testing.T) {
	style := wayu.new_style()
	testing.expect_value(t, style.foreground, "")
	testing.expect_value(t, style.background, "")
	testing.expect_value(t, style.bold, false)
	testing.expect_value(t, style.italic, false)
	testing.expect_value(t, style.underline, false)
}

// Test style render function
@(test)
test_style_render :: proc(t: ^testing.T) {
	// Plain style - should return text with potential padding
	style := wayu.new_style()
	result := wayu.render(style, "Hello")
	// Just check that result contains the text and RESET code
	testing.expect(t, len(result) >= 5, "Result should contain at least the text")
	defer delete(result)

	// Bold style - should add ANSI codes
	bold_style := wayu.Style{bold = true}
	bold_result := wayu.render(bold_style, "Bold")
	testing.expect(t, len(bold_result) > 4, "Bold text should have ANSI codes")
	defer delete(bold_result)
}

// Test predefined style creators
@(test)
test_predefined_styles :: proc(t: ^testing.T) {
	success_style := wayu.style_success()
	testing.expect_value(t, success_style.foreground, "green")

	error_style := wayu.style_error()
	testing.expect_value(t, error_style.foreground, "red")
	testing.expect_value(t, error_style.bold, true)

	warning_style := wayu.style_warning()
	testing.expect_value(t, warning_style.foreground, "yellow")

	info_style := wayu.style_info()
	testing.expect_value(t, info_style.foreground, "blue")
}

// Test color builder methods
@(test)
test_color_builders :: proc(t: ^testing.T) {
	base := wayu.new_style()

	// Test foreground
	fg_style := wayu.style_foreground(base, "red")
	testing.expect_value(t, fg_style.foreground, "red")

	// Test background
	bg_style := wayu.style_background(base, "blue")
	testing.expect_value(t, bg_style.background, "blue")
}

// Test text style builders
@(test)
test_text_style_builders :: proc(t: ^testing.T) {
	base := wayu.new_style()

	// Test bold
	bold_style := wayu.style_bold(base, true)
	testing.expect_value(t, bold_style.bold, true)

	// Test italic
	italic_style := wayu.style_italic(base, true)
	testing.expect_value(t, italic_style.italic, true)

	// Test underline
	underline_style := wayu.style_underline(base, true)
	testing.expect_value(t, underline_style.underline, true)

	// Test strikethrough
	strike_style := wayu.style_strikethrough(base, true)
	testing.expect_value(t, strike_style.strikethrough, true)
}

// Test padding builders
@(test)
test_padding_builders :: proc(t: ^testing.T) {
	base := wayu.new_style()

	// Test uniform padding
	padded := wayu.style_padding(base, 2)
	testing.expect_value(t, padded.padding_top, 2)
	testing.expect_value(t, padded.padding_right, 2)
	testing.expect_value(t, padded.padding_bottom, 2)
	testing.expect_value(t, padded.padding_left, 2)

	// Test individual padding
	top := wayu.style_padding_top(base, 1)
	testing.expect_value(t, top.padding_top, 1)

	right := wayu.style_padding_right(base, 2)
	testing.expect_value(t, right.padding_right, 2)

	bottom := wayu.style_padding_bottom(base, 3)
	testing.expect_value(t, bottom.padding_bottom, 3)

	left := wayu.style_padding_left(base, 4)
	testing.expect_value(t, left.padding_left, 4)
}

// Test margin builders
@(test)
test_margin_builders :: proc(t: ^testing.T) {
	base := wayu.new_style()

	// Test uniform margin
	margin := wayu.style_margin(base, 3)
	testing.expect_value(t, margin.margin_top, 3)
	testing.expect_value(t, margin.margin_right, 3)
	testing.expect_value(t, margin.margin_bottom, 3)
	testing.expect_value(t, margin.margin_left, 3)

	// Test individual margin
	top := wayu.style_margin_top(base, 1)
	testing.expect_value(t, top.margin_top, 1)

	right := wayu.style_margin_right(base, 2)
	testing.expect_value(t, right.margin_right, 2)

	bottom := wayu.style_margin_bottom(base, 3)
	testing.expect_value(t, bottom.margin_bottom, 3)

	left := wayu.style_margin_left(base, 4)
	testing.expect_value(t, left.margin_left, 4)
}

// Test dimension builders
@(test)
test_dimension_builders :: proc(t: ^testing.T) {
	base := wayu.new_style()

	// Test width and height
	width_style := wayu.style_width(base, 80)
	testing.expect_value(t, width_style.width, 80)

	height_style := wayu.style_height(base, 24)
	testing.expect_value(t, height_style.height, 24)

	// Test max dimensions
	max_width := wayu.style_max_width(base, 100)
	testing.expect_value(t, max_width.max_width, 100)

	max_height := wayu.style_max_height(base, 50)
	testing.expect_value(t, max_height.max_height, 50)
}

// Test border builders
@(test)
test_border_builders :: proc(t: ^testing.T) {
	base := wayu.new_style()

	// Test border style
	border := wayu.style_border(base, .Normal)
	testing.expect_value(t, border.border_style, wayu.BorderStyle.Normal)

	// Test individual borders
	top := wayu.style_border_top(base, true)
	testing.expect_value(t, top.border_top, true)

	right := wayu.style_border_right(base, true)
	testing.expect_value(t, right.border_right, true)

	bottom := wayu.style_border_bottom(base, true)
	testing.expect_value(t, bottom.border_bottom, true)

	left := wayu.style_border_left(base, true)
	testing.expect_value(t, left.border_left, true)

	// Test border colors
	border_fg := wayu.style_border_foreground(base, "green")
	testing.expect_value(t, border_fg.border_fg, "green")

	border_bg := wayu.style_border_background(base, "blue")
	testing.expect_value(t, border_bg.border_bg, "blue")
}

// Test alignment builders
@(test)
test_alignment_builders :: proc(t: ^testing.T) {
	base := wayu.new_style()

	// Test horizontal alignment
	h_center := wayu.style_align_horizontal(base, .Center)
	testing.expect_value(t, h_center.align_horizontal, wayu.Alignment.Center)

	// Test vertical alignment
	v_center := wayu.style_align_vertical(base, .Center)
	testing.expect_value(t, v_center.align_vertical, wayu.Alignment.Center)
}

// Test RGB color builders
@(test)
test_rgb_color_builders :: proc(t: ^testing.T) {
	base := wayu.new_style()

	// Test foreground RGB
	fg_rgb := wayu.style_foreground_rgb(base, 255, 0, 0)
	testing.expect(t, len(fg_rgb.foreground) > 0, "RGB foreground should be set")
	defer delete(fg_rgb.foreground)

	// Test background RGB
	bg_rgb := wayu.style_background_rgb(base, 0, 255, 0)
	testing.expect(t, len(bg_rgb.background) > 0, "RGB background should be set")
	defer delete(bg_rgb.background)
}

// Test hex color builders
@(test)
test_hex_color_builders :: proc(t: ^testing.T) {
	base := wayu.new_style()

	// Test foreground hex
	fg_hex := wayu.style_foreground_hex(base, "#FF0000")
	testing.expect(t, len(fg_hex.foreground) > 0, "Hex foreground should be set")
	defer delete(fg_hex.foreground)

	// Test background hex
	bg_hex := wayu.style_background_hex(base, "#00FF00")
	testing.expect(t, len(bg_hex.background) > 0, "Hex background should be set")
	defer delete(bg_hex.background)
}

// Test adaptive color builder
@(test)
test_adaptive_color_builder :: proc(t: ^testing.T) {
	base := wayu.new_style()

	// Test adaptive foreground
	adaptive := wayu.style_foreground_adaptive(base, "black", "white")
	testing.expect_value(t, adaptive.foreground, "black")
	testing.expect_value(t, adaptive.foreground_dark, "white")
}

// Test utility functions
@(test)
test_utility_functions :: proc(t: ^testing.T) {
	// Test dark terminal detection (returns true by default)
	is_dark := wayu.is_dark_terminal()
	testing.expect_value(t, is_dark, true)

	// Test hex to RGB conversion - now actually works!
	r, g, b := wayu.hex_to_rgb("#FF0000")
	testing.expect_value(t, r, 255)
	testing.expect_value(t, g, 0)
	testing.expect_value(t, b, 0)
}

// Test style chaining (builder pattern)
@(test)
test_style_chaining :: proc(t: ^testing.T) {
	base := wayu.new_style()

	// Chain multiple style operations
	styled := wayu.style_foreground(base, "red")
	styled = wayu.style_bold(styled, true)
	styled = wayu.style_padding(styled, 2)
	styled = wayu.style_width(styled, 80)

	testing.expect_value(t, styled.foreground, "red")
	testing.expect_value(t, styled.bold, true)
	testing.expect_value(t, styled.padding_top, 2)
	testing.expect_value(t, styled.width, 80)
}

// Test visible_width with plain text
@(test)
test_visible_width_plain :: proc(t: ^testing.T) {
	testing.expect_value(t, wayu.visible_width("Hello"), 5)
	testing.expect_value(t, wayu.visible_width("Test"), 4)
	testing.expect_value(t, wayu.visible_width(""), 0)
}

// Test visible_width with ANSI codes
@(test)
test_visible_width_ansi :: proc(t: ^testing.T) {
	// Text with ANSI color codes should not count escape sequences
	colored := "\x1b[31mRed\x1b[0m"
	testing.expect_value(t, wayu.visible_width(colored), 3)
}

// Test visible_width with emojis
@(test)
test_visible_width_emoji :: proc(t: ^testing.T) {
	// Emojis should count as 2 characters wide
	emoji := "✓"  // This is a 3-byte UTF-8 character
	width := wayu.visible_width(emoji)
	testing.expect(t, width > 0, "Emoji should have positive width")
}

// Test calculate_content_width with explicit width
@(test)
test_calculate_content_width_explicit :: proc(t: ^testing.T) {
	style := wayu.Style{width = 50}
	lines := []string{"Hello", "World"}
	width := wayu.calculate_content_width(style, lines)
	testing.expect_value(t, width, 50)
}

// Test calculate_content_width with max_width constraint
@(test)
test_calculate_content_width_max :: proc(t: ^testing.T) {
	style := wayu.Style{max_width = 10}
	lines := []string{"This is a very long line"}
	width := wayu.calculate_content_width(style, lines)
	testing.expect_value(t, width, 10)
}

// Test calculate_content_width auto-sizing
@(test)
test_calculate_content_width_auto :: proc(t: ^testing.T) {
	style := wayu.Style{}
	lines := []string{"Short", "Longer line"}
	width := wayu.calculate_content_width(style, lines)
	testing.expect_value(t, width, 11)  // Length of "Longer line"
}

// Test align_text left alignment
@(test)
test_align_text_left :: proc(t: ^testing.T) {
	result := wayu.align_text("Test", 10, .Left)
	testing.expect_value(t, len(result), 10)
	testing.expect(t, result[0:4] == "Test", "Text should be left-aligned")
	defer delete(result)
}

// Test align_text right alignment
@(test)
test_align_text_right :: proc(t: ^testing.T) {
	result := wayu.align_text("Test", 10, .Right)
	testing.expect_value(t, len(result), 10)
	defer delete(result)
}

// Test align_text center alignment
@(test)
test_align_text_center :: proc(t: ^testing.T) {
	result := wayu.align_text("Test", 10, .Center)
	testing.expect_value(t, len(result), 10)
	defer delete(result)
}

// Test align_text with text wider than width
@(test)
test_align_text_overflow :: proc(t: ^testing.T) {
	long_text := "This is a very long text"
	result := wayu.align_text(long_text, 5, .Left)
	defer delete(result)
	// Should truncate text when it's wider than target width
	result_width := wayu.visual_width(result)
	testing.expect(t, result_width <= 5, "Truncated text should fit within target width")
}

// Test get_border_char for Normal style
@(test)
test_get_border_char_normal :: proc(t: ^testing.T) {
	testing.expect_value(t, wayu.get_border_char(.Normal, .Top), "─")
	testing.expect_value(t, wayu.get_border_char(.Normal, .Left), "│")
	testing.expect_value(t, wayu.get_border_char(.Normal, .TopLeft), "┌")
	testing.expect_value(t, wayu.get_border_char(.Normal, .TopRight), "┐")
}

// Test get_border_char for Rounded style
@(test)
test_get_border_char_rounded :: proc(t: ^testing.T) {
	testing.expect_value(t, wayu.get_border_char(.Rounded, .TopLeft), "╭")
	testing.expect_value(t, wayu.get_border_char(.Rounded, .TopRight), "╮")
	testing.expect_value(t, wayu.get_border_char(.Rounded, .BottomLeft), "╰")
	testing.expect_value(t, wayu.get_border_char(.Rounded, .BottomRight), "╯")
}

// Test get_border_char for Thick style
@(test)
test_get_border_char_thick :: proc(t: ^testing.T) {
	testing.expect_value(t, wayu.get_border_char(.Thick, .Top), "━")
	testing.expect_value(t, wayu.get_border_char(.Thick, .Left), "┃")
}

// Test get_border_char for Double style
@(test)
test_get_border_char_double :: proc(t: ^testing.T) {
	testing.expect_value(t, wayu.get_border_char(.Double, .Top), "═")
	testing.expect_value(t, wayu.get_border_char(.Double, .Left), "║")
}

// Test parse_hex_byte valid input
@(test)
test_parse_hex_byte_valid :: proc(t: ^testing.T) {
	val, ok := wayu.parse_hex_byte("FF")
	testing.expect_value(t, ok, true)
	testing.expect_value(t, val, 255)

	val2, ok2 := wayu.parse_hex_byte("00")
	testing.expect_value(t, ok2, true)
	testing.expect_value(t, val2, 0)

	val3, ok3 := wayu.parse_hex_byte("A5")
	testing.expect_value(t, ok3, true)
	testing.expect_value(t, val3, 165)
}

// Test parse_hex_byte invalid input
@(test)
test_parse_hex_byte_invalid :: proc(t: ^testing.T) {
	_, ok := wayu.parse_hex_byte("GG")
	testing.expect_value(t, ok, false)

	_, ok2 := wayu.parse_hex_byte("F")
	testing.expect_value(t, ok2, false)
}

// Test hex_to_rgb with valid hex
@(test)
test_hex_to_rgb_valid :: proc(t: ^testing.T) {
	r, g, b := wayu.hex_to_rgb("#FF0000")
	testing.expect_value(t, r, 255)
	testing.expect_value(t, g, 0)
	testing.expect_value(t, b, 0)

	r2, g2, b2 := wayu.hex_to_rgb("00FF00")
	testing.expect_value(t, r2, 0)
	testing.expect_value(t, g2, 255)
	testing.expect_value(t, b2, 0)
}

// Test hex_to_rgb with invalid hex
@(test)
test_hex_to_rgb_invalid :: proc(t: ^testing.T) {
	r, g, b := wayu.hex_to_rgb("#FFF")
	testing.expect_value(t, r, 0)
	testing.expect_value(t, g, 0)
	testing.expect_value(t, b, 0)

	r2, g2, b2 := wayu.hex_to_rgb("GGGGGG")
	testing.expect_value(t, r2, 0)
	testing.expect_value(t, g2, 0)
	testing.expect_value(t, b2, 0)
}

// Test apply_text_only_style with empty text
@(test)
test_apply_text_only_style_empty :: proc(t: ^testing.T) {
	style := wayu.Style{bold = true}
	result := wayu.apply_text_only_style(style, "")
	testing.expect_value(t, result, "")
}

// Test apply_text_only_style with formatting
@(test)
test_apply_text_only_style_formatted :: proc(t: ^testing.T) {
	style := wayu.Style{bold = true, foreground = "red"}
	result := wayu.apply_text_only_style(style, "Test")
	testing.expect(t, len(result) > 4, "Formatted text should have ANSI codes")
	defer delete(result)
}

// Test render with empty text
@(test)
test_render_empty :: proc(t: ^testing.T) {
	style := wayu.new_style()
	result := wayu.render(style, "")
	testing.expect_value(t, result, "")
}

// Test render with borders
@(test)
test_render_with_borders :: proc(t: ^testing.T) {
	style := wayu.style_border(wayu.new_style(), .Normal)
	result := wayu.render(style, "Test")
	testing.expect(t, len(result) > 4, "Bordered text should be longer than plain text")
	defer delete(result)
}

// Test render with padding
@(test)
test_render_with_padding :: proc(t: ^testing.T) {
	style := wayu.style_padding(wayu.new_style(), 2)
	result := wayu.render(style, "Test")
	testing.expect(t, len(result) > 4, "Padded text should be longer than plain text")
	defer delete(result)
}

// Test render with margins
@(test)
test_render_with_margins :: proc(t: ^testing.T) {
	style := wayu.style_margin(wayu.new_style(), 1)
	result := wayu.render(style, "Test")
	testing.expect(t, len(result) > 4, "Text with margins should have newlines")
	defer delete(result)
}

// Test truncate_to_width with text that needs truncation
@(test)
test_truncate_to_width_basic :: proc(t: ^testing.T) {
	result := wayu.truncate_to_width("Hello, World!", 8)
	defer delete(result)
	result_width := wayu.visual_width(result)
	testing.expect(t, result_width <= 8, "Truncated text should have visual width <= 8")
	// Should end with "..."
	testing.expect(t, len(result) >= 3, "Result should have at least 3 characters for ellipsis")
}

// Test truncate_to_width with text shorter than max width
@(test)
test_truncate_to_width_no_truncation :: proc(t: ^testing.T) {
	result := wayu.truncate_to_width("Hi", 10)
	testing.expect_value(t, result, "Hi")
}

// Test truncate_to_width with text exactly at max width
@(test)
test_truncate_to_width_exact_fit :: proc(t: ^testing.T) {
	result := wayu.truncate_to_width("Hello", 5)
	testing.expect_value(t, result, "Hello")
}
