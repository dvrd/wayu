package integration

import wayu "../../src"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// A hook may start another wayu while the first command is waiting for it.
hook_command :: proc(t: ^testing.T, cli: CLI, args: ..string) -> string {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "/usr/bin/env", "-i")
	for entry in cli.env {
		key, _, _ := strings.partition(entry, "=")
		if key != "EDITOR" && key != "VISUAL" {
			append(&cmd, entry)
		}
	}
	append(&cmd, cli.binary)
	append(&cmd, ..args)
	result := wayu.run_command_timeout(cmd[:], 20_000)
	defer wayu.command_result_destroy(&result)
	testing.expectf(
		t,
		result.ok,
		"%v: timeout=%t, exit %d: %s",
		args,
		result.timed_out,
		result.exit_code,
		result.stderr,
	)
	return fmt.tprintf("%s%s", result.stdout, result.stderr)
}

@(test)
hooks :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)
	checked_cli(t, cli, "init", "--shell", "zsh")
	path := fmt.tprintf("%s/.config/wayu/hooks.conf", cli.home)
	dir := fmt.tprintf("%s/hookdir", cli.home)
	testing.expect_value(t, os.make_directory(dir), nil)
	set_cli_env(&cli, "HOOK_WAYU", cli.binary)
	write_fixture(
		t,
		path,
		`pre_path_add = "$HOOK_WAYU" build >/dev/null 2>&1
post_path_add = "$HOOK_WAYU" alias add fromhook 'echo hi' >/dev/null 2>&1
pre_path_remove = "$HOOK_WAYU" build >/dev/null 2>&1
post_path_remove = "$HOOK_WAYU" alias rm fromhook >/dev/null 2>&1
`,
	)
	hook_command(t, cli, "path", "add", dir)
	value, count := named_value(read_store(t, cli).aliases, "fromhook")
	testing.expect(t, count == 1 && value == "echo hi")
	hook_command(t, cli, "path", "rm", dir)
	_, count = named_value(read_store(t, cli).aliases, "fromhook")
	testing.expect_value(t, count, 0)

	write_fixture(t, path, "timeout = 1\npost_alias_add = sleep 30\n")
	start := time.tick_now()
	out := hook_command(t, cli, "alias", "add", "slowhook", "ls")
	testing.expect(t, time.tick_since(start) < 10 * time.Second)
	testing.expect(t, strings.contains(out, "post_alias_add hook timed out after 1 s"))

	write_fixture(t, path, "post_alias_add = echo hook-out-{name}; echo hook-err >&2\n")
	out = hook_command(t, cli, "alias", "add", "shownhook", "ls")
	testing.expect(
		t,
		strings.contains(out, "hook-out-shownhook") && strings.contains(out, "hook-err"),
	)

	log := fmt.tprintf("%s/rm-hooks.log", cli.home)
	write_fixture(
		t,
		path,
		`pre_alias_remove = echo pre:{name}={value} >> "$HOME/rm-hooks.log"
post_alias_remove = echo post:{name}={value} >> "$HOME/rm-hooks.log"
post_constant_remove = echo const:{name}={value} >> "$HOME/rm-hooks.log"
`,
	)
	hook_command(t, cli, "alias", "add", "rmhook", "git status")
	hook_command(t, cli, "const", "add", "RMHOOK_C", "myvalue")
	hook_command(t, cli, "alias", "rm", "rmhook")
	hook_command(t, cli, "const", "rm", "RMHOOK_C")
	testing.expect_value(
		t,
		read_fixture(t, log),
		"pre:rmhook=git status\npost:rmhook=git status\nconst:RMHOOK_C=myvalue\n",
	)

	write_fixture(
		t,
		path,
		`post_path_add = "/bin/echo" {path} "done"
post_path_remove = "echo 'wrapped ok'"
`,
	)
	out = hook_command(t, cli, "path", "add", dir)
	testing.expect(t, strings.contains(out, fmt.tprintf("%s done", dir)))
	out = hook_command(t, cli, "path", "rm", dir)
	testing.expect(t, strings.contains(out, "wrapped ok"))

	out = hook_command(t, cli, "function", "add", "noeditfn")
	file := fmt.tprintf("%s/.local/share/wayu/functions/noeditfn.zsh", cli.home)
	printed := false
	for line in strings.split_lines_iterator(&out) {
		if strings.trim_space(line) == file {
			printed = true
		}
	}
	testing.expect(t, printed && os.exists(file))
}
