package integration

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

cli_json :: proc(t: ^testing.T, cli: CLI, command: string) -> json.Object {
	out, desc, _ := cli_streams(t, cli, ..fixture_words(t, command))
	doc, err := json.parse(transmute([]byte)out, allocator = context.temp_allocator)
	obj, ok := doc.(json.Object)
	if err != nil || !ok {
		testing.fail_now(t, fmt.tprintf("%s: invalid JSON object: %v: %s", command, err, desc))
	}
	return obj
}

expect_keys :: proc(t: ^testing.T, command: string, obj: json.Object, keys: string) {
	names := strings.fields(keys, context.temp_allocator)
	testing.expectf(t, len(names) == len(obj), "%s: expected %s, got %v", command, keys, obj)
	for key in names {_, ok := obj[key]; testing.expectf(t, ok, "%s: missing %s", command, key)}
}

@(test)
cli_output :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)
	for cmd in strings.fields(
		"path alias const constants env backup plugin init config build export toml doctor template hooks function reload search completions",
		context.temp_allocator,
	) {
		for flag in ([]string{"help", "--help", "-h"}) {
			out, err, code := cli_streams(t, cli, cmd, flag)
			testing.expectf(
				t,
				code == 0 && err == "" && out != "",
				"%s %s: %d %s",
				cmd,
				flag,
				code,
				err,
			)
		}
	}
	for cmd in ([]string {
			"path list",
			"path list --json",
			"alias list",
			"const list",
			"search x",
		}) {
		out, err, code := cli_streams(t, cli, ..fixture_words(t, cmd))
		testing.expectf(
			t,
			code == 78 && out == "" && strings.count(err, "ERROR:") == 1,
			"%s: %d %s",
			cmd,
			code,
			err,
		)
	}
	checked_cli(t, cli, "init", "--shell", "zsh")
	for pair in ([][2]string{{"alias", "aliases"}, {"plugin", "plugins"}}) {
		obj := cli_json(t, cli, fmt.tprintf("%s list --json", pair[0]))
		rows, ok := obj[pair[1]].(json.Array)
		testing.expect(t, ok && len(rows) == 0)
	}
	_ = cli_json(t, cli, "const list --json")
	checked_cli(t, cli, "path", "add", "/usr/bin")
	checked_cli(t, cli, "alias", "add", "ll", "ls -la")
	checked_cli(t, cli, "const", "add", "EDITOR", "nvim")
	for cmd in ([]string {
			"backup restore path",
			"path get /nope",
			"path add",
			"nosuchcmd",
			"path list --bogus",
		}) {
		out, err, code := cli_streams(t, cli, ..fixture_words(t, cmd))
		testing.expectf(
			t,
			code != 0 && err != "" && !strings.contains(out, "ERROR"),
			"%s: %d %s",
			cmd,
			code,
			out,
		)
	}
	for cmd in ([]string {
			"path add /tmp --json",
			"const get EDITOR --json",
			"hooks --json",
			"toml show --json",
		}) {
		out, err, code := cli_streams(t, cli, ..fixture_words(t, cmd))
		testing.expectf(
			t,
			code == 64 && out == "" && strings.contains(err, "--json"),
			"%s: %d %s",
			cmd,
			code,
			err,
		)
	}
	expect_exit(t, cli, 0, "path", "--help", "--json")
	schemas := [][3]string {
		{"path list --json", "paths", "path source exists"},
		{"alias list --json", "aliases", "alias command source"},
		{"const list --json", "constants", "constant value source"},
		{
			"plugin list --json",
			"plugins count enabled",
			"name enabled priority shell url commit installed_path conflicts",
		},
		{"backup list --json", "backups", "file count entries"},
		{"search ll --json", "results query count", "type name value match field score"},
		{"doctor --json", "checks summary", "name status message fixable"},
		{
			"secrets recipient list --json",
			"recipients key_id recovery",
			"name recipient this_machine",
		},
	}
	for schema in schemas {
		cmd, keys, row_keys := schema[0], schema[1], schema[2]
		obj := cli_json(t, cli, cmd)
		expect_keys(t, cmd, obj, keys)
		first, _, _ := strings.partition(keys, " ")
		rows, ok := obj[first].(json.Array)
		if !testing.expectf(t, ok, "%s: expected %s array", cmd, first) {
			continue
		}
		testing.expectf(
			t,
			len(rows) > 0 || first == "plugins" || first == "recipients",
			"%s: empty %s",
			cmd,
			first,
		)
		for val in rows {
			row := val.(json.Object)
			expect_keys(t, cmd, row, row_keys)
			if first == "backups" {
				for entry in row["entries"].(json.Array) {expect_keys(t, cmd, entry.(json.Object), "index timestamp size_bytes path pre_restore")}
			}
		}
		if first == "checks" {
			expect_keys(t, cmd, obj["summary"].(json.Object), "ok warnings errors info fixable")
		}
	}
	_ = cli_json(t, cli, "path list --json --full")
	_ = cli_json(t, cli, "search zzzz --json")
	path, _ := os.lookup_env("PATH", context.temp_allocator)
	set_cli_env(&cli, "PATH", fmt.tprintf("/opt/wayu-ext-test:%s", path))
	ext := cli_json(t, cli, "path list --json --source external")
	found := false
	for val in ext["paths"].(json.Array) {
		row := val.(json.Object)
		if row["path"].(string) == "/opt/wayu-ext-test" && row["source"].(string) == "external" {
			found = true
		}
	}
	testing.expect(t, found)
	help := checked_cli(t, cli, "help", "--no-color")
	completions := checked_cli(t, cli, "completions", "zsh")
	_, _, words := strings.partition(completions, "_wayu_commands() {")
	commands, _, _ := strings.partition(words, "\n}")
	count := 0
	for line in strings.split_lines_iterator(&commands) {
		key, sep, _ := strings.partition(strings.trim_space(line), ":")
		if sep == "" || !strings.has_prefix(key, "'") {
			continue
		}
		name := strings.trim_prefix(key, "'")
		listed := false
		help_text := help
		for h in strings.split_lines_iterator(&help_text) {
			desc, _, _ := strings.partition(strings.trim_space(h), "  ")
			for alias in strings.split(desc, ", ", context.temp_allocator) {
				if alias == name {
					listed = true
				}
			}
		}
		testing.expectf(t, listed, "help missing %s", name)
		count += 1
	}
	testing.expect(t, count > 0)
	doc := read_fixture(t, "docs/cli.md")
	_, _, section := strings.partition(doc, "## Exit codes\n")
	table, _, _ := strings.partition(section, "\n#")
	_, _, codes := strings.partition(help, "EXIT CODES:")
	count = 0
	for line in strings.split_lines_iterator(&table) {
		if !strings.contains(line, "| `EXIT_") {
			continue
		}
		fields := strings.fields(line, context.temp_allocator)
		listed := false
		rows := codes
		for h in strings.split_lines_iterator(&rows) {
			words := strings.fields(h, context.temp_allocator)
			if len(words) > 0 && words[0] == fields[1] {
				listed = true
			}
		}
		testing.expectf(t, listed, "help missing exit %s", fields[1])
		count += 1
	}
	testing.expect(t, count >= 10)
}

