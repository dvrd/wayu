package integration

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
completions :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)
	expect_exit(t, cli, 0, "init", "--shell", "zsh")
	src := fmt.tprintf("%s/_src", cli.home)
	fixture := `#compdef testcomp
_testcomp() {
    _arguments '1:command:(init add remove list help)' '*::arg:->args'
}
_testcomp "$@"
`
	write_fixture(t, src, fixture)
	dir := fmt.tprintf("%s/.local/share/wayu/completions", cli.home)
	expect_exit(t, cli, 0, "completions", "add", "testcomp", src)
	testing.expect(t, os.exists(fmt.tprintf("%s/_testcomp", dir)))
	out := checked_cli(t, cli, "completions", "list")
	testing.expect(
		t,
		strings.contains(out, "Shell Completions") && strings.contains(out, "_testcomp"),
	)
	expect_exit(t, cli, 0, "completions", "add", "mycomp", src)
	testing.expect_value(t, read_fixture(t, fmt.tprintf("%s/_mycomp", dir)), fixture)
	out = checked_cli(t, cli, "completions", "list")
	testing.expect(t, strings.contains(out, "_testcomp") && strings.contains(out, "_mycomp"))
	expect_exit(t, cli, 0, "completions", "rm", "testcomp")
	testing.expect(t, !os.exists(fmt.tprintf("%s/_testcomp", dir)))
	out, _ = run_cli(t, cli, "completions", "rm", "nonexistent")
	testing.expect(t, strings.contains(out, "Completion not found"))
	code: int
	out, code = run_cli(
		t,
		cli,
		"completions",
		"add",
		"invalid",
		fmt.tprintf("%s/missing", cli.home),
	)
	testing.expect(t, code == 66 && strings.contains(out, "File not found"))
	out = checked_cli(t, cli, "completions", "help")
	testing.expect(
		t,
		strings.contains(out, "wayu completions") && strings.contains(out, "EXAMPLES"),
	)
	expect_exit(t, cli, 0, "completions", "rm", "mycomp")
	testing.expect(t, !has_any(checked_cli(t, cli, "completions", "list"), "_testcomp", "_mycomp"))

	expect_exit(t, cli, 0, "alias", "add", "gst", "git status")
	expect_exit(t, cli, 0, "const", "add", "DYN_CONST", "1")
	names := checked_cli(t, cli, "completions", "names", "alias")
	testing.expect(t, strings.contains(fmt.tprintf("\n%s\n", names), "\ngst\n"))
	bashfile := fmt.tprintf("%s/wayu.bash", cli.home)
	write_fixture(t, bashfile, checked_cli(t, cli, "completions", "bash"))
	probe := cli
	probe.binary = "/bin/bash"
	set_cli_env(&probe, "_WAYU_BIN", cli.binary)
	out = checked_cli(
		t,
		probe,
		"--norc",
		"-c",
		`source "$1"
t() { COMP_WORDS=("$@"); COMP_CWORD=$(( $# - 1 )); COMPREPLY=(); _wayu_completion; echo "${COMPREPLY[*]}"; }
t wayu alias rm ""
t wayu const get DYN
t wayu alias rm gst ""
t wayu alias ""
`,
		"probe",
		bashfile,
	)
	lines := strings.split_lines(out, context.temp_allocator)
	testing.expectf(
		t,
		len(lines) >= 4 &&
		strings.contains(fmt.tprintf(" %s ", lines[0]), " gst ") &&
		lines[1] == "DYN_CONST" &&
		lines[2] == "" &&
		strings.contains(fmt.tprintf(" %s ", lines[3]), " add ") &&
		!strings.contains(lines[3], "gst"),
		"bash: %s",
		out,
	)
	probe.binary = "/bin/sh"
	fish, found := run_cli(t, probe, "-c", "command -v fish")
	if found != 0 {
		return
	}
	probe.binary = strings.trim_space(fish)
	file := fmt.tprintf("%s/wayu.fish", cli.home)
	write_fixture(t, file, checked_cli(t, cli, "completions", "fish"))
	path, _ := os.lookup_env("PATH", context.temp_allocator)
	set_cli_env(&probe, "PATH", fmt.tprintf("%s:%s", filepath.dir(cli.binary), path))
	out = checked_cli(
		t,
		probe,
		"--no-config",
		"-c",
		`source "$argv[1]"; complete -C 'wayu alias rm '; echo ---; complete -C 'wayu alias rm gst '`,
		file,
	)
	first, sep, second := strings.partition(out, "---\n")
	has_gst := false
	for line in strings.split_lines(first, context.temp_allocator) {
		name, _, _ := strings.partition(line, "\t")
		if name == "gst" {
			has_gst = true
		}
	}
	testing.expectf(
		t,
		sep != "" &&
		has_gst &&
		!strings.contains(first, "Add an alias") &&
		!strings.contains(second, "gst"),
		"fish: %s",
		out,
	)
}
