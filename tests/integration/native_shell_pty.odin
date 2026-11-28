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
expect_text :: proc(t: ^testing.T, fd: posix.FD, want: string) -> string {
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
			return strings.to_string(response)
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
	master, pid := start_native_pty(t, cli)
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
	for key in ([]string{"\x0c", "\x1b[108;5u"}) {
		send(t, master, fmt.tprintf("echo AC\x1b[D%s", key))
		expect_text(t, master, "\x1b[2J\x1b[H\r\x1b[Jwayu> echo AC")
		send(t, master, "B\r")
		expect_text(t, master, "\x1b[?2004lABC\r\n")
		expect_text(t, master, "wayu> ")
	}

	send(t, master, "value=prompt\r")
	expect_text(t, master, "\x1b[?2004l")
	expect_text(t, master, "wayu> ")
	send(t, master, "if true; then\r")
	send(t, master, "echo \"$(printf %s $value)\"; fi\r")
	expect_text(t, master, "\x1b[?2004lprompt\r\n")
	expect_text(t, master, "wayu> ")
	send(t, master, "echo $WAYU_STARTUP\r")
	expect_text(t, master, "\x1b[?2004lready\r\n\r\n\x1b[?2004h")
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
	// Short-lived pipeline members exercise the process-group handoff under rapid forks.
	write_fixture(
		t,
		fmt.tprintf("%s/foreground.wayu", cli.home),
		strings.repeat("printf . | cat\n", 64, context.temp_allocator),
	)
	send(t, master, "source ~/foreground.wayu\r")
	expect_text(t, master, strings.repeat(".", 64, context.temp_allocator))
	expect_text(t, master, "wayu> ")
	send(t, master, "false; echo unreachable\r")
	expect_text(t, master, "exited with status 1.")
	expect_text(t, master, "wayu> ")
	send(t, master, "echo $?\r")
	expect_text(t, master, "1\r\n")
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
	send(t, master, "while true; do sleep 30; done\r")
	expect_text(t, master, "\x1b[?2004l")
	time.sleep(100 * time.Millisecond)
	send(t, master, "\x03")
	expect_text(t, master, "wayu> ")
	send(t, master, "echo $?\r")
	expect_text(t, master, "130\r\n")
	expect_text(t, master, "wayu> ")
	send(t, master, "f() { defer echo cleanup-complete; read value; }; f\r")
	expect_text(t, master, "\x1b[?2004l")
	time.sleep(100 * time.Millisecond)
	send(t, master, "\x03")
	expect_text(t, master, "cleanup-complete\r\n")
	expect_text(t, master, "wayu> ")
	send(t, master, "echo $?\r")
	expect_text(t, master, "130\r\n")
	expect_text(t, master, "wayu> ")
	for command in ([]string{"read value", "sleep 2 & wait"}) {
		send(t, master, fmt.tprintf("%s\r", command))
		expect_text(t, master, "\x1b[?2004l")
		time.sleep(100 * time.Millisecond)
		send(t, master, "\x03")
		expect_text(t, master, "wayu> ")
		send(t, master, "echo $?\r")
		expect_text(t, master, "130\r\n")
		expect_text(t, master, "wayu> ")
	}

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
	args := [?]cstring{exe, flags, "-ic", `"$WAYU_TEST_BINARY"; printf 'launcher returned\n'`, nil}
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
	send(t, fd, "exit\r")
	expect_text(t, fd, "launcher returned\r\n")
}

