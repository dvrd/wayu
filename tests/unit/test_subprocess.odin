package test_wayu

import wayu "../../src"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
test_run_command_timeout_after_output_closed :: proc(t: ^testing.T) {
	start := time.tick_now()
	r := wayu.run_command_timeout([]string{"sh", "-c", "exec >/dev/null 2>&1; sleep 2"}, 100)
	defer wayu.command_result_destroy(&r)
	testing.expect(
		t,
		r.timed_out && !r.ok,
		"deadline must cover children that close both output streams",
	)
	testing.expect(
		t,
		time.tick_since(start) < time.Second,
		"closed streams must not bypass the deadline",
	)

	// No deadline still waits for the actual exit code, rather than treating
	// EOF as success or timing an ordinary child out.
	done := wayu.run_command_timeout(
		[]string{"sh", "-c", "exec >/dev/null 2>&1; sleep 0.05; exit 7"},
		0,
	)
	defer wayu.command_result_destroy(&done)
	testing.expect(t, !done.timed_out && !done.ok)
	testing.expect_value(t, done.exit_code, 7)
}

@(test)
test_subprocess_capture_limits_unaligned_chunks :: proc(t: ^testing.T) {
	// The first short chunk makes the capture boundary fall inside a later
	// read. Both runners must cap bytes, rather than only count full reads.
	producer :: "printf a; sleep 0.05; head -c 70000 /dev/zero | tr '\\000' x"
	r := wayu.run_command_timeout([]string{"sh", "-c", producer}, 5000)
	defer wayu.command_result_destroy(&r)
	testing.expect(t, r.ok)
	testing.expect_value(t, len(r.stdout), 64 * 1024)
	ok, stderr := wayu.run_command_capture_stderr(
		[]string{"sh", "-c", "{ " + producer + "; } >&2"},
	)
	defer delete(stderr)
	testing.expect(t, ok)
	testing.expect_value(t, len(stderr), 64 * 1024)
}

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
	testing.expect(
		t,
		output == "",
		"capture_command with missing binary should return empty string",
	)
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

// OKAMI-325: stdin input with a deadline (secret-tool store).
@(test)
test_run_command_timeout_stdin :: proc(t: ^testing.T) {
	r := wayu.run_command_timeout([]string{"cat"}, 5000, stdin_data = "fake-key-hex\n")
	defer wayu.command_result_destroy(&r)
	testing.expect(t, r.ok && r.stdout == "fake-key-hex", r.stdout)

	// A child that reads its stdin and then hangs is killed at the deadline.
	h := wayu.run_command_timeout(
		[]string{"sh", "-c", "read x; sleep 30"},
		300,
		stdin_data = "fake\n",
	)
	defer wayu.command_result_destroy(&h)
	testing.expect(t, h.timed_out && !h.ok, "hung child must time out")

	// A child that exits without reading must not take us down (SIGPIPE).
	e := wayu.run_command_timeout([]string{"true"}, 5000, stdin_data = "fake")
	defer wayu.command_result_destroy(&e)
	testing.expect(t, e.ok)
}
