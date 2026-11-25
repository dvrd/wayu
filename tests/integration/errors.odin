package integration

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
errors :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)
	missing := fmt.tprintf("%s/nonexistent", cli.home)
	out, _ := run_cli(t, cli, "completions", "add", "test", missing)
	testing.expectf(
		t,
		strings.contains(out, "File not found") && strings.contains(out, missing),
		"%s",
		out,
	)

	locked := fmt.tprintf("%s/locked", cli.home)
	write_fixture(t, locked, "test content")
	if err := os.chmod(locked, {}); err != nil {
		testing.fail_now(t, fmt.tprintf("chmod: %v", err))
	}
	out, _ = run_cli(t, cli, "completions", "add", "test", locked)
	testing.expectf(t, has_any(out, "Permission denied", "Failed to read"), "%s", out)

	out, _ = run_cli(t, cli, "path", "list")
	testing.expectf(t, has_any(out, "not initialized", "wayu init"), "%s", out)
	out, _ = run_cli(t, cli, "path", "add", missing)
	testing.expectf(
		t,
		has_any(out, "does not exist", "Directory not found", "Could not resolve absolute path"),
		"%s",
		out,
	)
	out, _ = run_cli(t, cli, "alias", "add", "bad;name", "command")
	testing.expectf(t, has_any(out, "Invalid", "contains invalid character"), "%s", out)
	out, _ = run_cli(t, cli, "completions", "rm", "nonexistent")
	testing.expectf(t, has_any(out, "wayu completions list", "to see available"), "%s", out)
	out, _ = run_cli(t, cli, "alias", "list")
	testing.expectf(t, has_any(out, "wayu init", "initialize"), "%s", out)

	file, _ := run_cli(t, cli, "completions", "add", "test", missing)
	input, _ := run_cli(t, cli, "alias", "add", "if", "cmd")
	dir, _ := run_cli(t, cli, "path", "add", missing)
	categories :=
		int(has_any(file, "File not found", "does not exist")) +
		int(has_any(input, "reserved", "Invalid")) +
		int(has_any(dir, "does not exist", "Directory"))
	testing.expectf(t, categories >= 2, "file: %s; input: %s; directory: %s", file, input, dir)
}
