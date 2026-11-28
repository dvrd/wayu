package integration

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

@(private = "file")
close_native_pty :: proc(fd: posix.FD, pid: posix.pid_t) {
	posix.close(fd)
	posix.kill(pid, .SIGKILL)
	status: c.int
	for posix.waitpid(pid, &status, {}) < 0 && posix.errno() == .EINTR {}
}

// Configured limits in a session that starts with earlier history and keeps
// running: the undo ledger and the resident history window stay small, the
// line and the history file do not lose anything.
@(test)
native_retention_budgets :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)

	cfg := fmt.tprintf("%s/.config/wayu", cli.home)
	data := fmt.tprintf("%s/.local/share/wayu", cli.home)
	os.make_directory_all(cfg)
	os.make_directory_all(data)
	// undo_bytes holds two one-key edits. The history window holds two
	// commands of at most 64 bytes together.
	write_fixture(
		t,
		fmt.tprintf("%s/wayu.toml", cfg),
		"[settings]\nundo_bytes = 200\nhistory_entries = 2\nhistory_bytes = 64\n",
	)
	big := strings.repeat("x", 100, context.temp_allocator)
	earlier := fmt.tprintf("\"echo old-1\"\n\"echo old-2\"\n\"echo %s\"\n", big)
	history := fmt.tprintf("%s/history.jsonl", data)
	write_fixture(t, history, earlier)

	fd, pid := start_native_pty(t, cli)
	defer close_native_pty(fd, pid)

	expect_text(t, fd, "wayu> ")
	// Four undo keys: the two newest edits are undone, older ones have expired.
	send(t, fd, "echo abcdef\x1f\x1f\x1f\x1f\r")
	expect_text(t, fd, "\x1b[?2004labcd\r\n")
	expect_text(t, fd, "wayu> ")
	for word in ([]string{"one", "two", "three"}) {
		send(t, fd, fmt.tprintf("echo %s\r", word))
		expect_text(t, fd, fmt.tprintf("\x1b[?2004l%s\r\n", word))
		expect_text(t, fd, "wayu> ")
	}

	// Recall pages past the two resident commands: this session's first
	// command, then the record larger than the window, then earlier history.
	send(t, fd, "\x1b[A\x1b[A\x1b[A\x1b[A\r")
	expect_text(t, fd, "\x1b[?2004labcd\r\n")
	expect_text(t, fd, "wayu> ")
	send(t, fd, "\x1b[A\x1b[A\x1b[A\x1b[A\x1b[A\x1b[A\r")
	expect_text(t, fd, fmt.tprintf("\x1b[?2004l%s\r\n", big))
	expect_text(t, fd, "wayu> ")
	send(t, fd, "\x12old-1\r\r")
	expect_text(t, fd, "\x1b[?2004lold-1\r\n")
	expect_text(t, fd, "wayu> ")

	// The file keeps every record, in order, whatever the window dropped.
	testing.expect_value(
		t,
		read_fixture(t, history),
		fmt.tprintf(
			"%s\"echo abcd\"\n\"echo one\"\n\"echo two\"\n\"echo three\"\n\"echo abcd\"\n\"echo %s\"\n\"echo old-1\"\n",
			earlier,
			big,
		),
	)
}

// Without configuration nothing is limited: every edit can be undone and a
// long-running session recalls its first command.
@(test)
native_retention_defaults :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)

	fd, pid := start_native_pty(t, cli)
	defer close_native_pty(fd, pid)

	expect_text(t, fd, "wayu> ")
	send(
		t,
		fd,
		fmt.tprintf(
			"echo kept%s%s\r",
			strings.repeat("z", 64, context.temp_allocator),
			strings.repeat("\x1f", 64, context.temp_allocator),
		),
	)
	expect_text(t, fd, "\x1b[?2004lkept\r\n")
	expect_text(t, fd, "wayu> ")

	expected := strings.builder_make(context.temp_allocator)
	strings.write_string(&expected, "\"echo kept\"\n")
	for i in 0 ..< 24 {
		send(t, fd, fmt.tprintf("echo n%d\r", i))
		expect_text(t, fd, fmt.tprintf("\x1b[?2004ln%d\r\n", i))
		expect_text(t, fd, "wayu> ")
		fmt.sbprintf(&expected, "\"echo n%d\"\n", i)
	}

	send(t, fd, fmt.tprintf("%s\r", strings.repeat("\x1b[A", 24, context.temp_allocator)))
	expect_text(t, fd, "\x1b[?2004ln0\r\n")
	expect_text(t, fd, "wayu> ")
	strings.write_string(&expected, "\"echo n0\"\n")
	testing.expect_value(
		t,
		read_fixture(t, fmt.tprintf("%s/.local/share/wayu/history.jsonl", cli.home)),
		strings.to_string(expected),
	)
}

// Each limit is a non-negative integer. Anything else fails validation, and
// the native shell then runs without that limit.
@(test)
native_limit_validation :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)

	expect_exit(t, cli, 0, "init", "--shell", "zsh")
	config := fmt.tprintf("%s/.config/wayu/wayu.toml", cli.home)
	for key in ([]string{"capture_bytes", "undo_bytes", "history_bytes", "history_entries"}) {
		for value in ([]string{"-1", "\"many\"", "1.5"}) {
			write_fixture(t, config, fmt.tprintf("[settings]\n%s = %s\n", key, value))
			out, code := run_cli(t, cli, "toml", "validate")
			testing.expectf(
				t,
				code == 65 &&
				strings.contains(
					out,
					fmt.tprintf("settings.%s must be a non-negative integer", key),
				),
				"%s = %s: exit %d: %s",
				key,
				value,
				code,
				out,
			)
		}

		write_fixture(t, config, fmt.tprintf("[settings]\n%s = 0\n", key))
		expect_exit(t, cli, 0, "toml", "validate")
	}

	write_fixture(t, config, "[settings]\ncapture_bytes = -1\n")
	expect_exit(t, cli, 78, "doctor")
	out, _, code := cli_streams(t, cli, "-c", "v=$(printf ok); echo \"$v\"")
	testing.expect_value(t, code, 0)
	testing.expect_value(t, out, "ok\n")
}
