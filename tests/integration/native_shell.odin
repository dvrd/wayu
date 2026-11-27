package integration

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

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
	out := checked_cli(t, cli, "-c", code)
	testing.expect_value(t, out, "SAMPLESUFFIX\n$V\nSEED\nend")
	testing.expect_value(t, read_fixture(t, file), out)
	out = checked_cli(
		t,
		cli,
		"-c",
		`cd "$HOME"; sh -c 'echo out; echo err >&2' > both 2>&1; cat both`,
	)
	testing.expect_value(t, out, "out\nerr\n")
	stdout, stderr, rc := cli_streams(
		t,
		cli,
		"-c",
		`cd "$HOME"; cd missing 2> error; printf restored >&2; cat error`,
	)
	testing.expect_value(t, rc, 0)
	testing.expect(t, strings.contains(stdout, "cd: cannot enter missing"))
	testing.expect_value(t, stderr, "restored")
	env := checked_cli(t, cli, "-c", "printenv PATH")
	testing.expect(t, strings.has_prefix(env, fmt.tprintf("%s:", cli.home)))
	out = checked_cli(
		t,
		cli,
		"-c",
		`false && printf wrong; false || printf '%s\n' "$?"; true || printf wrong`,
	)
	testing.expect_value(t, out, "1\n")
	expect_exit(t, cli, 23, "-c", "exit 23; false")
	expect_exit(t, cli, 127, "-c", "wayu_missing_test_executable")
	expect_exit(t, cli, 2, "-c", "printf side-effect > \"$HOME/bad\"; printf |")
	expect_exit(t, cli, 2, "-c", `echo bad > "$HOME/bad"; if true; then echo missing-fi`)
	expect_exit(t, cli, 0, "-c", `if false; then printf wrong > "$HOME/bad"; fi`)
	testing.expect(t, !os.exists(fmt.tprintf("%s/bad", cli.home)))
	out = checked_cli(t, cli, "-c", "yes ok | head -n 100000 | wc -l")
	testing.expect_value(t, strings.trim_space(out), "100000")
	out = checked_cli(t, cli, "-c", "sleep 0.1 & jobs; fg")
	testing.expect(t, strings.contains(out, "Running sleep"))
}

@(test)
native_shell_entry_points :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)

	sh := cli
	sh.binary = "/bin/sh"
	out, err, status := cli_streams(
		t,
		sh,
		"-c",
		`printf '%s\n' 'export FIRST=hello' 'echo "$FIRST world"' 'exit 17' | "$1"`,
		"pipe-to-wayu",
		cli.binary,
	)
	testing.expect_value(t, status, 17)
	testing.expect_value(t, out, "hello world\n")
	testing.expect_value(t, err, "")

	expect_exit(t, cli, 64, "shell")
	expect_exit(t, cli, 64, "shell", "run", "exit 0")
	expect_exit(t, cli, 64, "-c")
	testing.expect_value(t, checked_cli(t, cli, "-c", ""), "")
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
	out := checked_cli(t, cli, "-c", "from_dir 'one two'; from_file; shared")
	testing.expect_value(t, out, "dir-from_dir one two\nfile-from_file\nmanaged\n")
	expect_exit(t, cli, 127, "-c", "ignored_file")
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
			"-c",
			fmt.tprintf(`export NATIVE_VALUE=shared; %s "one two" "it's three" ""`, name),
		)
		testing.expect_value(t, out, "<one two>\n<it's three>\n<>\n<shared>\n")
	}
}