start_native_pty :: proc(
	t: ^testing.T,
	cli: CLI,
	argv: []string = nil,
) -> (
	posix.FD,
	posix.pid_t,
) {
	env := make([]cstring, len(cli.env) + 1, context.temp_allocator)
	for v, i in cli.env {env[i] = strings.clone_to_cstring(v, context.temp_allocator)}
	exe := strings.clone_to_cstring(cli.binary, context.temp_allocator)
	args := make([]cstring, len(argv) + 2, context.temp_allocator)
	args[0] = exe
	for arg, i in argv {args[i + 1] = strings.clone_to_cstring(arg, context.temp_allocator)}

	master: posix.FD
	pid := forkpty(&master, nil, nil, nil)
	if pid < 0 {
		testing.fail_now(t, "could not open pseudo-terminal")
	}
	if pid == 0 {
		posix.execve(exe, raw_data(args[:]), raw_data(env))
		posix._exit(127)
	}
	return master, pid
}

@(test)
native_configured_prompt :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)
	config := fmt.tprintf("%s/.config/wayu", cli.home)
	project := fmt.tprintf("%s/project", cli.home)
	testing.expect_value(t, os.make_directory_all(config), nil)
	testing.expect_value(t, os.make_directory_all(project), nil)
	write_fixture(
		t,
		fmt.tprintf("%s/wayu.toml", config),
		`[prompt]
enabled = true
format = "{dir} {language_context}\n{character} "
[prompt.dir]
format = "[$basename](cyan bold)"
[prompt.contexts.odin]
format = "odin $version"
detect = ["*.odin"]
[prompt.character]
success_symbol = "[ok>](green)"
error_symbol = "[err>](red)"
[prompt.interactive]
toggle_enabled = true
rprompt_format = "[branch={git_branch},changes={git_pending}](yellow)"
`,
	)
	write_fixture(t, fmt.tprintf("%s/config.wayu", config), `cd "$HOME/project"`)
	write_fixture(t, fmt.tprintf("%s/main.odin", project), "package demo")
	sh := cli
	sh.binary = "/bin/sh"
	checked_cli(
		t,
		sh,
		"-c",
		`cd "$HOME/project" && git init -q && git symbolic-ref HEAD refs/heads/prompt-test`,
	)
	fd, pid := start_native_pty(t, cli)
	defer {
		posix.close(fd)
		posix.kill(pid, .SIGKILL)
		rc: c.int
		for posix.waitpid(pid, &rc, {}) < 0 && posix.errno() == .EINTR {}
	}
	expect_text(t, fd, "project odin ")
	expect_text(t, fd, "ok> ")
	expect_text(t, fd, "branch=prompt-test,changes=1")
	send(t, fd, "false\r")
	expect_text(t, fd, "err> ")
	frame := expect_text(t, fd, "\r\x1b[5C")
	testing.expect(
		t,
		strings.contains(frame, "branch=prompt-test,changes=1"),
		"warm prompt lost Git status on its first frame",
	)
	send(t, fd, "touch another-file\r")
	expect_text(t, fd, "branch=prompt-test,changes=2")
	send(t, fd, "cd ..\r")
	expect_text(t, fd, "~ wayu")
	other_dir := expect_text(t, fd, "\r\x1b[4C")
	testing.expect(
		t,
		!strings.contains(other_dir, "branch=prompt-test"),
		"previous directory's Git status leaked into the prompt",
	)
	send(t, fd, "\x07")
	expect_text(t, fd, "~ ➜ ")
	send(t, fd, "\x1b[103;5u")
	expect_text(t, fd, "~ wayu")
	expect_text(t, fd, "ok> ")
	for line in ([]string{"echo ALPHA", "echo BETA"}) {
		send(t, fd, fmt.tprintf("%s\r", line))
		expect_text(t, fd, "\x1b[?2004l")
		expect_text(t, fd, "ok> ")
	}
	send(t, fd, "\x1b[112;5u")
	expect_text(t, fd, "\x1b[2mecho BETA")
	send(t, fd, "echo ")
	expect_text(t, fd, "\x1b[2mBETA")
	send(t, fd, "\x10")
	expect_text(t, fd, "\x1b[2mALPHA")
}

