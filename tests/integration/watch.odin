package integration

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

watch_child :: proc(t: ^testing.T, cli: CLI, args: ..string) -> os.Process {
	child, err := os.process_start({command = args, env = cli.env})
	if err != nil {
		testing.fail_now(t, fmt.tprintf("start %v: %v", args, err))
	}
	return child
}

reap_watch_child :: proc(child: os.Process) {
	state, err := os.process_wait(child, 0)
	if (err == os.General_Error.Timeout || err == nil) && !state.exited {
		_ = os.process_kill(child)
		_, _ = os.process_wait(child)
	}
}

@(test)
watch :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)
	expect_exit(t, cli, 0, "init", "--shell", "zsh")
	pid_file := fmt.tprintf("%s/.local/share/wayu/watcher.pid", cli.home)
	victim := watch_child(t, cli, "sleep", "60")
	defer reap_watch_child(victim)
	write_fixture(t, pid_file, fmt.tprintf("%d", victim.pid))
	testing.expect(t, strings.contains(checked_cli(t, cli, "watch", "status"), "not running"))
	testing.expect(t, strings.contains(checked_cli(t, cli, "watch", "stop"), "not running"))
	time.sleep(200 * time.Millisecond)
	alive, e := os.process_wait(victim, 0)
	testing.expect(
		t,
		(e == os.General_Error.Timeout || e == nil) && !alive.exited && !os.exists(pid_file),
	)

	outside := fmt.tprintf("%s/outside", cli.home)
	write_fixture(t, outside, "keep\n")
	testing.expect_value(t, os.symlink(outside, pid_file), nil)
	watcher := watch_child(t, cli, cli.binary, "watch")
	defer reap_watch_child(watcher)
	start := time.tick_now()
	for {
		info, err := os.lstat(pid_file, context.temp_allocator)
		if err == nil && info.type == .Regular {
			testing.expect_value(t, info.mode, os.Permissions{.Read_User, .Write_User})
			break
		}
		if time.tick_since(start) > 10 * time.Second {
			testing.fail_now(t, "watcher did not replace the PID file")
		}
		time.sleep(50 * time.Millisecond)
	}
	testing.expect_value(t, read_fixture(t, outside), "keep\n")
	testing.expect(t, strings.contains(checked_cli(t, cli, "watch", "status"), "is running"))
	testing.expect(t, strings.contains(checked_cli(t, cli, "watch", "start"), "already running"))
	actual_pid := read_fixture(t, pid_file)
	write_fixture(t, pid_file, fmt.tprintf("%d", victim.pid))
	out, code := run_cli(t, cli, "watch", "stop")
	testing.expectf(t, code == 1 && strings.contains(out, "not signalling"), "%d: %s", code, out)
	time.sleep(200 * time.Millisecond)
	for child in ([]os.Process{victim, watcher}) {
		state, err := os.process_wait(child, 0)
		testing.expect(t, (err == os.General_Error.Timeout || err == nil) && !state.exited)
	}
	write_fixture(t, pid_file, actual_pid)
	testing.expect(t, strings.contains(checked_cli(t, cli, "watch", "stop"), "stopped"))
	state, err := os.process_wait(watcher, 5 * time.Second)
	testing.expect(t, err == nil && state.exited && !os.exists(pid_file))
}
