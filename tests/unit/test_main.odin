package test_wayu

import "core:testing"
import "core:fmt"
import wayu "../../src"

@(test)
test_parse_args_path_add :: proc(t: ^testing.T) {
	args := []string{"path", "add", "/usr/local/bin"}
	parsed := wayu.parse_args(args)
	defer if len(parsed.args) > 0 do delete(parsed.args)

	testing.expect_value(t, parsed.command, wayu.Command.PATH)
	testing.expect_value(t, parsed.action, wayu.Action.ADD)
	testing.expect_value(t, len(parsed.args), 1)
	testing.expect_value(t, parsed.args[0], "/usr/local/bin")
}

@(test)
test_parse_args_alias_add :: proc(t: ^testing.T) {
	args := []string{"alias", "add", "ll", "ls -la"}
	parsed := wayu.parse_args(args)
	defer if len(parsed.args) > 0 do delete(parsed.args)

	testing.expect_value(t, parsed.command, wayu.Command.ALIAS)
	testing.expect_value(t, parsed.action, wayu.Action.ADD)
	testing.expect_value(t, len(parsed.args), 2)
	testing.expect_value(t, parsed.args[0], "ll")
	testing.expect_value(t, parsed.args[1], "ls -la")
}

@(test)
test_parse_args_constants_remove :: proc(t: ^testing.T) {
	args := []string{"constants", "rm"}
	parsed := wayu.parse_args(args)
	defer if len(parsed.args) > 0 do delete(parsed.args)

	testing.expect_value(t, parsed.command, wayu.Command.CONSTANTS)
	testing.expect_value(t, parsed.action, wayu.Action.REMOVE)
	testing.expect_value(t, len(parsed.args), 0)
}

@(test)
test_parse_args_help :: proc(t: ^testing.T) {
	args := []string{"help"}
	parsed := wayu.parse_args(args)
	defer if len(parsed.args) > 0 do delete(parsed.args)

	testing.expect_value(t, parsed.command, wayu.Command.HELP)
}

@(test)
test_parse_args_empty :: proc(t: ^testing.T) {
	args := []string{}
	parsed := wayu.parse_args(args)
	defer if len(parsed.args) > 0 do delete(parsed.args)

	testing.expect_value(t, parsed.command, wayu.Command.HELP)
}

@(test)
test_parse_args_unknown_command :: proc(t: ^testing.T) {
	args := []string{"unknown"}
	parsed := wayu.parse_args(args)
	defer if len(parsed.args) > 0 do delete(parsed.args)

	testing.expect_value(t, parsed.command, wayu.Command.UNKNOWN)
}

@(test)
test_parse_args_backup_restore :: proc(t: ^testing.T) {
	args := []string{"backup", "restore"}
	parsed := wayu.parse_args(args)
	defer if len(parsed.args) > 0 do delete(parsed.args)

	testing.expect_value(t, parsed.command, wayu.Command.BACKUP)
	testing.expect_value(t, parsed.action, wayu.Action.RESTORE)
}

@(test)
test_parse_args_backup_clean :: proc(t: ^testing.T) {
	args := []string{"backup", "clean"}
	parsed := wayu.parse_args(args)
	defer if len(parsed.args) > 0 do delete(parsed.args)

	testing.expect_value(t, parsed.command, wayu.Command.BACKUP)
	testing.expect_value(t, parsed.action, wayu.Action.CLEAN)
}

@(test)
test_parse_args_plugin_list :: proc(t: ^testing.T) {
	args := []string{"plugin", "list"}
	parsed := wayu.parse_args(args)
	defer if len(parsed.args) > 0 do delete(parsed.args)

	testing.expect_value(t, parsed.command, wayu.Command.PLUGIN)
	testing.expect_value(t, parsed.action, wayu.Action.LIST)
}

@(test)
test_parse_args_completions_add :: proc(t: ^testing.T) {
	args := []string{"completions", "add", "_test"}
	parsed := wayu.parse_args(args)
	defer if len(parsed.args) > 0 do delete(parsed.args)

	testing.expect_value(t, parsed.command, wayu.Command.COMPLETIONS)
	testing.expect_value(t, parsed.action, wayu.Action.ADD)
	testing.expect_value(t, len(parsed.args), 1)
}

@(test)
test_parse_args_init_command :: proc(t: ^testing.T) {
	args := []string{"init"}
	parsed := wayu.parse_args(args)
	defer if len(parsed.args) > 0 do delete(parsed.args)

	testing.expect_value(t, parsed.command, wayu.Command.INIT)
}

@(test)
test_parse_args_version :: proc(t: ^testing.T) {
	args := []string{"version"}
	parsed := wayu.parse_args(args)
	defer if len(parsed.args) > 0 do delete(parsed.args)

	testing.expect_value(t, parsed.command, wayu.Command.VERSION)
}

@(test)
test_print_version :: proc(t: ^testing.T) {
	// Test that version printing doesn't crash
	wayu.print_version()
	testing.expect(t, true, "print_version should not crash")
}

@(test)
test_print_help :: proc(t: ^testing.T) {
	// Test that help printing doesn't crash
	wayu.print_help()
	testing.expect(t, true, "print_help should not crash")
}

@(test)
test_print_migrate_help :: proc(t: ^testing.T) {
	// Test that migrate help printing doesn't crash
	wayu.print_migrate_help()
	testing.expect(t, true, "print_migrate_help should not crash")
}