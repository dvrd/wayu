package integration

import wayu "../../src"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

when ODIN_OS == .Linux {foreign import pty_lib "system:util"} else {foreign import pty_lib "system:c"}
foreign pty_lib {
	forkpty :: proc(master: ^posix.FD, name: cstring, term: ^posix.termios, size: rawptr) -> posix.pid_t ---
}

send :: proc(t: ^testing.T, fd: posix.FD, data: string) {
	written := posix.write(fd, raw_data(data), c.size_t(len(data)))
	testing.expect_value(t, int(written), len(data))
}
expect_text :: proc(t: ^testing.T, fd: posix.FD, want: string) {
	start := time.tick_now()
	response := strings.builder_make(context.temp_allocator)
	for time.tick_since(start) < 5 * time.Second {
		poll := posix.pollfd {
			fd     = fd,
			events = {.IN},
		}
		if posix.poll(&poll, 1, 100) <= 0 {
			continue
		}
		// Leave bytes after the match for the next expectation.
		buf: [1]u8
		n := posix.read(fd, &buf[0], len(buf))
		if n <= 0 {
			break
		}
		strings.write_string(&response, string(buf[:n]))
		if strings.contains(strings.to_string(response), want) {
			return
		}
	}
	testing.fail_now(
		t,
		fmt.tprintf("terminal did not display %q: %q", want, strings.to_string(response)),
	)
}

@(test)
native_shell_terminal :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)
	config := fmt.tprintf("%s/.config/wayu", cli.home)
	testing.expect_value(t, os.make_directory_all(config), nil)
	write_fixture(t, fmt.tprintf("%s/wayu.toml", config), "[prompt]\nvi_mode = true\n")
	write_fixture(t, fmt.tprintf("%s/config.wayu", config), "export WAYU_STARTUP=ready\n")
	write_fixture(t, fmt.tprintf("%s/file with spaces", cli.home), "completed file\n")
	env := make([]cstring, len(cli.env) + 1, context.temp_allocator)
	for v, i in cli.env {env[i] = strings.clone_to_cstring(v, context.temp_allocator)}
	exe := strings.clone_to_cstring(cli.binary, context.temp_allocator)
	args := [3]cstring{exe, "shell", nil}
	master: posix.FD
	pid := forkpty(&master, nil, nil, nil)
	if pid < 0 {
		testing.fail_now(t, "could not open pseudo-terminal")
	}
	if pid == 0 {
		posix.execve(exe, raw_data(args[:]), raw_data(env))
		posix._exit(127)
	}
	defer {
		posix.close(master)
		posix.kill(pid, .SIGKILL)
		status: c.int
		for posix.waitpid(pid, &status, {}) < 0 && posix.errno() == .EINTR {}
	}
	expect_text(t, master, "wayu> ")
	for line in ([]string{"echo ONE", "echo TWO"}) {
		send(t, master, fmt.tprintf("%s\r", line))
		expect_text(t, master, "\x1b[?2004l")
		expect_text(t, master, "wayu> ")
	}
	send(t, master, "echo ")
	expect_text(t, master, "\x1b[2mTWO")
	send(t, master, "\x0e")
	expect_text(t, master, "\x1b[2mONE")
	send(t, master, "\x1b[C\r")
	expect_text(t, master, "ONE\r\n")
	expect_text(t, master, "wayu> ")
	send(t, master, "echo $WAYU_STARTUP\r")
	expect_text(t, master, "\x1b[?2004lready\r\n")
	expect_text(t, master, "wayu> ")
	send(t, master, "echo catX\x1bxA!\r")
	expect_text(t, master, "\x1b[?2004lcat!\r\n")
	expect_text(t, master, "wayu> ")
	send(t, master, "\x12cat!\r-accepted\r")
	expect_text(t, master, "\x1b[?2004lcat!-accepted\r\n")
	expect_text(t, master, "wayu> ")
	send(t, master, "echo undoX\x1f\r")
	expect_text(t, master, "\x1b[?2004lundo\r\n")
	expect_text(t, master, "wayu> ")
	send(t, master, "echo drop keep\x1b0wdw\r")
	expect_text(t, master, "\x1b[?2004lkeep\r\n")
	expect_text(t, master, "wayu> ")
	send(t, master, "\x1b[200~printf '%s' 'first\nsecond界'\x1b[201~\r")
	expect_text(t, master, "\x1b[?2004lfirst\r\nsecond界")
	expect_text(t, master, "wayu> ")
	send(t, master, "cat ~/file\t\r")
	expect_text(t, master, "\x1b[?2004lcompleted file\r\n")
	expect_text(t, master, "wayu> ")
	send(t, master, "sleep 30\r")
	expect_text(t, master, "\x1b[?2004l")
	time.sleep(100 * time.Millisecond)
	send(t, master, "\x1a")
	expect_text(t, master, "wayu> ")
	send(t, master, "jobs\r")
	expect_text(t, master, "Stopped sleep")
	send(t, master, "fg\r")
	expect_text(t, master, "\x1b[?2004l")
	time.sleep(100 * time.Millisecond)
	send(t, master, "\x03")
	expect_text(t, master, "wayu> ")
	send(t, master, "echo $?\r")
	expect_text(t, master, "130\r\n")
	expect_text(t, master, "wayu> ")
	testing.expect_value(t, posix.kill(pid, .SIGTERM), .OK)
	expect_text(t, master, "\x1b[?2004l")
	modes: posix.termios
	testing.expect_value(t, posix.tcgetattr(master, &modes), .OK)
	testing.expect(t, .ECHO in modes.c_lflag && .ICANON in modes.c_lflag)
}