@(test)
native_syntax_highlight :: proc(t: ^testing.T) {
	for mode in ([]string{"enabled", "disabled", "plain"}) {
		cli := new_cli(t)
		defer os.remove_all(cli.home)
		set_cli_env(&cli, "TERM", "xterm-256color")
		set_cli_env(&cli, "NO_COLOR", "1" if mode == "plain" else "")
		set_cli_env(&cli, "WAYU_PLAIN", "")
		config := fmt.tprintf("%s/.config/wayu", cli.home)
		testing.expect_value(t, os.make_directory_all(config), nil)
		write_fixture(
			t,
			fmt.tprintf("%s/wayu.toml", config),
			fmt.tprintf(
				"[settings]\nhighlight = %s\n[settings.highlight_styles]\nbuiltin = \"fg=244,underline\"\ndouble-hyphen-option = \"none\"\n",
				"false" if mode == "disabled" else "true",
			),
		)
		fd, pid := start_native_pty(t, cli)
		defer {
			posix.close(fd)
			posix.kill(pid, .SIGKILL)
			status: c.int
			for posix.waitpid(pid, &status, {}) < 0 && posix.errno() == .EINTR {}
		}
		expect_text(t, fd, "wayu> ")
		line := `cd --opt | printf "猫$HOME" 2> file # comment`
		send(t, fd, fmt.tprintf("\x1b[200~%s\x1b[201~", line))
		if mode != "enabled" {
			expect_text(t, fd, fmt.tprintf("wayu> %s\x1b[0m", line))
			continue
		}
		expect_text(t, fd, "\x1b[38;5;244;4mcd\x1b[0m --opt | \x1b[32mprintf\x1b[0m ")
		expect_text(t, fd, "\x1b[33m\"猫\x1b[0m\x1b[36m$HOME\x1b[0m\x1b[33m\"\x1b[0m ")
		expect_text(t, fd, "\x1b[33m2>\x1b[0m file \x1b[30;1m# comment\x1b[0m")
		send(t, fd, "\x15wayu_missing_cmd")
		expect_text(t, fd, "\x1b[31;1mwayu_missing_cmd\x1b[0m")
		send(t, fd, "\x15printf 'unfinished")
		expect_text(t, fd, "\x1b[33m'unfinished\x1b[0m")
		send(t, fd, "\x15printf [xy]\x1b[D")
		expect_text(t, fd, "\x1b[7m[\x1b[0mxy")
		send(t, fd, "\x15")
	}
}

@(test)
native_autosuggestions :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)

	config := fmt.tprintf("%s/.config/wayu", cli.home)
	testing.expect_value(t, os.make_directory_all(config), nil)
	write_fixture(
		t,
		fmt.tprintf("%s/wayu.toml", config),
		`[autosuggest]
enabled = true
style = "fg=244"
accept_keybind = "ctrl+g"
[tools]
atuin = {kind = "evalcache", args = "init zsh"}
`,
	)
	history := fmt.tprintf("%s/.zsh_history", cli.home)
	write_fixture(t, history, ": 1700000000:0;echo shared-shell\n")
	set_cli_env(&cli, "HISTFILE", history)
	set_cli_env(&cli, "NO_COLOR", "")
	set_cli_env(&cli, "WAYU_PLAIN", "")
	set_cli_env(&cli, "TERM", "xterm-256color")
	set_cli_env(&cli, "PATH", fmt.tprintf("%s:/usr/bin:/bin", cli.home))
	for tool in ([]string{"atuin", "wayu_test_executable"}) {
		path := fmt.tprintf("%s/%s", cli.home, tool)
		write_fixture(
			t,
			path,
			`#!/bin/sh
while [ "$#" -gt 1 ]; do
  if [ "$1" = --format ]; then shift; format=$1; fi
  shift
done
marker=${format%%\{command\}*}
for cmd in 'echo shared-shell' 'echo shared-atuin' 'echo shared-other'; do
  printf '%s%s%s\n' "$marker" "$cmd" "$marker"
done
`,
		)
		testing.expect_value(t, os.chmod(path, {.Read_User, .Write_User, .Execute_User}), nil)
	}

	fd, pid := start_native_pty(t, cli)
	defer {
		posix.close(fd)
		posix.kill(pid, .SIGKILL)
		rc: c.int
		for posix.waitpid(pid, &rc, {}) < 0 && posix.errno() == .EINTR {}
	}

	expect_text(t, fd, "wayu> ")
	send(t, fd, "echo shared-")
	expect_text(t, fd, "\x1b[38;5;244mshell")
	send(t, fd, "\x0e")
	expect_text(t, fd, "\x1b[38;5;244matuin")
	send(t, fd, "\x1b[103;5u\r")
	expect_text(t, fd, "\x1b[?2004lshared-atuin\r\n")
	expect_text(t, fd, "wayu> ")
	send(t, fd, "echo shared-")
	expect_text(t, fd, "\x1b[38;5;244matuin")
	send(t, fd, "\x10")
	expect_text(t, fd, "\x1b[38;5;244mother")
	send(t, fd, "\x07\r")
	expect_text(t, fd, "\x1b[?2004lshared-other\r\n")
	expect_text(t, fd, "wayu> ")
	send(t, fd, "wayu_test_")
	expect_text(t, fd, "\x1b[38;5;244mexecutable")
}


