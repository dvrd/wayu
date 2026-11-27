package integration

import "core:fmt"
import "core:os"
import "core:testing"

@(test)
completions_multishell :: proc(t: ^testing.T) {
	cases := []struct {
		shell, name, target, other, contents: string,
	} {
		{"bash", "jj", "jj.bash-completion", "_jj", "# dummy bash completion for jj\n"},
		{"fish", "jj", "jj.fish", "", "# dummy fish completion\ncomplete -c jj -s h\n"},
		{"zsh", "foo.fish", "foo.fish", "_foo.fish", "# completion ported as-is\n"},
	}
	for c in cases {
		cli := new_cli(t)
		defer os.remove_all(cli.home)
		set_cli_env(&cli, "SHELL", fmt.tprintf("/bin/%s", c.shell))
		expect_exit(t, cli, 0, "init", "--shell", c.shell)
		dir := fmt.tprintf("%s/.local/share/wayu/completions", cli.home)
		src := fmt.tprintf("%s/source", cli.home)
		write_fixture(t, src, c.contents)
		expect_exit(t, cli, 0, "--shell", c.shell, "completions", "add", c.name, src)
		testing.expectf(
			t,
			os.exists(fmt.tprintf("%s/%s", dir, c.target)),
			"%s: missing %s",
			c.shell,
			c.target,
		)
		if c.other != "" {
			testing.expectf(
				t,
				!os.exists(fmt.tprintf("%s/%s", dir, c.other)),
				"%s: unexpected %s",
				c.shell,
				c.other,
			)
		}
	}
	cli := new_cli(t)
	defer os.remove_all(cli.home)
	expect_exit(t, cli, 0, "init", "--shell", "zsh")
	path := fmt.tprintf("%s/.local/share/wayu/completions/foo.fish", cli.home)
	write_fixture(t, path, "# manually installed\n")
	expect_exit(t, cli, 0, "--shell", "zsh", "completions", "remove", "foo")
	testing.expect(t, !os.exists(path))
}
