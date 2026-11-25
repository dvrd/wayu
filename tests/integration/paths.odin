package integration

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

path_rows :: proc(t: ^testing.T, cli: CLI, dir: string, key: string = "") -> int {
	count := 0
	for row in read_store(t, cli).paths {
		if row.dir == dir && (key == "" || row.key == key) {
			count += 1
		}
	}
	return count
}

@(test)
path_entries :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)
	checked_cli(t, cli, "init", "--shell", "zsh")
	scratch, err := os.make_directory_temp("/tmp", "wp*", context.temp_allocator)
	if err != nil {
		testing.fail_now(t, "create path fixture")
	}
	defer os.remove_all(scratch)
	dirs := make([dynamic]string, context.temp_allocator)
	for name in ([]string{"zeta", "alpha", "mid", "with spaces"}) {
		dir := fmt.tprintf("%s/%s", scratch, name)
		testing.expect_value(t, os.make_directory(dir), nil)
		checked_cli(t, cli, "path", "add", dir)
		append(&dirs, dir)
	}
	rows := read_store(t, cli).paths
	if testing.expect_value(t, len(rows), len(dirs)) {
		for row, i in rows {testing.expect_value(t, row.dir, dirs[i])}
	}
	list := checked_cli(t, cli, "path", "list")
	testing.expect(t, strings.contains(list, dirs[0]))
	checked_cli(t, cli, "path", "add", dirs[0])
	testing.expect_value(t, path_rows(t, cli, dirs[0]), 1)
	checked_cli(t, cli, "path", "rm", dirs[0])
	testing.expect_value(t, path_rows(t, cli, dirs[0]), 0)
	link := fmt.tprintf("%s/link", scratch)
	testing.expect_value(t, os.symlink(dirs[0], link), nil)
	checked_cli(t, cli, "path", "add", link)
	missing := fmt.tprintf("%s/missing", scratch)
	out, code := run_cli(t, cli, "path", "add", missing)
	testing.expect(
		t,
		code != 0 && has_any(out, "does not exist", "not found", "Could not resolve"),
	)
	out, code = run_cli(t, cli, "path", "rm", missing)
	testing.expect(
		t,
		code == 65 && strings.contains(out, fmt.tprintf("PATH entry not found: %s", missing)),
	)
	file := fmt.tprintf("%s/file", scratch)
	write_fixture(t, file, "data")
	out, code = run_cli(t, cli, "path", "add", file)
	testing.expect(
		t,
		code == 65 && strings.contains(out, "Not a directory") && path_rows(t, cli, file) == 0,
	)
	out = checked_cli(t, cli, "path", "help")
	testing.expect(t, strings.contains(out, "EXAMPLES") && strings.contains(out, "wayu path"))
}

@(test)
path_resolution :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)
	checked_cli(t, cli, "init", "--shell", "zsh")
	root, err := os.get_working_directory(context.temp_allocator)
	testing.expect_value(t, err, nil)
	parent_arg := fmt.tprintf("../%s/tests", filepath.base(root))
	for pair in ([][2]string {
			{".", root},
			{"./bin", fmt.tprintf("%s/bin", root)},
			{"tests/unit", fmt.tprintf("%s/tests/unit", root)},
			{parent_arg, fmt.tprintf("%s/tests", root)},
			{"relative_named=tests/integration", fmt.tprintf("%s/tests/integration", root)},
		}) {
		arg, dir := pair[0], pair[1]
		checked_cli(t, cli, "path", "add", arg)
		key := "relative_named" if strings.has_prefix(arg, "relative_named=") else ""
		testing.expect_value(t, path_rows(t, cli, dir, key), 1)
		checked_cli(t, cli, "path", "rm", key if key != "" else arg)
		testing.expect_value(t, path_rows(t, cli, dir), 0)
	}
	for dir in ([]string {
			"bin",
			"tools",
			"$WAYU_UNSET_PATH_TEST/bin",
			"portable/bin",
			"--portable",
		}) {
		testing.expect_value(t, os.make_directory_all(fmt.tprintf("%s/%s", cli.home, dir)), nil)
	}
	for pair in ([][2]string {
			{"$HOME/bin", "/bin"},
			{"${HOME}/tools", "/tools"},
			{"~/bin", "/bin"},
			{"home_named=~", ""},
		}) {
		checked_cli(t, cli, "path", "add", pair[0])
		testing.expect_value(t, path_rows(t, cli, fmt.tprintf("%s%s", cli.home, pair[1])), 1)
	}
	before := read_fixture(t, entries_path(cli))
	testing.expect(t, !has_any(before, "$HOME", "${HOME}", "\"dir\": \"~"))
	_, code := run_cli(
		t,
		cli,
		"path",
		"add",
		fmt.tprintf("%s/$WAYU_UNSET_PATH_TEST/bin", cli.home),
	)
	testing.expect(t, code != 0)
	out := checked_cli(t, cli, "path", "add", "preview=$HOME/.config", "--dry-run")
	testing.expect(t, strings.contains(out, fmt.tprintf("%s/.config", cli.home)))
	testing.expect_value(t, read_fixture(t, entries_path(cli)), before)
	checked_cli(
		t,
		cli,
		"path",
		"add",
		fmt.tprintf("portable=%s/portable/bin", cli.home),
		"--portable",
	)
	testing.expect_value(t, path_rows(t, cli, "$HOME/portable/bin", "portable"), 1)
	before = read_fixture(t, entries_path(cli))
	expect_exit(t, cli, 65, "path", "add", "/usr/bin", "--portable")
	expect_exit(t, cli, 64, "path", "list", "--portable")
	sibling := fmt.tprintf("%s-sibling", cli.home)
	if err := os.make_directory(sibling); err != nil {
		testing.fail_now(t, "create sibling fixture")
	}
	defer os.remove(sibling)
	expect_exit(t, cli, 65, "path", "add", sibling, "--portable")
	out = checked_cli(
		t,
		cli,
		"path",
		"add",
		fmt.tprintf("preview=%s/.config", cli.home),
		"--portable",
		"--dry-run",
	)
	testing.expect(t, strings.contains(out, "$HOME/.config"))
	testing.expect_value(t, read_fixture(t, entries_path(cli)), before)
	sh := cli
	sh.binary = "/bin/sh"
	checked_cli(t, sh, "-c", `cd "$HOME" && exec "$1" path add -- --portable`, "probe", cli.binary)
	resolved := strings.trim_space(checked_cli(t, sh, "-c", `cd "$HOME/--portable" && pwd -P`))
	testing.expect_value(t, path_rows(t, cli, resolved), 1)
}

