package test_wayu

import wayu "../../src"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"

@(test)
test_stylize_function :: proc(t: ^testing.T) {
	// Test basic color styling
	result := wayu.stylize("hello", wayu.RED)
	expected := fmt.aprintf("%s%s%s", wayu.RED, "hello", wayu.RESET)
	defer delete(expected)
	testing.expect_value(t, result, expected)
	delete(result)
}

@(test)
test_stylize_with_bold :: proc(t: ^testing.T) {
	// Test color with bold styling - note: stylize puts style before color
	result := wayu.stylize("hello", wayu.BLUE, wayu.BOLD)
	expected := fmt.aprintf("%s%s%s%s", wayu.BOLD, wayu.BLUE, "hello", wayu.RESET)
	defer delete(expected)
	testing.expect_value(t, result, expected)
	delete(result)
}

@(test)
test_color_constants_exist :: proc(t: ^testing.T) {
	// Test that color constants are defined correctly
	testing.expect(t, len(wayu.RESET) > 0, "RESET should be defined")
	testing.expect(t, len(wayu.RED) > 0, "RED should be defined")
	testing.expect(t, len(wayu.GREEN) > 0, "GREEN should be defined")
	testing.expect(t, len(wayu.BLUE) > 0, "BLUE should be defined")
	testing.expect(t, len(wayu.BOLD) > 0, "BOLD should be defined")
}

@(test)
test_emoji_constants :: proc(t: ^testing.T) {
	// Test that emoji constants are defined
	testing.expect(t, len(wayu.EMOJI_SUCCESS) > 0, "EMOJI_SUCCESS should be defined")
	testing.expect(t, len(wayu.EMOJI_ERROR) > 0, "EMOJI_ERROR should be defined")
	testing.expect(t, len(wayu.EMOJI_PATH) > 0, "EMOJI_PATH should be defined")
	testing.expect(t, len(wayu.EMOJI_CONSTANT) > 0, "EMOJI_CONSTANT should be defined")
}

@(test)
test_print_success :: proc(t: ^testing.T) {
	// Test that print_success doesn't crash (it prints to stdout)
	wayu.print_success("test message")
	wayu.print_success("test with args: %s", "value")
	testing.expect(t, true, "print_success should not crash")
}

@(test)
test_print_error :: proc(t: ^testing.T) {
	// Test that print_error doesn't crash
	wayu.print_error("error message")
	wayu.print_error("error with args: %d", 42)
	testing.expect(t, true, "print_error should not crash")
}

@(test)
test_print_warning :: proc(t: ^testing.T) {
	// Test that print_warning doesn't crash
	wayu.print_warning("warning message")
	testing.expect(t, true, "print_warning should not crash")
}

@(test)
test_print_info :: proc(t: ^testing.T) {
	// Test that print_info doesn't crash
	wayu.print_info("info message")
	testing.expect(t, true, "print_info should not crash")
}

@(test)
test_print_header :: proc(t: ^testing.T) {
	// Test that print_header doesn't crash
	wayu.print_header("Header", wayu.EMOJI_ROCKET)
	wayu.print_header("Header with default emoji")
	testing.expect(t, true, "print_header should not crash")
}

@(test)
test_print_section :: proc(t: ^testing.T) {
	// Test that print_section doesn't crash
	wayu.print_section("Section", wayu.EMOJI_INFO)
	testing.expect(t, true, "print_section should not crash")
}

@(test)
test_print_item :: proc(t: ^testing.T) {
	// Test that print_item doesn't crash
	wayu.print_item("", "name", "value", wayu.EMOJI_FILE)
	wayu.print_item("", "name only")
	testing.expect(t, true, "print_item should not crash")
}

@(test)
test_print_prompt :: proc(t: ^testing.T) {
	// Test that print_prompt doesn't crash
	wayu.print_prompt("Enter value")
	testing.expect(t, true, "print_prompt should not crash")
}

@(test)
test_detect_color_profile :: proc(t: ^testing.T) {
	// Test color profile detection
	profile := wayu.detect_color_profile()
	testing.expect(
		t,
		profile >= wayu.ColorProfile.ASCII && profile <= wayu.ColorProfile.TRUECOLOR,
		"Should return valid color profile",
	)
}

@(test)
test_init_colors :: proc(t: ^testing.T) {
	// Test color initialization
	wayu.init_colors()
	profile := wayu.get_color_profile()
	testing.expect(
		t,
		profile >= wayu.ColorProfile.ASCII && profile <= wayu.ColorProfile.TRUECOLOR,
		"After init, should have valid color profile",
	)
}

@(test)
test_adaptive_color :: proc(t: ^testing.T) {
	// Test adaptive color function
	result := wayu.adaptive_color(wayu.VIBRANT_PRIMARY, wayu.ANSI256_PRIMARY, wayu.BRIGHT_CYAN)
	testing.expect(
		t,
		len(result) > 0 || wayu.CURRENT_COLOR_PROFILE == .ASCII,
		"Should return color code or empty for ASCII",
	)
}

