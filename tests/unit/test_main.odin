package test_wayu

import wayu "../../src"
import "core:fmt"
import "core:testing"

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
	// Action words come from WAYU_COMMAND_SPECS (OKAMI-282): backup has no
	// `clean` (that is `path clean`), so it is an unknown action (exit 64).
	args := []string{"backup", "clean"}
	parsed := wayu.parse_args(args)
	defer if len(parsed.args) > 0 do delete(parsed.args)

	testing.expect_value(t, parsed.command, wayu.Command.BACKUP)
	testing.expect_value(t, parsed.action, wayu.Action.UNKNOWN)
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

// Global-flag position rules (see cli_parser.odin): flags inside the value
// tail of `alias add` / `const add` belong to the value.
@(test)
test_parse_args_alias_add_keeps_value_flags :: proc(t: ^testing.T) {
	saved_yes, saved_dry := wayu.wayu.yes_flag, wayu.wayu.dry_run
	defer {wayu.wayu.yes_flag = saved_yes; wayu.wayu.dry_run = saved_dry}
	wayu.wayu.yes_flag, wayu.wayu.dry_run = false, false

	args := []string{"alias", "add", "gpf", "git", "push", "-f", "-n", "-y"}
	parsed := wayu.parse_args(args)
	defer if len(parsed.args) > 0 do delete(parsed.args)

	testing.expect_value(t, parsed.action, wayu.Action.ADD)
	testing.expect_value(t, len(parsed.args), 6)
	testing.expect_value(t, parsed.args[3], "-f")
	testing.expect_value(t, parsed.args[5], "-y")
	testing.expect(t, !wayu.wayu.yes_flag, "-y in the value tail must not enable --yes")
	testing.expect(t, !wayu.wayu.dry_run, "-n in the value tail must not enable dry-run")
	testing.expect_value(t, parsed.source_filter, "wayu")
}

@(test)
test_parse_args_flags_before_value_still_global :: proc(t: ^testing.T) {
	saved_yes, saved_dry := wayu.wayu.yes_flag, wayu.wayu.dry_run
	defer {wayu.wayu.yes_flag = saved_yes; wayu.wayu.dry_run = saved_dry}
	wayu.wayu.dry_run = false

	args := []string{"-n", "const", "add", "-y", "FOO", "bar", "-n"}
	parsed := wayu.parse_args(args)
	defer if len(parsed.args) > 0 do delete(parsed.args)

	testing.expect(t, wayu.wayu.dry_run, "leading -n is global")
	testing.expect_value(t, len(parsed.args), 3)
	testing.expect_value(t, parsed.args[0], "FOO")
	testing.expect_value(t, parsed.args[2], "-n")
}

@(test)
test_parse_args_double_dash_terminator :: proc(t: ^testing.T) {
	saved_dry := wayu.wayu.dry_run
	defer wayu.wayu.dry_run = saved_dry
	wayu.wayu.dry_run = false

	args := []string{"alias", "add", "g", "--", "-n"}
	parsed := wayu.parse_args(args)
	defer if len(parsed.args) > 0 do delete(parsed.args)

	testing.expect(t, !wayu.wayu.dry_run, "flags after -- are literal")
	testing.expect_value(t, len(parsed.args), 2)
	testing.expect_value(t, parsed.args[1], "-n")

	testing.expect(
		t,
		!wayu.global_flag_present([]string{"alias", "add", "x", "echo", "--tui"}, "--tui"),
	)
	testing.expect(t, !wayu.global_flag_present([]string{"--", "--tui"}, "--tui"))
	testing.expect(
		t,
		wayu.global_flag_present([]string{"path", "list", "--no-color"}, "--no-color"),
	)
}

// Elsewhere flags still work in any position (path list --full).
@(test)
test_parse_args_trailing_flag_on_list :: proc(t: ^testing.T) {
	args := []string{"path", "list", "-f"}
	parsed := wayu.parse_args(args)
	defer if len(parsed.args) > 0 do delete(parsed.args)
	testing.expect_value(t, parsed.source_filter, "all")
	wayu.wayu.source_filter = "wayu"
}

