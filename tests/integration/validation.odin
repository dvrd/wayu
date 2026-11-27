package integration

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
validation :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)
	expect_exit(t, cli, 0, "init", "--shell", "zsh")
	for c in ([]struct {
			kind, name, message: string,
		} {
			{"alias", "if", "reserved word 'if'"},
			{"alias", "my;alias", "invalid character ';'"},
			{"constants", "while", "reserved word 'while'"},
		}) {
		out, code := run_cli(t, cli, c.kind, "add", c.name, "value")
		testing.expectf(t, code == 65 && strings.contains(out, c.message), "%s: %s", c.name, out)
		store := read_store(t, cli) if os.exists(entries_path(cli)) else Fixture_Store{}
		_, count := named_value(store.aliases if c.kind == "alias" else store.env, c.name)
		testing.expect_value(t, count, 0)
	}
	out := checked_cli(t, cli, "constants", "add", "my_var", "value")
	val, count := named_value(read_store(t, cli).env, "my_var")
	testing.expect(
		t,
		strings.contains(out, "contains lowercase letters") && val == "value" && count == 1,
	)
	space := fmt.tprintf("%s/test dir", cli.home)
	testing.expect(t, os.make_directory_all(space) == nil)
	expect_exit(t, cli, 0, "path", "add", space)
	colon := fmt.tprintf("%s/co:lon", cli.home)
	dot := fmt.tprintf("%s/a:.", cli.home)
	for dir in ([]string{colon, dot, fmt.tprintf("%s/new\nline", cli.home)}) {
		testing.expect(t, os.make_directory_all(dir) == nil)
		expect_exit(t, cli, 65, "--shell", "zsh", "path", "add", dir)
	}
	store := read_store(t, cli)
	paths := make([dynamic]Fixture_Path, context.temp_allocator)
	append(&paths, Fixture_Path{"hand", dot})
	for p in store.paths {
		testing.expect(t, !has_any(p.dir, "co:lon", "a:."))
		append(&paths, p)
	}
	set_store(t, cli, paths = paths[:], aliases = store.aliases, env = store.env)
	_, _ = run_cli(t, cli, "--shell", "zsh", "build")
	data := fmt.tprintf("%s/.local/share/wayu", cli.home)
	sync := read_fixture(t, fmt.tprintf("%s/path_sync.zsh", data))
	testing.expect(t, !strings.contains(sync, "a:."))
	probe := cli
	probe.binary = "/bin/zsh"
	actual := checked_cli(
		t,
		probe,
		"-fc",
		`source "$1" >/dev/null 2>&1; print -rl -- $path`,
		"probe",
		fmt.tprintf("%s/core.zsh", data),
	)
	for line in strings.split_lines(actual, context.temp_allocator) {
		testing.expect(
			t,
			line != "." &&
			line != fmt.tprintf("%s/a", cli.home) &&
			line != fmt.tprintf("%s/co", cli.home),
		)
	}
	set_store(t, cli, paths = store.paths, aliases = store.aliases, env = store.env)
	for c in ([]struct {
			args: []string,
			text: string,
		} {
			{{"alias", "add", "myalias", "echo hello"}, "Alias added: myalias"},
			{{"constants", "add", "MY_CONSTANT", "value123"}, "Constant added: MY_CONSTANT"},
			{{"path", "add", "/usr/local/bin"}, "Added to PATH: /usr/local/bin"},
		}) {testing.expect(t, strings.contains(checked_cli(t, cli, ..c.args), c.text))}
	cfg := fmt.tprintf("%s/.config/wayu/wayu.toml", cli.home)
	write_fixture(
		t,
		cfg,
		"[shell]\ntype = \"zsh\"\n\n[settings]\nauto_backup = true\n\n[constants]\nX = \"1\"\n",
	)
	warn := checked_cli(t, cli, "toml", "validate")
	testing.expect(
		t,
		strings.contains(warn, "line 5: unknown key settings.auto_backup") &&
		strings.contains(warn, "line 7: unknown table [constants]"),
	)
	write_fixture(t, cfg, "[[paths]]\npath = \"/usr/bin\"\n")
	errout, code := run_cli(t, cli, "toml", "validate")
	testing.expect(
		t,
		code == 65 &&
		strings.contains(errout, "'wayu path add'") &&
		!strings.contains(errout, "migrate"),
	)
	write_fixture(t, cfg, "[shell]\ntype = \"zsh\"\n\n[env]\nX = \"1\"\n")
	errout, code = run_cli(t, cli, "toml", "validate")
	testing.expect(
		t,
		code == 65 &&
		strings.contains(errout, "line 4") &&
		strings.contains(errout, "'wayu const add'") &&
		strings.contains(errout, entries_path(cli)),
	)
}
