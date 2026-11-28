package integration

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"

@(test)
exit_codes :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)
	for entry in ([]string{"path", "alias", "const"}) {expect_exit(t, cli, 78, entry, "list")}
	expect_exit(t, cli, 0, "init", "--shell", "zsh")

	doc, err := os.read_entire_file_from_path("docs/cli.md", context.temp_allocator)
	if err != nil {
		testing.fail_now(t, fmt.tprintf("read docs/cli.md: %v", err))
	}
	_, heading, rest := strings.partition(string(doc), "### Exit code examples\n")
	if heading == "" {
		testing.fail_now(t, "missing exit code examples in docs/cli.md")
	}
	section, _, _ := strings.partition(rest, "\n#")
	codes := make(map[int]bool, context.temp_allocator)
	count := 0
	for line in strings.split_lines(section, context.temp_allocator) {
		if !strings.has_prefix(line, "| `wayu ") {
			continue
		}
		cmd, divider, cell := strings.partition(strings.trim_prefix(line, "| `wayu "), "` | ")
		code, ok := strconv.parse_int(strings.trim_suffix(cell, " |"), 10)
		if !testing.expectf(t, divider != "" && ok, "invalid exit code row: %s", line) {
			continue
		}
		expect_exit(t, cli, code, ..fixture_words(t, cmd))
		codes[code] = true
		count += 1
	}
	testing.expectf(t, count >= 10, "only %d documented exit code examples", count)
	for expected in ([]int{0, 64, 65, 66, 78}) {
		testing.expectf(t, codes[expected], "missing exit code %d in docs/cli.md", expected)
	}

	// docs/cli.md "When a runtime file cannot be refreshed": the change is
	// saved, the command exits 74 and build repairs the runtime.
	core := fmt.tprintf("%s/.local/share/wayu/core.zsh", cli.home)
	testing.expect_value(t, os.remove(core), nil)
	testing.expect_value(t, os.make_directory(core), nil)
	_, refresh_err, refresh_code := cli_streams(t, cli, "alias", "add", "exit_probe", "true")
	testing.expect_value(t, refresh_code, 74)
	testing.expectf(
		t,
		strings.contains(
			refresh_err,
			fmt.tprintf("wayu: could not refresh zsh runtime file %s", core),
		) &&
		strings.contains(refresh_err, "changes saved") &&
		strings.contains(refresh_err, "wayu build"),
		"unexpected diagnostic: %s",
		refresh_err,
	)
	expect_exit(t, cli, 74, "build")
	expect_exit(t, cli, 0, "alias", "get", "exit_probe")
	testing.expect_value(t, os.remove(core), nil)
	expect_exit(t, cli, 0, "build")
	testing.expect(t, strings.contains(read_fixture(t, core), "exit_probe"))

	config := fmt.tprintf("%s/.config/wayu/wayu.toml", cli.home)
	data, read_err := os.read_entire_file_from_path(config, context.temp_allocator)
	if read_err != nil {
		testing.fail_now(t, fmt.tprintf("read %s: %v", config, read_err))
	}
	invalid := fmt.tprintf("%s\n[aliases]\nll = ls\n", string(data))
	if write_err := os.write_entire_file(config, transmute([]u8)invalid); write_err != nil {
		testing.fail_now(t, fmt.tprintf("write %s: %v", config, write_err))
	}
	expect_exit(t, cli, 78, "doctor")
	expect_exit(t, cli, 65, "toml", "validate")
}
