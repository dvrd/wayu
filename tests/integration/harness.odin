package integration

import wayu "../../src"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

CLI :: struct {
	binary: string,
	home:   string,
	env:    []string,
}

new_cli :: proc(t: ^testing.T) -> CLI {
	home, err := os.make_directory_temp("", "wayu-integration-*", context.temp_allocator)
	if err != nil {
		testing.fail_now(t, fmt.tprintf("create test home: %v", err))
	}
	binary, ok := os.lookup_env("WAYU_BIN", context.temp_allocator)
	if !ok {
		binary = "./bin/wayu"
	}
	env := make([dynamic]string, context.temp_allocator)
	inherited, env_err := os.environ(context.temp_allocator)
	if env_err != nil {
		testing.fail_now(t, "cannot read environment")
	}
	for entry in inherited {
		key, _, _ := strings.partition(entry, "=")
		switch key {
		case "HOME",
		     "SHELL",
		     "NO_COLOR",
		     "WAYU_CONFIG",
		     "WAYU_CONFIG_DIR",
		     "WAYU_DATA_DIR",
		     "XDG_CONFIG_HOME",
		     "XDG_DATA_HOME",
		     "XDG_CACHE_HOME",
		     "XDG_STATE_HOME",
		     "ZDOTDIR":
			continue
		}
		append(&env, entry)
	}
	append(&env, fmt.tprintf("HOME=%s", home), "SHELL=/bin/zsh", "NO_COLOR=1")
	absolute, path_err := os.get_absolute_path(binary, context.temp_allocator)
	if path_err != nil {
		testing.fail_now(t, fmt.tprintf("resolve %s: %v", binary, path_err))
	}
	return {absolute, home, env[:]}
}

cli_streams :: proc(t: ^testing.T, cli: CLI, args: ..string) -> (out, errout: string, code: int) {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, cli.binary)
	append(&cmd, ..args)
	state, stdout, stderr, err := os.process_exec(
		{command = cmd[:], env = cli.env},
		context.temp_allocator,
	)
	if err != nil {
		testing.fail_now(t, fmt.tprintf("%v: %v", cmd[:], err))
	}
	return string(stdout), string(stderr), state.exit_code
}

run_cli :: proc(t: ^testing.T, cli: CLI, args: ..string) -> (output: string, code: int) {
	out, errout, status := cli_streams(t, cli, ..args)
	return fmt.tprintf("%s%s", out, errout), status
}

set_cli_env :: proc(cli: ^CLI, key, value: string) {
	entry := fmt.tprintf("%s=%s", key, value)
	env := make([dynamic]string, context.temp_allocator)
	append(&env, ..cli.env)
	cli.env = env[:]
	for existing, i in cli.env {
		name, _, _ := strings.partition(existing, "=")
		if key == name {
			cli.env[i] = entry; return
		}
	}
	append(&env, entry)
	cli.env = env[:]
}

fixture_words :: proc(t: ^testing.T, line: string) -> []string {
	statements := wayu.shell_parse_statements(line, .POSIX)
	defer wayu.shell_statements_destroy(&statements)
	if len(statements) != 1 || statements[0].error != "" {
		testing.fail_now(t, line)
	}
	args := make([dynamic]string, context.temp_allocator)
	for tok in statements[0].tokens {
		if tok.kind != .Word {
			testing.fail_now(t, line)
		}
		append(&args, strings.clone(tok.word.text, context.temp_allocator))
	}
	return args[:]
}

read_fixture :: proc(t: ^testing.T, path: string) -> string {
	bytes, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		testing.fail_now(t, fmt.tprintf("read %s: %v", path, err))
	}
	return string(bytes)
}

checked_cli :: proc(t: ^testing.T, cli: CLI, args: ..string) -> string {
	out, code := run_cli(t, cli, ..args)
	testing.expectf(t, code == 0, "%v: exit %d: %s", args, code, out)
	return out
}

has_any :: proc(output: string, fragments: ..string) -> bool {
	for fragment in fragments {
		if strings.contains(output, fragment) {
			return true
		}
	}
	return false
}

write_fixture :: proc(t: ^testing.T, path, contents: string) {
	if err := os.write_entire_file(path, transmute([]byte)contents); err != nil {
		testing.fail_now(t, fmt.tprintf("write %s: %v", path, err))
	}
}


expect_exit :: proc(t: ^testing.T, cli: CLI, expected: int, args: ..string) {
	out, code := run_cli(t, cli, ..args)
	testing.expectf(t, code == expected, "%v: expected %d, got %d: %s", args, expected, code, out)
}
