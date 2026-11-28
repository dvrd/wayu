package integration

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
native_pipeline_failures :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)

	expect_exit(t, cli, 7, "-c", "sh -c 'exit 7' | true")
	expect_exit(t, cli, 6, "-c", "sh -c 'exit 9' | sh -c 'exit 6' | true")
	expect_exit(t, cli, 141, "-c", "sh -c 'exit 141' | true")
	expect_exit(t, cli, 141, "-c", "true | sh -c 'kill -PIPE $$'")
	expect_exit(t, cli, 0, "-c", "yes | head -n 1 > /dev/null")
	expect_exit(t, cli, 0, "-c", "producer() { yes; }; producer | head -n 1 > /dev/null")
	expect_exit(t, cli, 141, "-c", "producer() { return 141; }; producer | true")
	expect_exit(t, cli, 17, "-c", "sh -c 'exit 17' | true & wait %1")
	expect_exit(t, cli, 19, "-c", "sh -c 'exit 19' | true & sleep 0.1; jobs; wait %1")
	expect_exit(t, cli, 0, "-c", "yes | head -n 1 > /dev/null & wait %1")
	expect_exit(t, cli, 8, "-c", "sh -c 'sleep 0.1; exit 8' | true & fg")

	stdout, stderr, status := cli_streams(
		t,
		cli,
		"-c",
		`a() { false; }; b() { sh -c 'exit 8'; }; a | b | true`,
	)
	testing.expect_value(t, status, 8)
	testing.expect_value(t, stdout, "")
	testing.expect_value(t, strings.count(stderr, "exited with status"), 1)
	testing.expect(t, strings.contains(stderr, "b exited with status 8"))
	stdout, stderr, status = cli_streams(t, cli, "-c", `a() { false; }; a | true || echo handled`)
	testing.expect_value(t, status, 0)
	testing.expect_value(t, stdout, "handled\n")
	testing.expect_value(t, stderr, "")
}

@(test)
native_exec_failures :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)

	write_fixture(t, fmt.tprintf("%s/a script.wy", cli.home), "echo ok")
	stdout, stderr, status := cli_streams(t, cli, "-c", `cd "$HOME"; "./a script.wy"`)
	testing.expect_value(t, status, 126)
	testing.expect_value(t, stdout, "")
	testing.expect(t, strings.contains(stderr, "permission denied"))
	testing.expect(t, strings.contains(stderr, "wayu './a script.wy'"))

	stdout, stderr, status = cli_streams(t, cli, "-c", "wayu_missing_test_command_867")
	testing.expect_value(t, status, 127)
	testing.expect_value(t, stdout, "")
	testing.expect(
		t,
		strings.contains(stderr, "cannot find the command wayu_missing_test_command_867"),
	)

	stdout, stderr, status = cli_streams(
		t,
		cli,
		"-c",
		"wayu_missing_test_command_867 || echo recovered",
	)
	testing.expect_value(t, status, 0)
	testing.expect_value(t, stdout, "recovered\n")
	testing.expect_value(t, stderr, "")
}
