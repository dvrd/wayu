package integration

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

@(test)
build_lock :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)
	expect_exit(t, cli, 0, "init", "--shell", "zsh")
	data := fmt.tprintf("%s/.local/share/wayu", cli.home)
	store := fmt.tprintf("%s/entries.json", data)
	write_fixture(
		t,
		store,
		`{"version":1,"paths":[],"env":[],"aliases":[{"name":"wayu_before","value":"true"}]}`,
	)
	file, err := os.open(fmt.tprintf("%s/.wayu.lock", data), {.Read, .Write, .Create})
	if err != nil {
		testing.fail_now(t, fmt.tprintf("open config lock: %v", err))
	}
	defer os.close(file)
	fd := posix.FD(os.fd(file))
	if posix.lockf(fd, .LOCK, 0) != .OK {
		testing.fail_now(t, "cannot hold config lock")
	}

	set_cli_env(&cli, "WAYU_PROMPT_HOOK", "1")
	args := []string{cli.binary, "--shell", "zsh", "build"}
	child, start_err := os.process_start({command = args, env = cli.env, stderr = os.stderr})
	if start_err != nil {
		testing.fail_now(t, fmt.tprintf("start build: %v", start_err))
	}
	time.sleep(500 * time.Millisecond)
	write_fixture(
		t,
		store,
		`{"version":1,"paths":[],"env":[],"aliases":[{"name":"wayu_before","value":"true"},{"name":"wayu_added","value":"true"}]}`,
	)
	if posix.lockf(fd, .ULOCK, 0) != .OK {
		testing.fail_now(t, "cannot release config lock")
	}
	state, wait_err := os.process_wait(child)
	testing.expectf(
		t,
		wait_err == nil && state.exit_code == 0,
		"build: %v, exit %d",
		wait_err,
		state.exit_code,
	)
	core, read_err := os.read_entire_file_from_path(
		fmt.tprintf("%s/core.zsh", data),
		context.temp_allocator,
	)
	testing.expect(t, read_err == nil && strings.contains(string(core), "wayu_added"))
}
