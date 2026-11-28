package integration

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

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

	expect_exit(t, cli, 65, "-c", "echo \"$(yes)\"")
	expect_exit(t, cli, 65, "-c", "v=$(echo \"$(yes)\")")
	expect_exit(t, cli, 0, "-c", "yes | head -c 20000 > /dev/null")
	out, _, status := cli_streams(t, cli, "-c", "v=$(yes) || echo recovered; echo working")
	testing.expect_value(t, status, 0)
	testing.expect_value(t, out, "recovered\nworking\n")

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
}