@(test)
native_jump_tool_config :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)
	config := fmt.tprintf("%s/.config/wayu", cli.home)
	dest := fmt.tprintf("%s/project with spaces", cli.home)
	testing.expect_value(t, os.make_directory_all(config), nil)
	testing.expect_value(t, os.make_directory_all(dest), nil)
	bin := fmt.tprintf("%s/zoxide", cli.home)
	write_fixture(t, bin, "#!/bin/sh\ntouch \"$HOME/invoked-zoxide\"\nexit 42\n")
	testing.expect_value(t, os.chmod(bin, {.Read_User, .Write_User, .Execute_User}), nil)
	set_cli_env(&cli, "PATH", fmt.tprintf("%s:/usr/bin:/bin", cli.home))
	file := fmt.tprintf("%s/wayu.toml", config)
	write_fixture(t, file, "[tools]\nzoxide = { args = \"init zsh\" }\n")
	sh := cli
	sh.binary = "/bin/sh"
	home := strings.trim_space(checked_cli(t, sh, "-c", `cd "$HOME" && pwd -P`))
	physical_dest := fmt.tprintf("%s/project with spaces", home)
	out := checked_cli(
		t,
		cli,
		"-c",
		`z; cd "$HOME/project with spaces"; z -; z project spaces; pwd; z -; pwd`,
	)
	testing.expect_value(t, out, fmt.tprintf("%s\n%s\n", physical_dest, home))
	expect_exit(t, cli, 1, "-c", "z missing")
	testing.expect(t, !os.exists(fmt.tprintf("%s/invoked-zoxide", cli.home)))
	write_fixture(t, file, "[tools]\nzoxide = { args = \"init zsh --cmd jump --hook none\" }\n")
	out = checked_cli(t, cli, "-c", "jump project spaces; pwd")
	testing.expect_value(t, out, fmt.tprintf("%s\n", physical_dest))
	expect_exit(t, cli, 127, "-c", "z")
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
		"-c",
		`cd "$HOME/alpha/project"; cd "$HOME/beta/project"; cd "$HOME/alpha/project"; cd "$HOME"`,
	)
	out := checked_cli(t, cli, "-c", `z PROJECT && pwd; z beta proj && pwd`)
	lines := strings.split(strings.trim_space(out), "\n", context.temp_allocator)
	testing.expect_value(t, len(lines), 2)
	testing.expect(t, strings.has_suffix(lines[0], "/alpha/project"))
	testing.expect(t, strings.has_suffix(lines[1], "/beta/project"))
	expect_exit(t, cli, 1, "-c", "z absent-directory")

	// Earlier releases persisted integer counts and nanosecond timestamps.
	path := fmt.tprintf("%s/.local/share/wayu/directories.json", cli.home)
	now := time.to_unix_nanoseconds(time.now())
	write_fixture(
		t,
		path,
		fmt.tprintf(
			`{{"%s/alpha/project":{{"count":40,"last_visit":1}},"%s/beta/project":{{"count":3,"last_visit":%d}}}}`,
			cli.home,
			cli.home,
			now,
		),
	)
	testing.expect(
		t,
		strings.has_suffix(
			strings.trim_space(checked_cli(t, cli, "warp", "project")),
			"/beta/project",
		),
	)
	out = checked_cli(t, cli, "-c", "wayu warp project && pwd")
	testing.expect(t, strings.has_suffix(strings.trim_space(out), "/beta/project"))
	expect_exit(t, cli, 1, "-c", "wayu warp absent-directory")
	out = checked_cli(t, cli, "-c", "z project && pwd")
	testing.expectf(
		t,
		strings.has_suffix(strings.trim_space(out), "/beta/project"),
		"jump output %q; stored visits %s",
		out,
		read_fixture(t, path),
	)
}

@(test)
warp_shell_init_visits :: proc(t: ^testing.T) {
	for shell in ([]string{"zsh", "bash", "fish"}) {
		cli := new_cli(t)
		defer os.remove_all(cli.home)
		sh := cli
		sh.binary = "/bin/sh"
		exe, found := run_cli(t, sh, "-c", `command -v "$1"`, "which", shell)
		if found != 0 {
			continue
		}
		sh.binary = strings.trim_space(exe)
		checked_cli(t, cli, "init", "--shell", shell)
		dir := fmt.tprintf("%s/sample project", cli.home)
		testing.expect_value(t, os.make_directory_all(dir), nil)
		source_core := fmt.tprintf(`source "$HOME/.local/share/wayu/core.%s"; `, shell)
		prompt := "_wayu_paths_sync; " if shell == "bash" else ""
		code := strings.concatenate(
			{
				source_core,
				`cd "$HOME/sample project"; `,
				prompt,
				source_core,
				`cd "$HOME"; `,
				prompt,
				"wayu warp project && pwd; ",
				prompt,
				prompt,
			},
			context.temp_allocator,
		)
		option := "-f" if shell == "zsh" else "--norc" if shell == "bash" else "--no-config"
		out, err, status := cli_streams(t, sh, option, "-ic", code)
		testing.expectf(
			t,
			status == 0 && strings.trim_space(out) == dir,
			"%s: %s %s",
			shell,
			out,
			err,
		)
		data := read_fixture(t, fmt.tprintf("%s/.local/share/wayu/directories.json", cli.home))
		visits: map[string]struct {
			count:      f64,
			last_visit: i64,
		}
		testing.expect_value(
			t,
			json.unmarshal(transmute([]u8)data, &visits, allocator = context.temp_allocator),
			nil,
		)
		testing.expect_value(t, visits[dir].count, 2)
		testing.expect_value(t, visits[cli.home].count, 1)
	}
}