@(test)
path_clean_dedup :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)
	checked_cli(t, cli, "init", "--shell", "zsh")
	missing := fmt.tprintf("%s/gone", cli.home)
	keep := fmt.tprintf("%s/bin", cli.home)
	testing.expect_value(t, os.make_directory(keep), nil)
	checked_cli(t, cli, "const", "add", "TOOLS_ROOT", cli.home)
	rows := []Fixture_Path {
		{"keep", keep},
		{"gone", missing},
		{"home", "$HOME"},
		{"unset_bin", "$WAYU_OKAMI168_SURELY_UNSET/bin"},
		{"env_bin", "${TOOLS_ROOT}/bin"},
	}
	set_store(t, cli, paths = rows, env = read_store(t, cli).env)
	before := read_fixture(t, entries_path(cli))
	out := checked_cli(t, cli, "--dry-run", "path", "clean")
	testing.expect(t, strings.contains(out, "gone"))
	expect_exit(t, cli, 64, "path", "clean")
	testing.expect_value(t, read_fixture(t, entries_path(cli)), before)
	checked_cli(t, cli, "path", "clean", "--yes")
	for row in rows {
		testing.expect_value(t, path_rows(t, cli, row.dir, row.key), 0 if row.key == "gone" else 1)
	}
	set_store(t, cli, paths = {{"a_home", "$HOME"}, {"b_home", cli.home}, {"c_tmp", "/tmp"}})
	checked_cli(t, cli, "path", "dedup", "--yes")
	testing.expect_value(t, path_rows(t, cli, "$HOME", "a_home"), 1)
	testing.expect_value(t, path_rows(t, cli, cli.home), 0)
	testing.expect_value(t, path_rows(t, cli, "/tmp", "c_tmp"), 1)
	out = checked_cli(t, cli, "path", "add", cli.home)
	testing.expect(
		t,
		strings.contains(out, "already") &&
		!strings.contains(out, "Added") &&
		path_rows(t, cli, cli.home) == 0,
	)
	set_store(t, cli, paths = {{"dup", "/tmp"}, {"dup", "/tmp"}})
	before = read_fixture(t, entries_path(cli))
	code: int
	out, code = run_cli(t, cli, "path", "dedup", "--yes")
	testing.expect(
		t,
		code == 78 &&
		strings.contains(out, "appears twice") &&
		strings.contains(out, entries_path(cli)),
	)
	testing.expect_value(t, read_fixture(t, entries_path(cli)), before)
	set_store(t, cli, paths = {{"hooked", "/tmp"}})
	write_fixture(
		t,
		fmt.tprintf("%s/.config/wayu/hooks.conf", cli.home),
		`pre_path_remove = echo pre:{path} >> "$HOME/log"
post_path_remove = echo post:{path} >> "$HOME/log"
`,
	)
	checked_cli(t, cli, "path", "rm", "hooked")
	testing.expect_value(
		t,
		read_fixture(t, fmt.tprintf("%s/log", cli.home)),
		"pre:/tmp\npost:/tmp\n",
	)
}
