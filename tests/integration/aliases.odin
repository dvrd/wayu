package integration

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
aliases :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)
	expect_exit(t, cli, 0, "init", "--shell", "zsh")
	cases := []Named_Value {
		{"ll", "ls -la"},
		{"greet", `echo "Hello, World!"`},
		{"gco", "git checkout"},
		{"findlarge", "find . -type f -size +100M | sort -h"},
		{"multitest", "cd /tmp; ls -la; pwd"},
		{"lsd", "ls -la | grep ^d"},
		{"persistent1", "echo test1"},
		{"persistent2", "echo test2"},
	}
	for c in cases {expect_exit(t, cli, 0, "alias", "add", c.name, c.value)}
	rows := read_store(t, cli).aliases
	for c in cases {
		val, count := named_value(rows, c.name)
		testing.expectf(
			t,
			val == c.value && count == 1,
			"stored %s: %q (%d rows)",
			c.name,
			val,
			count,
		)
	}
	testing.expect(t, strings.contains(checked_cli(t, cli, "alias", "list"), "ll"))
	expect_exit(t, cli, 0, "alias", "rm", "ll")
	_, removed := named_value(read_store(t, cli).aliases, "ll")
	testing.expect_value(t, removed, 0)
	expect_exit(t, cli, 0, "alias", "add", "myalias", "echo first")
	expect_exit(t, cli, 0, "alias", "add", "myalias", "echo second")
	val, count := named_value(read_store(t, cli).aliases, "myalias")
	testing.expect(t, val == "echo second" && count == 1)
	for c in ([]Named_Value {
			{"-bad", "cannot start with '-'"},
			{"a b", "invalid character"},
			{"if", "reserved"},
		}) {
		out, code := run_cli(t, cli, "alias", "add", "--", c.name, "echo test")
		testing.expectf(t, code == 65 && strings.contains(out, c.value), "%s: %s", c.name, out)
	}
	expect_exit(t, cli, 0, "alias", "add", "good-name", "echo test")
	out, code := run_cli(t, cli, "alias", "add", "testalias", "")
	testing.expect(t, code != 0 && has_any(out, "cannot be empty", "Missing required arguments"))

	set_store(t, cli, aliases = {{"gs", "git status"}, {"ga", "git add"}})
	list := checked_cli(t, cli, "alias", "list")
	testing.expect(t, strings.contains(list, "gs") && strings.contains(list, "git status"))
	testing.expect_value(
		t,
		strings.trim_space(checked_cli(t, cli, "alias", "get", "ga")),
		"git add",
	)
	set_store(t, cli, aliases = {{"ll", "ls -la"}})
	cfg := fmt.tprintf("%s/.config/wayu/wayu.toml", cli.home)
	before := read_fixture(t, cfg)
	expect_exit(t, cli, 0, "alias", "add", "gs", "git status")
	after := read_store(t, cli).aliases
	testing.expect(
		t,
		len(after) == 2 &&
		after[0] == Named_Value{"ll", "ls -la"} &&
		after[1] == Named_Value{"gs", "git status"},
	)
	testing.expect_value(t, read_fixture(t, cfg), before)
	set_store(t, cli, aliases = {{"rmme", "echo bye"}, {"keepme", "echo stay"}})
	expect_exit(t, cli, 0, "alias", "rm", "rmme")
	after = read_store(t, cli).aliases
	testing.expect(t, len(after) == 1 && after[0] == Named_Value{"keepme", "echo stay"})

	expect_exit(t, cli, 0, "alias", "add", "updme", "echo old_value")
	expect_exit(t, cli, 0, "alias", "add", "updme", "echo new_value")
	core := fmt.tprintf("%s/.local/share/wayu/core.zsh", cli.home)
	generated := read_fixture(t, core)
	testing.expect(
		t,
		strings.contains(generated, "new_value") && !strings.contains(generated, "old_value"),
	)
	expect_exit(t, cli, 0, "alias", "add", "glf", "git log --format='%h'")
	expect_exit(t, cli, 0, "alias", "add", "other_after_glf", "ls")
	testing.expect_value(
		t,
		strings.trim_space(checked_cli(t, cli, "alias", "get", "glf")),
		"git log --format='%h'",
	)
	expect_exit(t, cli, 0, "alias", "add", "gpf", "git", "push", "-f")
	expect_exit(t, cli, 0, "alias", "add", "gn", "--", "-n")
	testing.expect_value(
		t,
		strings.trim_space(checked_cli(t, cli, "alias", "get", "gpf")),
		"git push -f",
	)
	testing.expect_value(t, strings.trim_space(checked_cli(t, cli, "alias", "get", "gn")), "-n")
	for n in ([]string {
			"..",
			"g.st",
			"1x",
			"cd",
			"cat",
		}) {expect_exit(t, cli, 0, "alias", "add", n, fmt.tprintf("echo %s-ran", n))}
	expect_exit(t, cli, 65, "alias", "add", "a/b", "ls")
	expect_exit(t, cli, 65, "alias", "add", "if", "ls")
	expect_exit(t, cli, 65, "alias", "add", "local", "ls")
	bad, st := run_cli(t, cli, "alias", "add", "badutf", "a\xffb")
	testing.expectf(t, st == 65 && strings.count(bad, "ERROR") == 1, "%s", bad)
	shell_cli := cli
	shell_cli.binary = "/bin/zsh"
	zsh_out := checked_cli(
		t,
		shell_cli,
		"-fc",
		`source "$1" >/dev/null 2>&1; eval 'g.st'; eval '..'; eval '1x'; eval cd; eval cat`,
		"zsh",
		core,
	)
	testing.expect_value(
		t,
		strings.trim_space(zsh_out),
		"g.st-ran\n..-ran\n1x-ran\ncd-ran\ncat-ran",
	)
	help := checked_cli(t, cli, "alias", "help")
	testing.expect(t, strings.contains(help, "EXAMPLES") && strings.contains(help, "wayu alias"))
}
