package integration

import "core:c"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

@(test)
native_capture_budget :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)

	dir := fmt.tprintf("%s/.config/wayu", cli.home)
	os.make_directory_all(dir)
	write_fixture(t, fmt.tprintf("%s/wayu.toml", dir), "[settings]\ncapture_bytes = 8192\n")
	for n in ([]int{8191, 8192, 8193}) {
		data := strings.repeat("x", n, context.temp_allocator)
		path := fmt.tprintf("%s/data", cli.home)
		write_fixture(t, path, data)
		cmd := fmt.tprintf("v=$(cat '%s'); echo accepted", path)
		out, err, rc := cli_streams(t, cli, "-c", cmd)
		if n <= 8192 {
			testing.expect_value(t, rc, 0)
			testing.expect_value(t, out, "accepted\n")
		} else {
			testing.expect_value(t, rc, 65)
			testing.expect_value(t, out, "")
			testing.expect(t, strings.contains(err, "capture_bytes"))
		}
	}

	// The trailing newline counts toward the limit before expansion would trim it.
	path := fmt.tprintf("%s/trailing", cli.home)
	write_fixture(t, path, fmt.tprintf("%s\n", strings.repeat("x", 8192, context.temp_allocator)))
	expect_exit(t, cli, 65, "-c", fmt.tprintf("v=$(cat '%s')", path))

	// No part of an oversized value reaches the command that would consume it.
	partial, _, partial_rc := cli_streams(t, cli, "-c", "echo \"$(yes)\"")
	testing.expect_value(t, partial_rc, 65)
	testing.expect_value(t, partial, "")
	target := fmt.tprintf("%s/consumer", cli.home)
	expect_exit(t, cli, 65, "-c", fmt.tprintf("printf %%s \"$(yes)\" > '%s'", target))
	if consumed, read_err := os.read_entire_file_from_path(target, context.temp_allocator);
	   read_err == nil {
		testing.expect_value(t, len(consumed), 0)
	}

	expect_exit(t, cli, 65, "-c", "v=$(echo \"$(yes)\")")
	expect_exit(t, cli, 0, "-c", "yes | head -c 20000 > /dev/null")
	out, _, status := cli_streams(t, cli, "-c", "v=$(yes) || echo recovered; echo \"[$v]\"")
	testing.expect_value(t, status, 0)
	testing.expect_value(t, out, "recovered\n[]\n")

	// Each substitution has its own allowance, including one nested in another.
	// The inner one fits exactly; echo's newline takes the outer one over.
	exact := fmt.tprintf("%s/exact", cli.home)
	write_fixture(t, exact, strings.repeat("x", 8192, context.temp_allocator))
	expect_exit(t, cli, 0, "-c", fmt.tprintf("v=$(printf %%s \"$(cat '%s')\")", exact))
	expect_exit(t, cli, 65, "-c", fmt.tprintf("v=$(echo \"$(cat '%s')\")", exact))

	// The producer is cancelled with its substitution. This one stops writing
	// after the overflow, so only the cancellation ends its heartbeat.
	pid_file := fmt.tprintf("%s/producer.pid", cli.home)
	beat := fmt.tprintf("%s/producer.beat", cli.home)
	expect_exit(
		t,
		cli,
		65,
		"-c",
		fmt.tprintf(
			"v=$(sh -c 'echo $$ > \"%s\"; yes | head -c 9000; while :; do echo beat > \"%s\"; sleep 0.05; done' 2>/dev/null)",
			pid_file,
			beat,
		),
	)
	os.remove(beat)
	time.sleep(500 * time.Millisecond)
	if os.exists(beat) {
		// Still running: it is ours, so stop it before failing.
		if producer, ok := strconv.parse_int(strings.trim_space(read_fixture(t, pid_file)), 10);
		   ok {
			posix.kill(posix.pid_t(producer), .SIGKILL)
		}

		testing.fail_now(t, "the producer kept running after its substitution was cancelled")
	}

	// A limit that is not a multiple of the read size is exact as well.
	write_fixture(t, fmt.tprintf("%s/wayu.toml", dir), "[settings]\ncapture_bytes = 10000\n")
	uneven := fmt.tprintf("%s/uneven", cli.home)
	for n in ([]int{10000, 10001}) {
		write_fixture(t, uneven, strings.repeat("x", n, context.temp_allocator))
		expect_exit(t, cli, 0 if n == 10000 else 65, "-c", fmt.tprintf("v=$(cat '%s')", uneven))
	}

	write_fixture(t, fmt.tprintf("%s/wayu.toml", dir), "[settings]\ncapture_bytes = 8192\n")

	// An unrelated background job can still finish after an unlimited producer is cancelled.
	expect_exit(t, cli, 0, "-c", "sleep 0.1 & keeper=$!; v=$(yes) || wait $keeper")
	// Signal readiness from inside the capture before sending terminal Ctrl+C.
	fd, pid := start_native_pty(t, cli)
	defer {
		posix.close(fd)
		posix.kill(pid, .SIGKILL)
		status: c.int
		for posix.waitpid(pid, &status, {}) < 0 && posix.errno() == .EINTR {}
	}

	expect_text(t, fd, "wayu> ")
	send(t, fd, "v=$(sh -c 'echo waiting >&2; sleep 30')\r")
	expect_text(t, fd, "\x1b[?2004lwaiting\r\n")
	send(t, fd, "\x03")
	expect_text(t, fd, "wayu> ")
	send(t, fd, "echo $?\r")
	expect_text(t, fd, "\x1b[?2004l130\r\n")
	expect_text(t, fd, "wayu> ")

	// A producer that never stops writing is interrupted the same way, and the
	// session keeps working.
	send(t, fd, "v=$(sh -c 'echo writing >&2; while :; do echo tick; sleep 0.05; done')\r")
	expect_text(t, fd, "\x1b[?2004lwriting\r\n")
	send(t, fd, "\x03")
	expect_text(t, fd, "wayu> ")
	send(t, fd, "echo $? \"[$v]\"\r")
	expect_text(t, fd, "\x1b[?2004l130 []\r\n")
}

// Without a configured limit a substitution is unbounded, and Ctrl+C still
// ends a producer that never stops writing.
@(test)
native_capture_default :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)

	path := fmt.tprintf("%s/large", cli.home)
	// Below Linux's 128 KiB limit for one argument, above its 64 KiB pipe buffer.
	write_fixture(t, path, strings.repeat("x", 100000, context.temp_allocator))
	out, _, rc := cli_streams(
		t,
		cli,
		"-c",
		fmt.tprintf("v=$(cat '%s'); printf %%s \"$v\" | wc -c", path),
	)
	testing.expect_value(t, rc, 0)
	testing.expect_value(t, strings.trim_space(out), "100000")

	fd, pid := start_native_pty(t, cli)
	defer {
		posix.close(fd)
		posix.kill(pid, .SIGKILL)
		status: c.int
		for posix.waitpid(pid, &status, {}) < 0 && posix.errno() == .EINTR {}
	}

	expect_text(t, fd, "wayu> ")
	send(t, fd, "v=$(sh -c 'echo writing >&2; while :; do echo tick; sleep 0.05; done')\r")
	expect_text(t, fd, "\x1b[?2004lwriting\r\n")
	send(t, fd, "\x03")
	expect_text(t, fd, "wayu> ")
	send(t, fd, "echo $? \"[$v]\"\r")
	expect_text(t, fd, "\x1b[?2004l130 []\r\n")
}