@(test)
native_argument_completion :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)

	sh := cli
	sh.binary = "/bin/sh"
	if _, status := run_cli(t, sh, "-c", "command -v fish"); status != 0 {
		return
	}

	dir := fmt.tprintf("%s/.local/share/wayu/completions", cli.home)
	testing.expect_value(t, os.make_directory_all(dir), nil)
	write_fixture(
		t,
		fmt.tprintf("%s/printf.fish", dir),
		"complete -c printf -f -a 'preview previous'\n",
	)
	checked_cli(t, cli, "alias", "add", "pa", "printf")
	fd, pid := start_native_pty(t, cli)
	defer {
		posix.close(fd)
		posix.kill(pid, .SIGKILL)
		rc: c.int
		for posix.waitpid(pid, &rc, {}) < 0 && posix.errno() == .EINTR {}
	}

	expect_text(t, fd, "wayu> ")
	send(t, fd, "pa prx end\x1b[D\x1b[D\x1b[D\x1b[D\x1b[D\t")
	expect_text(t, fd, "pa preview end")
	send(t, fd, "\t")
	expect_text(t, fd, "pa previous end")
}

@(test)
native_directory_browser :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)

	data := fmt.tprintf("%s/.local/share/wayu", cli.home)
	testing.expect_value(t, os.make_directory_all(data), nil)
	file := fmt.tprintf("%s/directories.json", data)
	dir := fmt.tprintf("%s/sample project", cli.home)
	testing.expect_value(t, os.make_directory_all(dir), nil)
	write_fixture(t, fmt.tprintf("%s/preview.txt", dir), "")
	write_fixture(
		t,
		file,
		fmt.tprintf(
			`{{"%s":{{"count":8,"last_visit":0}},"/other":{{"count":4,"last_visit":0}}}}`,
			dir,
		),
	)
	set_cli_env(&cli, "LINES", "15")
	set_cli_env(&cli, "COLUMNS", "90")
	fd, pid := start_native_pty(t, cli, {"warp", "edit"})
	defer {
		posix.close(fd)
		posix.kill(pid, .SIGKILL)
		rc: c.int
		for posix.waitpid(pid, &rc, {}) < 0 && posix.errno() == .EINTR {}
	}
	expect_text(t, fd, "preview.txt")
	expect_text(t, fd, "Close")
	send(t, fd, "\x0e")
	moved := expect_text(t, fd, "Directory unavailable")
	testing.expect(t, !strings.contains(moved, "\x1b[2J") && !strings.contains(moved, "\x1b[15;"))
	send(t, fd, "project")
	expect_text(t, fd, "preview.txt")
	send(t, fd, "\x17")
	expect_text(t, fd, "\x1b[3;10H\x1b[1m2")
	send(t, fd, "\x13")
	expect_text(t, fd, "\x1b[3;10H\x1b[1m0")
	write_fixture(
		t,
		file,
		fmt.tprintf(
			`{{"%s":{{"count":16,"last_visit":0}},"/other":{{"count":4,"last_visit":0}}}}`,
			dir,
		),
	)
	send(t, fd, "\x12")
	expect_text(t, fd, "\x1b[3;8H\x1b[1m4")
	send(t, fd, "\x04")
	expect_text(t, fd, "Cancel")
	send(t, fd, "\x1b")
	expect_text(t, fd, "Close")
	send(t, fd, "\x04")
	expect_text(t, fd, "Cancel")
	send(t, fd, "y")
	expect_text(t, fd, "No matching directories")
	list := checked_cli(t, cli, "warp", "edit")
	testing.expect(t, strings.contains(list, "/other") && !strings.contains(list, dir))
	send(t, fd, "\x1b")
}