@(test)
native_shell_language :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)

	checked_cli(t, cli, "init", "--shell", "zsh")
	write_fixture(t, fmt.tprintf("%s/.config/wayu/login.wayu", cli.home), "login_mode=yes")
	out := checked_cli(
		t,
		cli,
		"-lc",
		`mkcd() { mkdir -p "$1" && cd "$1"; }
mkcd "$HOME/dir with spaces"
basename "$PWD"
echo "${login_mode:-missing}"
name=outer
name=inner printenv name
if printenv name; then echo leaked; elif test "$name" = outer; then echo local; fi
export name
printenv name
show() { for item in "$@"; do echo "$item"; done; return 7; }
show 'two words' three
echo "$?"
n=yes
until test "$n" = no; do n=no; done
while test "$n" = no; do n=done; done
echo "$n"
value=$(printf 'a b\n\n')
echo "${value:-$(echo wrong)}" "${missing:-$(echo fallback)}"
type mkcd
command -v cd
where mkcd
for x in $(printf 'a b'); do echo "$x"; done`,
	)
	testing.expect_value(
		t,
		out,
		"dir with spaces\nyes\ninner\nlocal\nouter\ntwo words\nthree\n7\ndone\na b fallback\nmkcd is a function\ncd\nmkcd is a function\na\nb\n",
	)
	testing.expect_value(
		t,
		checked_cli(
			t,
			cli,
			"-lc",
			`echo "$0:$#:$1"; for x in a b c; do if test "$x" = a; then continue; fi; echo "$x"; break; done`,
			"script",
			"arg",
		),
		"script:1:arg\nb\n",
	)
	expect_exit(t, cli, 1, "-c", "v=$(false)")
	expect_exit(t, cli, 1, "-c", "command -v wayu_missing_command_xyz")
}

@(test)
native_script_files :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)

	path := fmt.tprintf("%s/a script.wy", cli.home)
	body := `type cd
printf '<%s>\n' "$0" "$@"
exit 19`
	write_fixture(t, path, body)
	out, err, status := cli_streams(t, cli, path, "--help", "", "a b")
	testing.expect_value(t, status, 19)
	testing.expect_value(t, err, "")
	testing.expect_value(
		t,
		out,
		fmt.tprintf("cd is a shell builtin\n<%s>\n<--help>\n<>\n<a b>\n", path),
	)
	expect_exit(t, cli, 126, "-c", `cd "$HOME"; "./a script.wy"`)
	testing.expect_value(t, os.symlink(cli.binary, fmt.tprintf("%s/wayu", cli.home)), nil)
	set_cli_env(&cli, "PATH", fmt.tprintf("%s:/usr/bin:/bin", cli.home))
	write_fixture(t, path, fmt.tprintf("#!/usr/bin/env wayu\n%s", body))
	testing.expect_value(t, os.chmod(path, {.Read_User, .Execute_User}), nil)
	out, err, status = cli_streams(
		t,
		cli,
		"-c",
		`cd "$HOME"; "./a script.wy" 'x y' > result; exit "$?"`,
	)
	testing.expect_value(t, status, 19)
	testing.expect_value(t, err, "")
	testing.expect_value(
		t,
		read_fixture(t, fmt.tprintf("%s/result", cli.home)),
		"cd is a shell builtin\n<./a script.wy>\n<x y>\n",
	)

	expect_exit(t, cli, 66, fmt.tprintf("%s/missing.wy", cli.home))

	// execvp uses /bin/sh for executable text without a shebang. Keep
	// interpreters off PATH so accidental suffix lookups are observable.
	set_cli_env(&cli, "PATH", cli.home)
	for suffix in ([]string{"wy", "sh", "bash", "zsh", "fish", "nu"}) {
		script := fmt.tprintf("setup.%s", suffix)
		filename := fmt.tprintf("%s/%s", cli.home, script)
		write_fixture(t, filename, `case "$1" in "x y") printf ok;; *) exit 9;; esac`)
		command := fmt.tprintf(`cd "$HOME"; ./%s 'x y'`, script)
		expect_exit(t, cli, 126, "-c", command)
		expect_exit(t, cli, 126, "-c", script)
		testing.expect_value(t, os.chmod(filename, {.Read_User, .Execute_User}), nil)
		testing.expect_value(t, checked_cli(t, cli, "-c", command), "ok")
		testing.expect_value(t, checked_cli(t, cli, "-c", fmt.tprintf("%s 'x y'", script)), "ok")
	}

	override := fmt.tprintf("%s/override.zsh", cli.home)
	write_fixture(t, override, "#!/bin/sh\nprintf 'shebang won'\n")
	testing.expect_value(t, os.chmod(override, {.Read_User, .Execute_User}), nil)
	testing.expect_value(t, checked_cli(t, cli, "-c", "override.zsh"), "shebang won")
}
