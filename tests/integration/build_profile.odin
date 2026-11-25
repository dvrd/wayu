package integration

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
build_profile :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)
	checked_cli(t, cli, "init", "--shell", "zsh")
	out := checked_cli(t, cli, "build", "profile")
	for word in ([]string {
			"core",
			"interactive shell",
		}) {testing.expectf(t, strings.contains(out, word), "missing %s in %s", word, out)}
	rows := make(map[string]int, context.temp_allocator)
	for line in strings.split_lines_iterator(&out) {
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) < 2 || fields[len(fields) - 1] != "ms" {
			continue
		}
		label := fields[0]
		if label != "raw" && label != "min" && label != "max" && label != "mean" {
			continue
		}
		rows[label] += 1
		testing.expectf(
			t,
			len(fields) == (7 if label == "raw" else 3),
			"unexpected samples: %s",
			line,
		)
		for value in fields[1:len(fields) - 1] {
			ms, ok := strconv.parse_f64(value)
			testing.expectf(t, ok && ms >= 0, "invalid sample: %s", line)
		}
	}
	for label in ([]string{"min", "mean", "max", "raw"}) {testing.expect_value(t, rows[label], 2)}
	data := fmt.tprintf("%s/.local/share/wayu", cli.home)
	testing.expect_value(t, os.remove(fmt.tprintf("%s/core.zsh", data)), nil)
	out = checked_cli(t, cli, "build", "profile")
	testing.expect(t, strings.contains(out, "core.") && strings.contains(out, "not found"))
	checked_cli(t, cli, "init", "--shell", "zsh")
	checked_cli(t, cli, "alias", "add", "ll", "ls -la")
	out = checked_cli(t, cli, "build", "profile")
	for label in ([]string{"Phase breakdown (sorted by time", "(sum)", "PATH", "Aliases"}) {
		testing.expectf(t, strings.contains(out, label), "missing %s", label)
	}
	config := fmt.tprintf("%s/.config/wayu", cli.home)
	toml := fmt.tprintf("%s/wayu.toml", config)
	write_fixture(t, fmt.tprintf("%s/lazyinit.sh", cli.home), "true\n")
	tool := fmt.tprintf("%s/wayufaketool", cli.home)
	write_fixture(t, tool, "#!/bin/sh\necho 'export WAYU_FAKE=1'\n")
	testing.expect_value(t, os.chmod(tool, {.Read_User, .Write_User, .Execute_User}), nil)
	tools_config := `
[tools]
wayufaketool = { kind = "evalcache", args = "init zsh" }
fakelazy = { kind = "lazy", init_script = "~/lazyinit.sh", hook_commands = ["fakelazy"] }
`
	write_fixture(t, toml, fmt.tprintf("%s%s", read_fixture(t, toml), tools_config))
	path, _ := os.lookup_env("PATH", context.temp_allocator)
	set_cli_env(&cli, "PATH", fmt.tprintf("%s:%s", cli.home, path))
	user_config := fmt.tprintf("%s/config.zsh", config)
	write_fixture(t, user_config, "[[ -o interactive ]] && sleep 0.3\n")
	checked_cli(t, cli, "build")
	out = checked_cli(t, cli, "build", "profile")
	for label in ([]string {
			"tool wayufaketool (evalcache)",
			"tool fakelazy (lazy)",
			"(interactive, no user rc)",
		}) {
		testing.expectf(t, strings.contains(out, label), "missing %s: %s", label, out)
	}
	testing.expect(t, !strings.contains(out, "lazy ›"))
	delayed, timed_tool := false, false
	for line in strings.split_lines_iterator(&out) {
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) < 4 || fields[1] != "ms" || !strings.has_suffix(fields[2], "%") {
			continue
		}
		ms, ok := strconv.parse_f64(fields[0])
		if strings.contains(line, "User configuration (from config.zsh)") {
			delayed = ok && ms >= 250
		}
		if strings.contains(line, "tool wayufaketool (evalcache)") {
			timed_tool = ok
		}
	}
	testing.expect(t, delayed && timed_tool)
}

@(test)
export_modes :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)
	checked_cli(t, cli, "init", "--shell", "zsh")
	checked_cli(t, cli, "const", "add", "EXPORT_T", "hello")
	checked_cli(t, cli, "alias", "add", "exll", "ls -la")
	turbo := fmt.tprintf("%s/.local/share/wayu/turbo.zsh", cli.home)
	out := checked_cli(t, cli, "export", "--eval")
	testing.expect(t, !strings.contains(out, "\x1b[") && !os.exists(turbo))
	zsh := cli
	zsh.binary = "zsh"
	out = checked_cli(
		t,
		zsh,
		"-fc",
		`eval "$("$1" export --eval)"; print -r -- "$EXPORT_T"; alias exll`,
		"probe",
		cli.binary,
	)
	testing.expect(t, strings.contains(out, "hello") && strings.contains(out, "exll"))
	expect_exit(t, cli, 78, "export", "--check")
	checked_cli(t, cli, "export", "--turbo")
	testing.expect(t, os.exists(turbo))
	expect_exit(t, cli, 0, "export", "--check")
	config := fmt.tprintf("%s/.config/wayu", cli.home)
	future := time.time_add(time.now(), 5 * time.Second)
	testing.expect_value(t, os.chtimes(fmt.tprintf("%s/wayu.toml", config), future, future), nil)
	expect_exit(t, cli, 0, "export", "--check")
	file := fmt.tprintf("%s/config.zsh", config)
	write_fixture(t, file, "export CFG_PROBE=1\n")
	expect_exit(t, cli, 78, "export", "--check")
	checked_cli(t, cli, "export", "--turbo")
	expect_exit(t, cli, 0, "export", "--check")
	testing.expect_value(t, os.remove(file), nil)
	checked_cli(t, cli, "export", "--turbo")
	write_fixture(t, turbo, fmt.tprintf("%s# edited\n", read_fixture(t, turbo)))
	expect_exit(t, cli, 78, "export", "--check")
	expect_exit(t, cli, 64, "export", "bogus")
	expect_exit(t, cli, 64, "build", "bogus")
	expect_exit(t, cli, 64, "build", "eval")
}
