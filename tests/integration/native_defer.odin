package integration

import "core:fmt"
import "core:os"
import "core:testing"

@(test)
native_deferred_cleanup :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)

	file := fmt.tprintf("%s/helpers.wy", cli.home)
	write_fixture(t, file, `defer echo sourced`)
	out, err, status := cli_streams(
		t,
		cli,
		"-c",
		`defer echo outer
f() { defer printf '[%s]\n' "$1"; return 0; }
f "function argument"
source "$HOME/helpers.wy"
file="$HOME/file one"
value='once; exit 77'
defer printf '%s' "$value" >"$file"
value=changed
file="$HOME/other"
defer echo last
echo body
exit 19`,
	)
	testing.expect_value(t, status, 19)
	testing.expect_value(t, out, "[function argument]\nsourced\nbody\nlast\nouter\n")
	testing.expect_value(t, read_fixture(t, fmt.tprintf("%s/file one", cli.home)), "once; exit 77")

	out, err, status = cli_streams(
		t,
		cli,
		"-c",
		`defer echo remaining; defer sh -c 'exit 7'; defer echo first; true`,
	)
	testing.expect_value(t, status, 7)
	testing.expect_value(t, out, "first\nremaining\n")
	testing.expect(t, err != "")

	out, _, status = cli_streams(
		t,
		cli,
		"-c",
		`defer echo remaining; defer sh -c 'exit 7'; sh -c 'exit 19'; echo unreachable`,
	)
	testing.expect_value(t, status, 19)
	testing.expect_value(t, out, "remaining\n")

	out, _, status = cli_streams(
		t,
		cli,
		"-c",
		`defer echo outer; value=$(defer printf captured); echo "value=$value"`,
	)
	testing.expect_value(t, status, 0)
	testing.expect_value(t, out, "value=captured\nouter\n")
	out, err, status = cli_streams(t, cli, "-c", `f() { defer false; true; }; f || echo recovered`)
	testing.expect_value(t, status, 0)
	testing.expect_value(t, err, "")
	testing.expect_value(t, out, "recovered\n")

	out, _, status = cli_streams(
		t,
		cli,
		"-c",
		`defer echo before; defer echo never >"$(sh -c 'exit 16')"; echo unreachable`,
	)
	testing.expect_value(t, status, 16)
	testing.expect_value(t, out, "before\n")

	keyword := fmt.tprintf("%s/case", cli.home)
	write_fixture(t, keyword, "#!/bin/sh\nprintf '<%s>\\n' \"$1\"")
	testing.expect_value(t, os.chmod(keyword, {.Read_User, .Execute_User}), nil)
	set_cli_env(&cli, "PATH", fmt.tprintf("%s:/bin:/usr/bin", cli.home))
	out = checked_cli(t, cli, "-c", `name=case; defer "$name" '$(echo altered); exit 77'`)
	testing.expect_value(t, out, "<$(echo altered); exit 77>\n")
}

@(test)
native_deferred_stdin :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)

	path := fmt.tprintf("%s/input", cli.home)
	for example in ([]struct {
			body:   string,
			status: int,
		} {
			{"defer echo cleaned\necho body\n", 0},
			{"defer echo cleaned\necho body\nsh -c 'exit 17'\necho unreachable\n", 17},
		}) {
		write_fixture(t, path, example.body)
		state, out, _, err := os.process_exec(
			{
				command = []string{"/bin/sh", "-c", `exec "$1" <"$2"`, "sh", cli.binary, path},
				env = cli.env,
			},
			context.temp_allocator,
		)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, state.exit_code, example.status)
		testing.expect_value(t, string(out), "body\ncleaned\n")
	}
}