@(test)
warp_search_pipe :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)

	data := fmt.tprintf("%s/.local/share/wayu", cli.home)
	testing.expect_value(t, os.make_directory_all(data), nil)
	write_fixture(
		t,
		fmt.tprintf("%s/directories.json", data),
		`{"/a/space here":{"count":4,"last_visit":0},"/other":{"count":8,"last_visit":0}}`,
	)
	sh := cli
	sh.binary = "/bin/sh"
	for cancel in ([]bool{false, true}) {
		fd, pid := start_native_pty(
			t,
			sh,
			{
				"-c",
				`"$0" warp search space </dev/null | cat > "$HOME/selected"; echo done`,
				cli.binary,
			},
		)
		defer {
			posix.close(fd)
			posix.kill(pid, .SIGKILL)
			rc: c.int
			for posix.waitpid(pid, &rc, {}) < 0 && posix.errno() == .EINTR {}
		}

		expect_text(t, fd, "/a/space here")
		send(t, fd, "\x1b" if cancel else "\r")
		expect_text(t, fd, "done")
		testing.expect_value(
			t,
			read_fixture(t, fmt.tprintf("%s/selected", cli.home)),
			"" if cancel else "/a/space here\n",
		)
	}

	out, _, status := cli_streams(t, cli, "warp", "search", "no-such-directory")
	testing.expect_value(t, out, "")
	testing.expect_value(t, status, 1)
}

@(test)
native_editor_undo_paste :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)

	fd, pid := start_native_pty(t, cli)
	defer {
		posix.close(fd)
		posix.kill(pid, .SIGKILL)
		status: c.int
		for posix.waitpid(pid, &status, {}) < 0 && posix.errno() == .EINTR {}
	}

	expect_text(t, fd, "wayu> ")
	send(t, fd, "echo ok\x1b[200~界undo\x1b[201~\x1f\r")
	expect_text(t, fd, "\x1b[?2004lok\r\n")
}

@(test)
native_history_paging :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)

	cfg := fmt.tprintf("%s/.config/wayu", cli.home)
	data := fmt.tprintf("%s/.local/share/wayu", cli.home)
	os.make_directory_all(cfg)
	os.make_directory_all(data)
	write_fixture(
		t,
		fmt.tprintf("%s/wayu.toml", cfg),
		"[settings]\nhistory_bytes=12\nhistory_entries=1\n",
	)
	write_fixture(
		t,
		fmt.tprintf("%s/history.jsonl", data),
		"\"echo earlier than window\"\n\"echo later\"\n",
	)
	fd, pid := start_native_pty(t, cli)
	defer {
		posix.close(fd)
		posix.kill(pid, .SIGKILL)
		status: c.int
		for posix.waitpid(pid, &status, {}) < 0 && posix.errno() == .EINTR {}
	}

	expect_text(t, fd, "wayu> ")
	send(t, fd, "\x1b[A\x1b[A\r")
	expect_text(t, fd, "\x1b[?2004learlier than window\r\n")
	expect_text(t, fd, "wayu> ")
	send(t, fd, "\x12earlier\r again\r")
	expect_text(t, fd, "\x1b[?2004learlier than window again\r\n")
}