@(test)
test_get_primary :: proc(t: ^testing.T) {
	// Test primary color getter
	color := wayu.get_primary()
	testing.expect(
		t,
		len(color) > 0 || wayu.CURRENT_COLOR_PROFILE == .ASCII,
		"Should return primary color or empty for ASCII",
	)
}

@(test)
test_get_secondary :: proc(t: ^testing.T) {
	// Test secondary color getter
	color := wayu.get_secondary()
	testing.expect(
		t,
		len(color) > 0 || wayu.CURRENT_COLOR_PROFILE == .ASCII,
		"Should return secondary color or empty for ASCII",
	)
}

@(test)
test_get_accent :: proc(t: ^testing.T) {
	// Test accent color getter
	color := wayu.get_accent()
	testing.expect(
		t,
		len(color) > 0 || wayu.CURRENT_COLOR_PROFILE == .ASCII,
		"Should return accent color or empty for ASCII",
	)
}

@(test)
test_get_success :: proc(t: ^testing.T) {
	// Test success color getter
	color := wayu.get_success()
	testing.expect(
		t,
		len(color) > 0 || wayu.CURRENT_COLOR_PROFILE == .ASCII,
		"Should return success color or empty for ASCII",
	)
}

@(test)
test_get_error :: proc(t: ^testing.T) {
	// Test error color getter
	color := wayu.get_error()
	testing.expect(
		t,
		len(color) > 0 || wayu.CURRENT_COLOR_PROFILE == .ASCII,
		"Should return error color or empty for ASCII",
	)
}

@(test)
test_get_warning :: proc(t: ^testing.T) {
	// Test warning color getter
	color := wayu.get_warning()
	testing.expect(
		t,
		len(color) > 0 || wayu.CURRENT_COLOR_PROFILE == .ASCII,
		"Should return warning color or empty for ASCII",
	)
}

@(test)
test_get_info :: proc(t: ^testing.T) {
	// Test info color getter
	color := wayu.get_info()
	testing.expect(
		t,
		len(color) > 0 || wayu.CURRENT_COLOR_PROFILE == .ASCII,
		"Should return info color or empty for ASCII",
	)
}

@(test)
test_get_muted :: proc(t: ^testing.T) {
	// Test muted color getter
	color := wayu.get_muted()
	testing.expect(
		t,
		len(color) > 0 || wayu.CURRENT_COLOR_PROFILE == .ASCII,
		"Should return muted color or empty for ASCII",
	)
}

@(test)
test_term_safe_clean_passthrough :: proc(t: ^testing.T) {
	// Clean text (incl. multi-byte UTF-8 and a backslash) comes back as is,
	// without a copy.
	s := "plain [x] \\ é ✓ 日本"
	out := wayu.term_safe(s)
	testing.expect_value(t, out, s)
	testing.expect(t, raw_data(out) == raw_data(s), "clean input must not be copied")
	testing.expect_value(t, wayu.term_safe(""), "")
}

@(test)
test_term_safe_escapes_controls :: proc(t: ^testing.T) {
	// OSC title + clear screen: the ESC/BEL bytes become visible text.
	testing.expect_value(t, wayu.term_safe("a\x1b]0;pwned\x07b"), "a\\x1B]0;pwned\\x07b")
	testing.expect_value(t, wayu.term_safe("\x1b[2J"), "\\x1B[2J")
	// Tab and newline get their short escapes; other C0 and DEL are \xHH.
	testing.expect_value(t, wayu.term_safe("\x00\t\n\r\x7f"), "\\x00\\t\\n\\x0D\\x7F")
	// C1 controls (8-bit CSI / OSC as runes) are \u00HH.
	testing.expect_value(t, wayu.term_safe("c1\u009b31m\u009d"), "c1\\u009B31m\\u009D")
	// U+00A0 (just past C1) is printable and stays.
	testing.expect_value(t, wayu.term_safe("a b"), "a b")
}

@(test)
test_term_safe_invalid_utf8 :: proc(t: ^testing.T) {
	// Lone continuation / truncated sequences / a raw 8-bit CSI byte are
	// shown as \xHH; valid runes around them survive.
	testing.expect_value(t, wayu.term_safe("a\x9b[2Jb"), "a\\x9B[2Jb")
	testing.expect_value(t, wayu.term_safe("é\xc3"), "é\\xC3")
	testing.expect_value(t, wayu.term_safe("\xff\xfe✓"), "\\xFF\\xFE✓")
	// An encoded U+FFFD is valid text, not an error byte.
	testing.expect_value(t, wayu.term_safe("�"), "�")
	// The output never holds a byte < 0x20, DEL, or invalid UTF-8.
	out := wayu.term_safe("\x1b\x9b\xc2\x9b\x07\x7f\xe2\x82")
	testing.expect(t, utf8.valid_string(out), "output must be valid UTF-8")
	for i in 0 ..< len(out) {
		testing.expect(t, out[i] >= 0x20 && out[i] != 0x7f, "raw control byte in output")
	}
}
