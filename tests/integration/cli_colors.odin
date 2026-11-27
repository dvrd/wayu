package integration

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
cli_colors :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)
	// An empty value disables each override, independent of the calling terminal.
	for key in ([]string {
			"NO_COLOR",
			"FORCE_COLOR",
			"CLICOLOR_FORCE",
			"WAYU_PLAIN",
		}) {set_cli_env(&cli, key, "")}
	expect_exit(t, cli, 0, "init", "--shell", "zsh")
	expect_exit(t, cli, 0, "path", "add", "/usr/bin")
	expect_exit(t, cli, 0, "alias", "add", "ll", "ls -la")
	expect_exit(t, cli, 0, "const", "add", "EDITOR", "nvim")
	commands := []string {
		"--help",
		"help",
		"version",
		"path list",
		"path list --full",
		"path list --json",
		"path --help",
		"path get /nope",
		"alias list",
		"alias --help",
		"const list",
		"const list --full",
		"const --help",
		"backup list",
		"backup --help",
		"backup restore path",
		"doctor",
		"doctor --json",
		"plugin list",
		"plugin list --json",
		"plugin search",
		"plugin --help",
		"completions list",
		"completions --help",
		"toml validate",
		"toml show",
		"toml keys",
		"template list",
		"hooks",
		"function list",
		"export list",
		"build help",
		"init --help",
		"search ll",
		"search ll --json",
		"nosuchcmd",
		"path add",
		"path list --bogus",
		"path add /tmp --json",
	}
	for mode in ([]string{"pipe", "NO_COLOR", "--no-color"}) {
		set_cli_env(&cli, "FORCE_COLOR", "1" if mode != "pipe" else "")
		set_cli_env(&cli, "NO_COLOR", "1" if mode == "NO_COLOR" else "")
		for cmd in commands {
			line := fmt.tprintf("%s --no-color", cmd) if mode == "--no-color" else cmd
			out, _ := run_cli(t, cli, ..fixture_words(t, line))
			testing.expectf(t, !strings.contains(out, "\x1b"), "%s: escape in %s", mode, line)
		}
	}
	set_cli_env(&cli, "NO_COLOR", "")
	set_cli_env(&cli, "FORCE_COLOR", "1")
	_, out, _, err := os.process_exec(
		{command = {cli.binary, "path", "list"}, env = cli.env},
		context.temp_allocator,
	)
	testing.expectf(
		t,
		err == nil && strings.contains(string(out), "\x1b"),
		"forced stdout missing color",
	)
	_, _, errout, err2 := os.process_exec(
		{command = {cli.binary, "path", "get", "/nope"}, env = cli.env},
		context.temp_allocator,
	)
	testing.expectf(
		t,
		err2 == nil && strings.contains(string(errout), "\x1b"),
		"forced stderr missing color",
	)
}
