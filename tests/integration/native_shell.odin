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
native_alias_sources :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)

	checked_cli(t, cli, "init", "--shell", "zsh")
	checked_cli(t, cli, "alias", "add", "shared", "echo managed")
	for dir in ([]string{"patterns/from_dir", "patterns/shared", "flat"}) {
		testing.expect_value(t, os.make_directory_all(fmt.tprintf("%s/%s", cli.home, dir)), nil)
	}

	for file in ([]string{"patterns/ignored_file", "flat/from_file", "flat/from_dir"}) {
		write_fixture(t, fmt.tprintf("%s/%s", cli.home, file), "")
	}

	write_fixture(
		t,
		fmt.tprintf("%s/.config/wayu/alias-sources.conf", cli.home),
		"dir ~/missing echo missing\ndir ~/patterns echo dir-{name}\ndir ~/flat echo file-{name}\n",
	)
	out := checked_cli(t, cli, "shell", "run", "from_dir 'one two'; from_file; shared")
	testing.expect_value(t, out, "dir-from_dir one two\nfile-from_file\nmanaged\n")
	expect_exit(t, cli, 127, "shell", "run", "ignored_file")
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

@(test)
native_zoxide :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)
	config := fmt.tprintf("%s/.config/wayu", cli.home)
	dest := fmt.tprintf("%s/project with spaces", cli.home)
	testing.expect_value(t, os.make_directory_all(config), nil)
	testing.expect_value(t, os.make_directory_all(dest), nil)
	bin := fmt.tprintf("%s/zoxide", cli.home)
	write_fixture(
		t,
		bin,
		`#!/bin/sh
case "$1" in
add) printf '%s\n' "$3" >> "$HOME/visits" ;;
query) [ "$2" = --exclude ] && [ "$4" = -- ] && [ "$5" = project ] && [ "$6" = words ] || exit 4
       printf '%s/project with spaces\n' "$HOME" ;;
esac
`,
	)
	testing.expect_value(t, os.chmod(bin, {.Read_User, .Write_User, .Execute_User}), nil)
	set_cli_env(&cli, "PATH", fmt.tprintf("%s:/usr/bin:/bin", cli.home))
	file := fmt.tprintf("%s/wayu.toml", config)
	write_fixture(t, file, "[tools]\nzoxide = { args = \"init zsh\" }\n")
	sh := cli
	sh.binary = "/bin/sh"
	home := strings.trim_space(checked_cli(t, sh, "-c", `cd "$HOME" && pwd -P`))
	physical_dest := fmt.tprintf("%s/project with spaces", home)
	out := checked_cli(t, cli, "shell", "run", "z; z project words; pwd; z -; pwd")
	testing.expect_value(t, out, fmt.tprintf("%s\n%s\n", physical_dest, home))
	testing.expect(t, !os.exists(fmt.tprintf("%s/visits", cli.home)))
	expect_exit(t, cli, 4, "shell", "run", "z missing")
	write_fixture(t, file, "[tools]\nzoxide = { args = \"init zsh --cmd jump --hook none\" }\n")
	out = checked_cli(t, cli, "shell", "run", "jump project words; pwd")
	testing.expect_value(t, out, fmt.tprintf("%s\n", physical_dest))
	expect_exit(t, cli, 127, "shell", "run", "z")
}

@(test)
native_jump_without_zoxide :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)
	set_cli_env(&cli, "PATH", "/usr/bin:/bin")
	for dir in ([]string{"alpha/project", "beta/project"}) {
		testing.expect_value(t, os.make_directory_all(fmt.tprintf("%s/%s", cli.home, dir)), nil)
	}
	checked_cli(
		t,
		cli,
		"shell",
		"run",
		`cd "$HOME/alpha/project"; cd "$HOME/beta/project"; cd "$HOME/alpha/project"; cd "$HOME"`,
	)
	out := checked_cli(t, cli, "shell", "run", `z PROJECT && pwd; z beta proj && pwd`)
	lines := strings.split(strings.trim_space(out), "\n", context.temp_allocator)
	testing.expect_value(t, len(lines), 2)
	testing.expect(t, strings.has_suffix(lines[0], "/alpha/project"))
	testing.expect(t, strings.has_suffix(lines[1], "/beta/project"))
	expect_exit(t, cli, 1, "shell", "run", "z absent-directory")
}
