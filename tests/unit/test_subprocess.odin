package test_wayu

import "core:testing"
import "core:strings"
import wayu "../../src"

@(test)
test_run_command_success :: proc(t: ^testing.T) {
	// /usr/bin/true always exits 0 (macOS path; /bin/true on Linux)
	ok := wayu.run_command([]string{"/usr/bin/true"})
	testing.expect(t, ok, "run_command(/usr/bin/true) should return true")
}

@(test)
test_run_command_failure :: proc(t: ^testing.T) {
	// /usr/bin/false always exits 1 (macOS path; /bin/false on Linux)
	ok := wayu.run_command([]string{"/usr/bin/false"})
	testing.expect(t, !ok, "run_command(/usr/bin/false) should return false")
}

@(test)
test_run_command_with_args :: proc(t: ^testing.T) {
	// echo exits 0 regardless of args
	ok := wayu.run_command([]string{"echo", "hello", "world"})
	testing.expect(t, ok, "run_command(echo hello world) should return true")
}

@(test)
test_run_command_missing_binary :: proc(t: ^testing.T) {
	// Non-existent binary should return false
	ok := wayu.run_command([]string{"/nonexistent/binary/that/does/not/exist"})
	testing.expect(t, !ok, "run_command with missing binary should return false")
}

@(test)
test_capture_command_output :: proc(t: ^testing.T) {
	// echo outputs a known string
	output := wayu.capture_command([]string{"echo", "hello"})
	defer delete(output)
	testing.expect(t, output == "hello", "capture_command(echo hello) should return 'hello'")
}

@(test)
test_capture_command_trims_whitespace :: proc(t: ^testing.T) {
	// printf with spaces — output should be trimmed
	output := wayu.capture_command([]string{"printf", "  hello  "})
	defer delete(output)
	testing.expect(t, output == "hello", "capture_command should trim surrounding whitespace")
}

@(test)
test_capture_command_failure_returns_empty :: proc(t: ^testing.T) {
	// Non-existent binary returns empty string
	output := wayu.capture_command([]string{"/nonexistent/binary"})
	defer delete(output)
	testing.expect(t, output == "", "capture_command with missing binary should return empty string")
}

@(test)
test_capture_command_multiline_returns_trimmed :: proc(t: ^testing.T) {
	// printf with newline — trim_space removes trailing newline
	output := wayu.capture_command([]string{"printf", "abc\n"})
	defer delete(output)
	testing.expect(t, output == "abc", "capture_command should trim trailing newline")
}

@(test)
test_run_command_with_stdin_success :: proc(t: ^testing.T) {
	// cat reads stdin and exits 0
	ok := wayu.run_command_with_stdin([]string{"cat"}, "hello")
	testing.expect(t, ok, "run_command_with_stdin(cat) should return true")
}

@(test)
test_run_command_with_stdin_empty_input :: proc(t: ^testing.T) {
	// cat with empty stdin still exits 0
	ok := wayu.run_command_with_stdin([]string{"cat"}, "")
	testing.expect(t, ok, "run_command_with_stdin with empty input should return true")
}
