package integration

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
constants :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)
	expect_exit(t, cli, 0, "init", "--shell", "zsh")
	cases := []Named_Value {
		{"MY_VAR", "test_value"},
		{"MY_PATH", "/usr/local/my path"},
		{"API_KEY", "abc-123_xyz.789"},
		{"GET_TEST", "hello_world"},
		{"ESCAPE_TEST", `say "hello"`},
		{"QUOTED_VALUE", `"Hello, World!"`},
		{"VERSION_2024", "1.2.3"},
		{"PERSIST_TEST_1", "value1"},
		{"PERSIST_TEST_2", "value2"},
	}
	for c in cases {expect_exit(t, cli, 0, "constants", "add", c.name, c.value)}
	rows := read_store(t, cli).env
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
	for c in cases[3:5] {
		testing.expect_value(
			t,
			strings.trim_space(checked_cli(t, cli, "constants", "get", c.name)),
			c.value,
		)
	}
	testing.expect(t, strings.contains(checked_cli(t, cli, "constants", "list"), "MY_VAR"))
	expect_exit(t, cli, 65, "constants", "get", "NONEXISTENT_XYZ_123")
	expect_exit(t, cli, 64, "constants", "get", "")
	expect_exit(t, cli, 0, "constants", "rm", "MY_VAR")
	_, removed := named_value(read_store(t, cli).env, "MY_VAR")
	testing.expect_value(t, removed, 0)
	expect_exit(t, cli, 0, "constants", "add", "DUPLICATE_TEST", "first")
	expect_exit(t, cli, 0, "constants", "add", "DUPLICATE_TEST", "second")
	val, count := named_value(read_store(t, cli).env, "DUPLICATE_TEST")
	testing.expect(t, val == "second" && count == 1)
	for c in ([]Named_Value {
			{"bad-name", "invalid"},
			{"123ABC", "must start with"},
			{"while", "reserved"},
		}) {
		out, code := run_cli(t, cli, "constants", "add", c.name, "value")
		testing.expectf(
			t,
			code != 0 && strings.contains(strings.to_lower(out, context.temp_allocator), c.value),
			"%s: %s",
			c.name,
			out,
		)
	}
	warn := checked_cli(t, cli, "constants", "add", "my_lowercase_var", "value")
	val, count = named_value(read_store(t, cli).env, "my_lowercase_var")
	testing.expect(
		t,
		strings.contains(warn, "contains lowercase letters") &&
		strings.contains(warn, "UPPER_CASE") &&
		val == "value" &&
		count == 1,
	)
	out, code := run_cli(t, cli, "constants", "add", "MULTILINE", "line1\nline2")
	testing.expectf(t, code == 0 || has_any(out, "invalid", "newline"), "%s", out)
	set_store(t, cli, env = {{"FROM_TOML", "loaded"}, {"TOML_ONLY", "from_table"}})
	list := checked_cli(t, cli, "constants", "list")
	testing.expect(t, strings.contains(list, "FROM_TOML") && strings.contains(list, "loaded"))
	testing.expect_value(
		t,
		strings.trim_space(checked_cli(t, cli, "constants", "get", "TOML_ONLY")),
		"from_table",
	)
	set_store(t, cli, env = {{"EXISTING", "value"}})
	cfg := fmt.tprintf("%s/.config/wayu/wayu.toml", cli.home)
	before := read_fixture(t, cfg)
	expect_exit(t, cli, 0, "constants", "add", "TOML_ADDED", "new_value")
	rows = read_store(t, cli).env
	testing.expect(
		t,
		len(rows) == 2 &&
		rows[0] == Named_Value{"EXISTING", "value"} &&
		rows[1] == Named_Value{"TOML_ADDED", "new_value"},
	)
	testing.expect_value(t, read_fixture(t, cfg), before)
	expect_exit(t, cli, 0, "constants", "rm", "TOML_ADDED")
	rows = read_store(t, cli).env
	testing.expect(t, len(rows) == 1 && rows[0] == Named_Value{"EXISTING", "value"})
	help := checked_cli(t, cli, "constants", "help")
	testing.expect(
		t,
		strings.contains(help, "EXAMPLES") && strings.contains(help, "wayu const add"),
	)
	expect_exit(t, cli, 0, "const", "add", "CONST_ALIAS_TEST", "alias_value")
	val, count = named_value(read_store(t, cli).env, "CONST_ALIAS_TEST")
	testing.expect(t, val == "alias_value" && count == 1)
	testing.expect(t, strings.contains(checked_cli(t, cli, "const", "list"), "CONST_ALIAS_TEST"))
	testing.expect_value(
		t,
		strings.trim_space(checked_cli(t, cli, "const", "get", "CONST_ALIAS_TEST")),
		"alias_value",
	)
	expect_exit(t, cli, 0, "const", "rm", "CONST_ALIAS_TEST")
	_, removed = named_value(read_store(t, cli).env, "CONST_ALIAS_TEST")
	testing.expect_value(t, removed, 0)

	protected := strings.fields(
		"PATH HOME IFS SHELL ZDOTDIR WAYU_CONFIG_DIR WAYU_ANY PS1 PROMPT_COMMAND BASH_ENV RPROMPT fish_function_path",
		context.temp_allocator,
	)
	for name in protected {expect_exit(t, cli, 65, "const", "add", name, "/x")}
	expect_exit(t, cli, 65, "const", "add", "PATH", "/x", "--secret")
	_, count = named_value(read_store(t, cli).env, "PATH")
	testing.expect_value(t, count, 0)
	set_store(t, cli, env = {{"PATH", "/x"}, {"PROMPT_COMMAND", "true"}})
	out, code = run_cli(t, cli, "doctor")
	testing.expect(
		t,
		code == 78 &&
		strings.contains(out, "protected environment names") &&
		strings.contains(out, "PATH") &&
		strings.contains(out, "PROMPT_COMMAND"),
	)
	expect_exit(t, cli, 0, "build")
	core := read_fixture(t, fmt.tprintf("%s/.local/share/wayu/core.zsh", cli.home))
	testing.expect(
		t,
		strings.contains(core, "# wayu: skipping protected env name PROMPT_COMMAND") &&
		!strings.contains(core, "export PATH="),
	)
	expect_exit(t, cli, 0, "const", "rm", "PATH")
	expect_exit(t, cli, 0, "const", "rm", "PROMPT_COMMAND")

	out, code = run_cli(t, cli, "const", "add", "BADUTF", "a\xffb")
	_, count = named_value(read_store(t, cli).env, "BADUTF")
	testing.expect(
		t,
		code == 65 &&
		strings.count(out, "ERROR") == 1 &&
		strings.contains(out, "UTF-8") &&
		count == 0,
	)
	set_store(t, cli, env = {{"EMPTY_C", ""}, {"CMT_C", "nvim # not a comment"}})
	expect_exit(t, cli, 0, "const", "add", "CAFE_C", "café")
	for c in ([]Named_Value {
			{"EMPTY_C", ""},
			{"CMT_C", "nvim # not a comment"},
			{"CAFE_C", "café"},
		}) {
		val, count = named_value(read_store(t, cli).env, c.name)
		testing.expect(t, val == c.value && count == 1)
		testing.expect_value(
			t,
			strings.trim_space(checked_cli(t, cli, "const", "get", c.name)),
			c.value,
		)
	}

	env := make([dynamic]string, context.temp_allocator)
	for entry in cli.env {
		key, _, _ := strings.partition(entry, "=")
		switch key {case "HOME",
		                 "PATH",
		                 "NO_COLOR",
		                 "ASAN_OPTIONS",
		                 "LSAN_OPTIONS",
		                 "UBSAN_OPTIONS":
			append(&env, entry)
		}
	}
	append(&env, "WAYU_FIRST_VAR=x")
	cli.env = env[:]
	full := checked_cli(t, cli, "--json", "const", "list", "--full")
	listed: struct {
		constants: []struct {
			constant, value, source: string,
		},
	}
	if err := json.unmarshal(transmute([]u8)full, &listed, allocator = context.temp_allocator);
	   err != nil {
		testing.fail_now(t, fmt.tprintf("parse constant list: %v", err))
	}
	seen := make(map[string]bool, context.temp_allocator)
	for row in listed.constants {
		testing.expectf(t, !seen[row.constant], "repeated %s", row.constant)
		seen[row.constant] = true
	}
	testing.expect(t, len(seen) > 0)
}
