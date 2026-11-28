package integration

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
native_failure_locations :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)

	path := fmt.tprintf("%s/deploy.wy", cli.home)
	write_fixture(t, path, "# setup\n\necho output\nsh -c 'exit 47'\necho skipped")
	out, err, status := cli_streams(t, cli, path)
	testing.expect_value(t, status, 47)
	testing.expect_value(t, out, "output\n")
	testing.expect(
		t,
		strings.contains(err, fmt.tprintf("%s, line 4: sh exited with status 47", path)),
	)

	lib := fmt.tprintf("%s/library.wy", cli.home)
	write_fixture(t, lib, "# calls\nwork() {\n  sh -c 'echo detail >&2; exit 47'\n}")
	write_fixture(t, path, "source \"$HOME/library.wy\"\nwork\necho skipped")
	out, err, status = cli_streams(t, cli, path)
	testing.expect_value(t, status, 47)
	testing.expect_value(t, out, "")
	testing.expect(t, strings.contains(err, "detail\n"))
	testing.expect(
		t,
		strings.contains(err, fmt.tprintf("%s, line 3: sh exited with status 47", lib)),
	)
	testing.expect_value(t, strings.count(err, "exited with status"), 1)

	out, err, status = cli_streams(t, cli, "-c", "false || echo handled")
	testing.expect_value(t, status, 0)
	testing.expect_value(t, out, "handled\n")
	testing.expect_value(t, err, "")
}
