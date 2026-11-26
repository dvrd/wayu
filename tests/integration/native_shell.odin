package integration

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
native_shell :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)
	file := fmt.tprintf("%s/output", cli.home)
	checked_cli(t, cli, "init", "--shell", "zsh")
	checked_cli(t, cli, "alias", "add", "shout", "tr a-z A-Z")
	checked_cli(t, cli, "const", "add", "EXAMPLE", "seed")
	checked_cli(t, cli, "path", "add", cli.home)
	code := `cd "$HOME"; export V=sample; printf '%s\n' "$V"'suffix' '$V' "$EXAMPLE" | shout > output; printf end >> output; cat < output`
	out := checked_cli(t, cli, "shell", "run", code)
	testing.expect_value(t, out, "SAMPLESUFFIX\n$V\nSEED\nend")
	testing.expect_value(t, read_fixture(t, file), out)
	out = checked_cli(
		t,
		cli,
		"shell",
		"run",
		`cd "$HOME"; sh -c 'echo out; echo err >&2' > both 2>&1; cat both`,
	)
	testing.expect_value(t, out, "out\nerr\n")
	stdout, stderr, rc := cli_streams(
		t,
		cli,
		"shell",
		"run",
		`cd "$HOME"; cd missing 2> error; printf restored >&2; cat error`,
	)
	testing.expect_value(t, rc, 0)
	testing.expect(t, strings.contains(stdout, "cd: cannot enter missing"))
	testing.expect_value(t, stderr, "restored")
	env := checked_cli(t, cli, "shell", "run", "printenv PATH")
	testing.expect(t, strings.has_prefix(env, fmt.tprintf("%s:", cli.home)))
	out = checked_cli(
		t,
		cli,
		"shell",
		"run",
		`false && printf wrong; false || printf '%s\n' "$?"; true || printf wrong`,
	)
	testing.expect_value(t, out, "1\n")
	expect_exit(t, cli, 23, "shell", "run", "exit 23; false")
	expect_exit(t, cli, 127, "shell", "run", "wayu_missing_test_executable")
	expect_exit(t, cli, 2, "shell", "run", "printf side-effect > \"$HOME/bad\"; printf |")
	expect_exit(t, cli, 2, "shell", "run", `if false; then printf wrong > "$HOME/bad"; fi`)
	testing.expect(t, !os.exists(fmt.tprintf("%s/bad", cli.home)))
	out = checked_cli(t, cli, "shell", "run", "yes ok | head -n 100000 | wc -l")
	testing.expect_value(t, strings.trim_space(out), "100000")
	out = checked_cli(t, cli, "shell", "run", "sleep 0.1 & jobs; fg")
	testing.expect(t, strings.contains(out, "Running sleep"))
}

@(test)
native_managed_functions :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)
	dir := fmt.tprintf("%s/.local/share/wayu/functions", cli.home)
	testing.expect_value(t, os.make_directory_all(dir), nil)
	for shell in ([]string{"bash", "zsh", "fish"}) {
		sh := cli
		sh.binary = "/bin/sh"
		_, code := run_cli(t, sh, "-c", `command -v "$1"`, "which", shell)
		if code != 0 {
			continue
		}
		name := fmt.tprintf("from_%s", shell)
		body := strings.concatenate(
			{name, `() { printf '<%s>\n' "$@" "$NATIVE_VALUE"; }`, "\n"},
			context.temp_allocator,
		)
		if shell == "fish" {
			body = fmt.tprintf(
				"function %s\n printf '<%%s>\\n' $argv \"$NATIVE_VALUE\"\nend\n",
				name,
			)
		}
		write_fixture(t, fmt.tprintf("%s/%s.%s", dir, name, shell), body)
		out := checked_cli(
			t,
			cli,
			"shell",
			"run",
			fmt.tprintf(`export NATIVE_VALUE=shared; %s "one two" "it's three" ""`, name),
		)
		testing.expect_value(t, out, "<one two>\n<it's three>\n<>\n<shared>\n")
	}
}