@(test)
native_shell_launchers :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)
	for shell in ([]string{"bash", "zsh", "fish"}) {
		sh := cli
		sh.binary = "/bin/sh"
		path, found := run_cli(t, sh, "-c", `command -v "$1"`, "which", shell)
		if found != 0 {
			continue
		}
		path = strings.trim_space(path)
		run_native_launcher(t, cli, shell, path)
	}
}

run_native_launcher :: proc(t: ^testing.T, cli: CLI, shell, path: string) {
	env := make([dynamic]cstring, context.temp_allocator)
	for v in cli.env {
		if !strings.has_prefix(v, "SHELL=") {
			append(&env, strings.clone_to_cstring(v, context.temp_allocator))
		}
	}
	append(&env, strings.clone_to_cstring(fmt.tprintf("SHELL=%s", path), context.temp_allocator))
	append(
		&env,
		strings.clone_to_cstring(
			fmt.tprintf("WAYU_TEST_BINARY=%s", cli.binary),
			context.temp_allocator,
		),
		nil,
	)
	exe := strings.clone_to_cstring(path, context.temp_allocator)
	flags: cstring = "-f"
	if shell == "bash" {
		flags = "--norc"
	} else if shell == "fish" {
		flags = "--no-config"
	}
	args := [?]cstring {
		exe,
		flags,
		"-ic",
		`"$WAYU_TEST_BINARY" shell; printf 'launcher returned\n'`,
		nil,
	}
	fd: posix.FD
	size := wayu.winsize {
		ws_row = 24,
		ws_col = 80,
	}
	pid := forkpty(&fd, nil, nil, &size)
	if pid < 0 {
		testing.fail_now(t, "could not start launcher terminal")
	}
	if pid == 0 {
		posix.execve(exe, raw_data(args[:]), raw_data(env)); posix._exit(127)
	}
	defer {
		posix.close(fd)
		posix.kill(pid, .SIGKILL)
		status: c.int
		for posix.waitpid(pid, &status, {}) < 0 && posix.errno() == .EINTR {}
	}
	expect_text(t, fd, "wayu> ")
	send(t, fd, "echo launcher-test\r")
	expect_text(t, fd, "\x1b[?2004llauncher-test\r\n")
	expect_text(t, fd, "wayu> ")
	history := fmt.tprintf("%s/.local/share/wayu/history.jsonl", cli.home)
	record := read_fixture(t, history)
	testing.expectf(
		t,
		strings.contains(record, "echo launcher-test"),
		"%s history missing the submitted command",
		shell,
	)
	send(t, fd, "echo launch\x10\x1b[C\r")
	expect_text(t, fd, "\x1b[?2004llauncher-test\r\n")
	expect_text(t, fd, "wayu> ")
	send(t, fd, "\"$WAYU_TEST_BINARY\" --tui\r")
	expect_text(t, fd, "\x1b[?1049h")
	expect_text(t, fd, "Shell Configuration Manager")
	send(t, fd, "q")
	expect_text(t, fd, "\x1b[?1049l")
	expect_text(t, fd, "wayu> ")
	send(t, fd, "exit\r")
	expect_text(t, fd, "launcher returned\r\n")
}