@(test)
cli_control_chars :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)
	checked_cli(t, cli, "init", "--shell", "zsh")
	value := "echo \x1b]0;pwned\x07\x1b[2J\u009b31m"
	dir := "/nonexistent/pwn\x1b[2Jdir"
	set_store(
		t,
		cli,
		env = {{"PWN_TITLE", value}},
		paths = {{"PWN", dir}},
		aliases = {{"pwnalias", value}},
	)
	for cmd in ([]string {
			"alias list",
			"alias list --full",
			"const list",
			"const list --full",
			"path list",
			"path list --full",
			"search pwn",
			"doctor",
		}) {
		out, _ := run_cli(t, cli, ..fixture_words(t, cmd))
		testing.expectf(
			t,
			!has_any(out, "\x1b", "\x07", "\u009b"),
			"%s printed raw control characters",
			cmd,
		)
		if cmd == "alias list" || cmd == "const list" {
			testing.expect(t, strings.contains(out, `\x1B]0;pwned\x07\x1B[2J\u009B31m`))
		}
		if cmd == "path list" {
			testing.expect(t, strings.contains(out, `pwn\x1B[2Jdir`))
		}
	}
	for item in ([][6]string {
			{"alias", "aliases", "alias", "pwnalias", "command", value},
			{"const", "constants", "constant", "PWN_TITLE", "value", value},
			{"path", "paths", "path", dir, "path", dir},
		}) {
		obj := cli_json(t, cli, fmt.tprintf("%s list --json", item[0]))
		found := false
		for val in obj[item[1]].(json.Array) {
			row := val.(json.Object)
			if row[item[2]].(string) == item[3] && row[item[4]].(string) == item[5] {
				found = true
			}
		}
		testing.expectf(t, found, "%s JSON lost the stored value", item[0])
	}
	testing.expect_value(
		t,
		checked_cli(t, cli, "const", "get", "PWN_TITLE"),
		fmt.tprintf("%s\n", value),
	)
}
