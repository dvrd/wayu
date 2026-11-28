package integration

import "core:c"
import "core:fmt"
import "core:os"
import "core:sys/posix"
import "core:testing"

@(test)
native_retention_budgets :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)

	cfg := fmt.tprintf("%s/.config/wayu", cli.home)
	os.make_directory_all(cfg)
	write_fixture(
		t,
		fmt.tprintf("%s/wayu.toml", cfg),
		"[settings]\nundo_bytes=1\nhistory_entries=1\n",
	)
	fd, pid := start_native_pty(t, cli)
	defer {
		posix.close(fd)
		posix.kill(pid, .SIGKILL)
		status: c.int
		for posix.waitpid(pid, &status, {}) < 0 && posix.errno() == .EINTR {}
	}

	expect_text(t, fd, "wayu> ")
	send(t, fd, "echo retained\x1f\r")
	expect_text(t, fd, "\x1b[?2004lretained\r\n")
}
