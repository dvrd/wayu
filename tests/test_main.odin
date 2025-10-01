package test_wayu

import "core:testing"
import "core:fmt"
import wayu "../src"

@(test)
test_parse_args_path_add :: proc(t: ^testing.T) {
	args := []string{"path", "add", "/usr/local/bin"}
	parsed := wayu.parse_args(args)

	testing.expect_value(t, parsed.command, wayu.Command.PATH)
	testing.expect_value(t, parsed.action, wayu.Action.ADD)
	testing.expect_value(t, len(parsed.args), 1)
	testing.expect_value(t, parsed.args[0], "/usr/local/bin")
}

@(test)
test_parse_args_alias_add :: proc(t: ^testing.T) {
	args := []string{"alias", "add", "ll", "ls -la"}
	parsed := wayu.parse_args(args)

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

	testing.expect_value(t, parsed.command, wayu.Command.CONSTANTS)
	testing.expect_value(t, parsed.action, wayu.Action.REMOVE)
	testing.expect_value(t, len(parsed.args), 0)
}

@(test)
test_parse_args_help :: proc(t: ^testing.T) {
	args := []string{"help"}
	parsed := wayu.parse_args(args)

	testing.expect_value(t, parsed.command, wayu.Command.HELP)
}

@(test)
test_parse_args_empty :: proc(t: ^testing.T) {
	args := []string{}
	parsed := wayu.parse_args(args)

	testing.expect_value(t, parsed.command, wayu.Command.HELP)
}

@(test)
test_parse_args_unknown_command :: proc(t: ^testing.T) {
	args := []string{"unknown"}
	parsed := wayu.parse_args(args)

	testing.expect_value(t, parsed.command, wayu.Command.UNKNOWN)
}