// OKAMI-231: unknown dash tokens outside literal positions are reported.
@(test)
test_parse_args_unknown_flag_rejected :: proc(t: ^testing.T) {
	saved_dry := wayu.wayu.dry_run
	defer wayu.wayu.dry_run = saved_dry
	wayu.wayu.dry_run = false

	Case :: struct {
		args:    []string,
		unknown: string,
	}
	cases := []Case {
		{{"path", "add", "/tmp", "--dryrun"}, "--dryrun"},
		{{"path", "list", "--bogus"}, "--bogus"},
		{{"init", "--templat", "x"}, "--templat"},
		{{"init", "--template", "x"}, ""}, // OKAMI-241: documented
		{{"alias", "add", "--bogus", "x", "y"}, "--bogus"},
		// accepted: command-local, help, literal, add value, negative number
		{{"doctor", "--fix"}, ""},
		{{"plugin", "update", "--all"}, ""},
		{{"plugin", "search", "--category=git"}, ""},
		{{"export", "--eval"}, ""},
		{{"path", "list", "-h"}, ""},
		{{"path", "rm", "--", "-weird"}, ""},
		{{"const", "add", "OFF", "-5"}, ""},
		{{"plugin", "priority", "foo", "-1"}, ""},
		{{"alias", "add", "g", "grep", "-n", "--bogus"}, ""},
		{{"-c=header", "--weird"}, ""},
	}
	for c in cases {
		parsed := wayu.parse_args(c.args)
		testing.expectf(
			t,
			parsed.unknown_flag == c.unknown,
			"%v: got %q want %q",
			c.args,
			parsed.unknown_flag,
			c.unknown,
		)
		if len(parsed.args) > 0 do delete(parsed.args)
	}
	testing.expect(t, !wayu.wayu.dry_run, "--dryrun typo must not enable anything")
}

// OKAMI-233: export's documented flag forms select the mode.
@(test)
test_parse_args_export_modes :: proc(t: ^testing.T) {
	Case :: struct {
		args:   []string,
		action: wayu.Action,
	}
	cases := []Case {
		{{"export"}, .TURBO},
		{{"export", "--turbo"}, .TURBO},
		{{"export", "--eval"}, .EVAL},
		{{"export", "eval"}, .EVAL},
		{{"export", "--check"}, .CHECK},
		{{"export", "check"}, .CHECK},
		{{"export", "list"}, .LIST},
		{{"export", "bogus"}, .UNKNOWN},
	}
	for c in cases {
		parsed := wayu.parse_args(c.args)
		testing.expectf(
			t,
			parsed.action == c.action,
			"%v: got %v want %v",
			c.args,
			parsed.action,
			c.action,
		)
		if len(parsed.args) > 0 do delete(parsed.args)
	}
}

// OKAMI-231: a global long flag ending argv is a flag even in the add value.
@(test)
test_parse_args_trailing_long_flag_in_value :: proc(t: ^testing.T) {
	saved_dry := wayu.wayu.dry_run
	defer wayu.wayu.dry_run = saved_dry
	wayu.wayu.dry_run = false

	parsed := wayu.parse_args([]string{"alias", "add", "x", "y", "--dry-run"})
	defer if len(parsed.args) > 0 do delete(parsed.args)
	testing.expect(t, wayu.wayu.dry_run, "trailing --dry-run enables dry-run")
	testing.expect_value(t, len(parsed.args), 2)
	testing.expect_value(t, parsed.args[1], "y")
	testing.expect_value(t, parsed.ambiguous_tail_flag, "")
	testing.expect(
		t,
		wayu.global_flag_present([]string{"alias", "add", "x", "y", "--no-color"}, "--no-color"),
	)

	// After `--` it stays literal.
	wayu.wayu.dry_run = false
	p2 := wayu.parse_args([]string{"alias", "add", "x", "--", "y", "--dry-run"})
	defer if len(p2.args) > 0 do delete(p2.args)
	testing.expect(t, !wayu.wayu.dry_run, "--dry-run after -- is literal")
	testing.expect_value(t, p2.args[len(p2.args) - 1], "--dry-run")
	testing.expect(
		t,
		!wayu.global_flag_present(
			[]string{"alias", "add", "x", "--", "y", "--no-color"},
			"--no-color",
		),
	)

	// Short form stays in the value but is flagged for a warning.
	p3 := wayu.parse_args([]string{"alias", "add", "g", "grep", "-n"})
	defer if len(p3.args) > 0 do delete(p3.args)
	testing.expect(t, !wayu.wayu.dry_run, "trailing -n stays value")
	testing.expect_value(t, p3.ambiguous_tail_flag, "-n")
}
