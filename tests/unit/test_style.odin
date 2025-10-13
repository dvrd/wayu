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
	// Plain style - should return text as-is
	style := wayu.new_style()
	result := wayu.render(style, "Hello")
	testing.expect_value(t, result, "Hello")

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
	// Test dark terminal detection (always returns true as placeholder)
	is_dark := wayu.is_dark_terminal()
	testing.expect_value(t, is_dark, true)

	// Test hex to RGB conversion (placeholder returns 0,0,0)
	r, g, b := wayu.hex_to_rgb("#FF0000")
	testing.expect_value(t, r, 0)
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
