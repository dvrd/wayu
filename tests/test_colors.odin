package test_wayu

import "core:testing"
import "core:fmt"
import "core:strings"
import wayu "../src"

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