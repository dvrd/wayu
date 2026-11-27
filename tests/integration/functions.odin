package integration

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
functions :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)
	set_cli_env(&cli, "EDITOR", "true")
	set_cli_env(&cli, "VISUAL", "true")
	checked_cli(t, cli, "init", "--shell", "zsh")
	dir := fmt.tprintf("%s/.local/share/wayu/functions", cli.home)
	file := fmt.tprintf("%s/greet.zsh", dir)
	testing.expect(t, strings.contains(checked_cli(t, cli, "function", "list"), "No functions"))
	checked_cli(t, cli, "function", "add", "greet")
	testing.expect(t, os.exists(file))
	testing.expect(t, strings.contains(checked_cli(t, cli, "function", "list"), "greet"))
	expect_exit(t, cli, 64, "function", "remove", "greet")
	testing.expect(t, os.exists(file))
	out := checked_cli(t, cli, "--dry-run", "function", "remove", "greet", "--yes")
	testing.expect(t, strings.contains(out, "DRY RUN") && os.exists(file))
	checked_cli(t, cli, "function", "remove", "greet", "--yes")
	testing.expect(t, !os.exists(file))
	out = checked_cli(t, cli, "-n", "function", "add", "dryfn")
	testing.expect(
		t,
		strings.contains(out, "DRY RUN") && !os.exists(fmt.tprintf("%s/dryfn.zsh", dir)),
	)
	code: int
	out, code = run_cli(t, cli, "function", "remove", "does_not_exist", "--yes")
	testing.expectf(t, code == 66 && strings.contains(out, "not found"), "%d: %s", code, out)
	out, code = run_cli(t, cli, "function", "add", "bad name")
	testing.expectf(
		t,
		code == 65 && strings.contains(strings.to_lower(out, context.temp_allocator), "invalid"),
		"%d: %s",
		code,
		out,
	)
	// A rejected name must leave files outside the managed functions directory intact.
	outside := fmt.tprintf("%s/.local/share/wayu/sibling.zsh", cli.home)
	write_fixture(t, outside, "keep me\n")
	expect_exit(t, cli, 65, "function", "remove", "../sibling", "--yes")
	testing.expect_value(t, read_fixture(t, outside), "keep me\n")
	checked_cli(t, cli, "function", "add", "helper")
	testing.expect(t, strings.contains(checked_cli(t, cli, "fn", "list"), "helper"))
	sh := cli
	sh.binary = "/bin/sh"
	for shell in ([]string{"zsh", "bash", "fish"}) {
		_, probe := run_cli(t, sh, "-c", `command -v "$1"`, "probe", shell)
		if probe != 0 {
			continue
		}
		exe := cli
		exe.binary = shell
		name := fmt.tprintf("skel_%s", shell)
		checked_cli(t, cli, "--shell", shell, "function", "add", name)
		skeleton := fmt.tprintf("%s/%s.%s", dir, name, shell)
		testing.expect(t, os.exists(skeleton))
		checked_cli(t, exe, "-n", skeleton)
		if shell == "zsh" {
			write_fixture(
				t,
				fmt.tprintf("%s/wayu_e2e_marker.zsh", dir),
				"wayu_e2e_marker() { echo E2E_MARKER_OK; }\n",
			)
			result := checked_cli(
				t,
				exe,
				"-fc",
				`source "$HOME/.local/share/wayu/init.zsh" && wayu_e2e_marker`,
			)
			testing.expect(t, strings.contains(result, "E2E_MARKER_OK"))
		}
	}
}
