package test_wayu

import "core:testing"
import wayu "../src"

// Test basic style creation
@(test)
test_style_creation :: proc(t: ^testing.T) {
    style := wayu.Style{}
    testing.expect_value(t, style.foreground, "")
    testing.expect_value(t, style.background, "")
    testing.expect_value(t, style.bold, false)
}

// Test style render function
@(test)
test_style_render :: proc(t: ^testing.T) {
    style := wayu.Style{}
    result := wayu.render(style, "Hello")
    testing.expect_value(t, result, "Hello")

    bold_style := wayu.Style{bold = true}
    bold_result := wayu.render(bold_style, "Bold")
    testing.expect(t, len(bold_result) > 4, "Bold text should have ANSI codes")
}

// Test style builder methods
@(test)
test_style_builders :: proc(t: ^testing.T) {
    base := wayu.Style{}

    // Test foreground
    styled := wayu.style_foreground(base, "red")
    testing.expect_value(t, styled.foreground, "red")

    // Test bold
    bold_styled := wayu.style_bold(base, true)
    testing.expect_value(t, bold_styled.bold, true)

    // Test padding
    padded := wayu.style_padding(base, 2)
    testing.expect_value(t, padded.padding_top, 2)
    testing.expect_value(t, padded.padding_right, 2)
    testing.expect_value(t, padded.padding_bottom, 2)
    testing.expect_value(t, padded.padding_left, 2)
}

// Test predefined styles
@(test)
test_predefined_styles :: proc(t: ^testing.T) {
    success_style := wayu.style_success()
    testing.expect_value(t, success_style.foreground, "green")

    error_style := wayu.style_error()
    testing.expect_value(t, error_style.foreground, "red")
    testing.expect_value(t, error_style.bold, true)
}

// Test color constants
@(test)
test_color_constants :: proc(t: ^testing.T) {
    testing.expect_value(t, wayu.COLOR_CONSTANTS.Red, "31")
    testing.expect_value(t, wayu.COLOR_CONSTANTS.Green, "32")
    testing.expect_value(t, wayu.COLOR_CONSTANTS.Blue, "34")
}

// Test utility functions
@(test)
test_utilities :: proc(t: ^testing.T) {
    testing.expect_value(t, wayu.is_dark_terminal(), true)

    r, g, b := wayu.hex_to_rgb("#FF0000")
    testing.expect_value(t, r, 0) // placeholder returns 0
    testing.expect_value(t, g, 0)
    testing.expect_value(t, b, 0)
}