// Two open sessions share history.jsonl: each recalls what the other ran, the
// file holds every record once per submission, and a rotated file is picked
// up without restarting either session.
@(test)
native_history_sessions :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)

	a, a_pid := start_native_pty(t, cli)
	defer {
		posix.close(a)
		posix.kill(a_pid, .SIGKILL)
		status: c.int
		for posix.waitpid(a_pid, &status, {}) < 0 && posix.errno() == .EINTR {}
	}

	b, b_pid := start_native_pty(t, cli)
	defer {
		posix.close(b)
		posix.kill(b_pid, .SIGKILL)
		status: c.int
		for posix.waitpid(b_pid, &status, {}) < 0 && posix.errno() == .EINTR {}
	}

	expect_text(t, a, "wayu> ")
	expect_text(t, b, "wayu> ")
	send(t, a, "echo from-a\r")
	expect_text(t, a, "\x1b[?2004lfrom-a\r\n")
	expect_text(t, a, "wayu> ")
	send(t, b, "echo from-b\r")
	expect_text(t, b, "\x1b[?2004lfrom-b\r\n")
	expect_text(t, b, "wayu> ")

	send(t, a, "\x1b[A\r")
	expect_text(t, a, "\x1b[?2004lfrom-b\r\n")
	expect_text(t, a, "wayu> ")
	send(t, b, "\x12from-a\r\r")
	expect_text(t, b, "\x1b[?2004lfrom-a\r\n")
	expect_text(t, b, "wayu> ")

	history := fmt.tprintf("%s/.local/share/wayu/history.jsonl", cli.home)
	testing.expect_value(
		t,
		read_fixture(t, history),
		"\"echo from-a\"\n\"echo from-b\"\n\"echo from-b\"\n\"echo from-a\"\n",
	)

	// Both sessions append at the same time: each record stays one whole line.
	burst :: 10
	for i in 0 ..< burst {
		send(t, a, fmt.tprintf("echo a-%d\r", i))
		send(t, b, fmt.tprintf("echo b-%d\r", i))
	}

	expect_text(t, a, fmt.tprintf("\x1b[?2004la-%d\r\n", burst - 1))
	expect_text(t, a, "wayu> ")
	expect_text(t, b, fmt.tprintf("\x1b[?2004lb-%d\r\n", burst - 1))
	expect_text(t, b, "wayu> ")
	records := make(map[string]int, context.temp_allocator)
	lines := strings.split_lines(
		strings.trim_right(read_fixture(t, history), "\n"),
		context.temp_allocator,
	)
	for line in lines {records[line] += 1}

	testing.expect_value(t, len(lines), 4 + 2 * burst)
	for i in 0 ..< burst {
		testing.expect_value(t, records[fmt.tprintf("\"echo a-%d\"", i)], 1)
		testing.expect_value(t, records[fmt.tprintf("\"echo b-%d\"", i)], 1)
	}

	rotated := fmt.tprintf("%s/.local/share/wayu/history.rotated", cli.home)
	write_fixture(t, rotated, "\"echo rotated\"\n")
	testing.expect_value(t, os.rename(rotated, history), nil)
	send(t, a, "\x1b[A\r")
	expect_text(t, a, "\x1b[?2004lrotated\r\n")
	expect_text(t, a, "wayu> ")
	send(t, b, "echo after-rotation\r")
	expect_text(t, b, "\x1b[?2004lafter-rotation\r\n")
	expect_text(t, b, "wayu> ")
	testing.expect_value(
		t,
		read_fixture(t, history),
		"\"echo rotated\"\n\"echo rotated\"\n\"echo after-rotation\"\n",
	)
}
