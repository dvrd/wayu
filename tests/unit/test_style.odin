package test_wayu

import "core:testing"
import wayu "../../src"

// ============================================================================
// Basic style tests
// ============================================================================

@(test)
test_style_creation :: proc(t: ^testing.T) {
	style := wayu.new_style()
	testing.expect_value(t, style.foreground, "")
	testing.expect_value(t, style.background, "")
	testing.expect_value(t, style.bold, false)
	testing.expect_value(t, style.italic, false)
	testing.expect_value(t, style.underline, false)
}

@(test)
test_style_render :: proc(t: ^testing.T) {
	style := wayu.new_style()
	result := wayu.render(style, "Hello")
	testing.expect(t, len(result) >= 5, "Result should contain at least the text")
	defer delete(result)

	bold_style := wayu.Style{bold = true}
	bold_result := wayu.render(bold_style, "Bold")
	testing.expect(t, len(bold_result) > 4, "Bold text should have ANSI codes")
	defer delete(bold_result)
}

@(test)
test_style_builders :: proc(t: ^testing.T) {
	base := wayu.new_style()

	fg_style := wayu.style_foreground(base, "red")
	testing.expect_value(t, fg_style.foreground, "red")

	bold_style := wayu.style_bold(base, true)
	testing.expect_value(t, bold_style.bold, true)

	// Builder chaining
	styled := wayu.style_foreground(base, "blue")
	styled = wayu.style_bold(styled, true)
	testing.expect_value(t, styled.foreground, "blue")
	testing.expect_value(t, styled.bold, true)
}

// ============================================================================
// Width / layout tests
// ============================================================================

@(test)
test_visible_width_plain :: proc(t: ^testing.T) {
	testing.expect_value(t, wayu.visible_width("Hello"), 5)
	testing.expect_value(t, wayu.visible_width("Test"), 4)
	testing.expect_value(t, wayu.visible_width(""), 0)
}

@(test)
test_visible_width_ansi :: proc(t: ^testing.T) {
	colored := "\x1b[31mRed\x1b[0m"
	testing.expect_value(t, wayu.visible_width(colored), 3)
}

@(test)
test_visible_width_emoji :: proc(t: ^testing.T) {
	emoji := "✓"
	width := wayu.visible_width(emoji)
	testing.expect(t, width > 0, "Emoji should have positive width")
}

@(test)
test_visual_width :: proc(t: ^testing.T) {
	testing.expect_value(t, wayu.visual_width("Hello"), 5)
	testing.expect(t, wayu.visual_width("✓") > 0, "Emoji should have positive width")
}

@(test)
test_calculate_content_width_explicit :: proc(t: ^testing.T) {
	style := wayu.Style{width = 50}
	lines := []string{"Hello", "World"}
	width := wayu.calculate_content_width(style, lines)
	testing.expect_value(t, width, 50)
}

@(test)
test_calculate_content_width_max :: proc(t: ^testing.T) {
	style := wayu.Style{max_width = 10}
	lines := []string{"This is a very long line"}
	width := wayu.calculate_content_width(style, lines)
	testing.expect_value(t, width, 10)
}

@(test)
test_calculate_content_width_auto :: proc(t: ^testing.T) {
	style := wayu.Style{}
	lines := []string{"Short", "Longer line"}
	width := wayu.calculate_content_width(style, lines)
	testing.expect_value(t, width, 11)
}

@(test)
test_align_text_left :: proc(t: ^testing.T) {
	result := wayu.align_text("Test", 10, .Left)
	testing.expect_value(t, len(result), 10)
	testing.expect(t, result[0:4] == "Test", "Text should be left-aligned")
	defer delete(result)
}

@(test)
test_align_text_right :: proc(t: ^testing.T) {
	result := wayu.align_text("Test", 10, .Right)
	testing.expect_value(t, len(result), 10)
	defer delete(result)
}

@(test)
test_align_text_center :: proc(t: ^testing.T) {
	result := wayu.align_text("Test", 10, .Center)
	testing.expect_value(t, len(result), 10)
	defer delete(result)
}

@(test)
test_align_text_overflow :: proc(t: ^testing.T) {
	long_text := "This is a very long text"
	result := wayu.align_text(long_text, 5, .Left)
	defer delete(result)
	result_width := wayu.visual_width(result)
	testing.expect(t, result_width <= 5, "Truncated text should fit within target width")
}

// ============================================================================
// Border character tests
// ============================================================================

@(test)
test_get_border_char_normal :: proc(t: ^testing.T) {
	testing.expect_value(t, wayu.get_border_char(.Normal, .Top), "─")
	testing.expect_value(t, wayu.get_border_char(.Normal, .Left), "│")
	testing.expect_value(t, wayu.get_border_char(.Normal, .TopLeft), "┌")
	testing.expect_value(t, wayu.get_border_char(.Normal, .TopRight), "┐")
}

@(test)
test_get_border_char_rounded :: proc(t: ^testing.T) {
	testing.expect_value(t, wayu.get_border_char(.Rounded, .TopLeft), "╭")
	testing.expect_value(t, wayu.get_border_char(.Rounded, .TopRight), "╮")
	testing.expect_value(t, wayu.get_border_char(.Rounded, .BottomLeft), "╰")
	testing.expect_value(t, wayu.get_border_char(.Rounded, .BottomRight), "╯")
}

@(test)
test_get_border_char_thick :: proc(t: ^testing.T) {
	testing.expect_value(t, wayu.get_border_char(.Thick, .Top), "━")
	testing.expect_value(t, wayu.get_border_char(.Thick, .Left), "┃")
}

@(test)
test_get_border_char_double :: proc(t: ^testing.T) {
	testing.expect_value(t, wayu.get_border_char(.Double, .Top), "═")
	testing.expect_value(t, wayu.get_border_char(.Double, .Left), "║")
}

// ============================================================================
// Unicode width tests
// ============================================================================

@(test)
test_get_rune_width :: proc(t: ^testing.T) {
	testing.expect_value(t, wayu.get_rune_width('a'), 1)
	testing.expect_value(t, wayu.get_rune_width(' '), 1)
	testing.expect(t, wayu.get_rune_width('\x00') == 0, "Control char should be zero width")
}

@(test)
test_is_wide_character :: proc(t: ^testing.T) {
	testing.expect_value(t, wayu.is_wide_character('a'), false)
	testing.expect_value(t, wayu.is_wide_character('✓'), false)  // explicit exclusion
}

// ============================================================================
// apply_text_only_style test
// ============================================================================

@(test)
test_apply_text_only_style :: proc(t: ^testing.T) {
	style := wayu.Style{bold = true, foreground = "red"}
	result := wayu.apply_text_only_style(style, "Test")
	defer delete(result)
	testing.expect(t, len(result) > 4, "Styled text should have ANSI codes")
}
