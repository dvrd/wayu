package test_wayu

import "core:fmt"
import "core:os"
import "core:testing"
import "core:strings"
import wayu "../../src"

@(test)
test_alias_parsing :: proc(t: ^testing.T) {
	test_config := `#!/usr/bin/env zsh

# Shell Aliases Configuration
alias ll="ls -la"
alias gc="git commit"
alias gs="git status"
`

	lines := strings.split(test_config, "\n")
	defer delete(lines)

	aliases_found := 0
	for line in lines {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "alias ") && strings.contains(trimmed, "=") {
			aliases_found += 1
		}
	}

	testing.expect_value(t, aliases_found, 3)
}

@(test)
test_alias_extraction :: proc(t: ^testing.T) {
	test_line := `alias ll="ls -la"`

	if strings.has_prefix(test_line, "alias ") && strings.contains(test_line, "=") {
		eq_pos := strings.index(test_line, "=")
		if eq_pos != -1 {
			name := test_line[6:eq_pos] // Skip "alias "
			value := test_line[eq_pos + 1:]

			testing.expect_value(t, name, "ll")

			// Clean quotes
			if strings.has_prefix(value, "\"") && strings.has_suffix(value, "\"") {
				value = value[1:len(value) - 1]
			}
			testing.expect_value(t, value, "ls -la")
		}
	}
}

@(test)
test_alias_with_spaces :: proc(t: ^testing.T) {
	test_cases := []string{
		`alias ll="ls -la"`,
		`alias gc="git commit -m"`,
		`    alias    gs="git status"   `,
	}

	expected_names := []string{"ll", "gc", "gs"}

	for test_case, i in test_cases {
		trimmed := strings.trim_space(test_case)
		if strings.has_prefix(trimmed, "alias ") && strings.contains(trimmed, "=") {
			eq_pos := strings.index(trimmed, "=")
			if eq_pos != -1 {
				name := trimmed[6:eq_pos]
				name = strings.trim_space(name)
				testing.expect_value(t, name, expected_names[i])
			}
		}
	}
}

@(test)
test_alias_format_validation :: proc(t: ^testing.T) {
	valid_lines := []string{
		`alias ll="ls -la"`,
		`alias gc='git commit'`,
		`alias test="echo test"`,
	}

	invalid_lines := []string{
		`# alias comment="test"`,
		`export VAR="value"`,
		`echo "alias"`,
		``,
	}

	for line in valid_lines {
		trimmed := strings.trim_space(line)
		is_valid := strings.has_prefix(trimmed, "alias ") &&
		            strings.contains(trimmed, "=") &&
		            !strings.has_prefix(trimmed, "#")
		testing.expect(t, is_valid, "Valid alias line should be recognized")
	}

	for line in invalid_lines {
		trimmed := strings.trim_space(line)
		is_valid := strings.has_prefix(trimmed, "alias ") &&
		            strings.contains(trimmed, "=") &&
		            !strings.has_prefix(trimmed, "#")
		testing.expect(t, !is_valid, "Invalid alias line should be rejected")
	}
}

@(test)
test_parse_args_alias_remove :: proc(t: ^testing.T) {
	args := []string{"alias", "rm", "ll"}
	parsed := wayu.parse_args(args)
	defer if len(parsed.args) > 0 do delete(parsed.args)
	testing.expect_value(t, parsed.command, wayu.Command.ALIAS)
	testing.expect_value(t, parsed.action, wayu.Action.REMOVE)
	testing.expect_value(t, len(parsed.args), 1)
}

@(test)
test_alias_command_with_quotes :: proc(t: ^testing.T) {
	test_line := `alias gs="git status --short"`
	testing.expect(t, strings.contains(test_line, "="), "Should contain equals")

	eq_pos := strings.index(test_line, "=")
	if eq_pos != -1 {
		command := test_line[eq_pos + 1:]
		testing.expect(t, strings.has_prefix(command, "\""), "Command should have quotes")
		testing.expect(t, strings.has_suffix(command, "\""), "Command should end with quotes")
	}
}

// ---------------------------------------------------------------------------
// alias_sources.odin tests
// ---------------------------------------------------------------------------

@(test)
test_path_basename_simple :: proc(t: ^testing.T) {
	testing.expect_value(t, wayu.path_basename("/home/user/patterns"), "patterns")
}

@(test)
test_path_basename_trailing_slash :: proc(t: ^testing.T) {
	testing.expect_value(t, wayu.path_basename("/home/user/patterns/"), "patterns")
}

@(test)
test_path_basename_no_slash :: proc(t: ^testing.T) {
	testing.expect_value(t, wayu.path_basename("patterns"), "patterns")
}

@(test)
test_path_basename_empty :: proc(t: ^testing.T) {
	testing.expect_value(t, wayu.path_basename(""), "")
}

@(test)
test_expand_home_with_tilde :: proc(t: ^testing.T) {
	home := os.get_env("HOME", context.allocator)
	defer delete(home)

	result := wayu.expand_home("~/foo/bar")
	defer delete(result)

	expected := strings.concatenate([]string{home, "/foo/bar"})
	defer delete(expected)

	testing.expect_value(t, result, expected)
}

@(test)
test_expand_home_no_tilde :: proc(t: ^testing.T) {
	result := wayu.expand_home("/absolute/path")
	defer delete(result)
	testing.expect_value(t, result, "/absolute/path")
}

@(test)
test_read_alias_sources_empty_file :: proc(t: ^testing.T) {
	// Set up temp config dir
	tmp_dir :: "/tmp/wayu-test-alias-sources"
	os.make_directory(tmp_dir)
	defer os.remove_all(tmp_dir)

	original := wayu.WAYU_CONFIG
	wayu.WAYU_CONFIG = tmp_dir
	defer wayu.WAYU_CONFIG = original

	// Write empty conf (only comments)
	conf_path := fmt.aprintf("%s/alias-sources.conf", tmp_dir)
	defer delete(conf_path)
	_ = os.write_entire_file(conf_path, transmute([]byte)string("# no sources here\n"))

	sources := wayu.read_alias_sources()
	defer wayu.cleanup_alias_sources(sources)

	testing.expect_value(t, len(sources), 0)
}

@(test)
test_read_alias_sources_missing_file :: proc(t: ^testing.T) {
	tmp_dir :: "/tmp/wayu-test-alias-sources-missing"
	os.make_directory(tmp_dir)
	defer os.remove_all(tmp_dir)

	original := wayu.WAYU_CONFIG
	wayu.WAYU_CONFIG = tmp_dir
	defer wayu.WAYU_CONFIG = original

	// No conf file written — should return nil gracefully
	sources := wayu.read_alias_sources()
	testing.expect(t, sources == nil, "Expected nil when conf file missing")
}

@(test)
test_read_alias_sources_parses_dir_entry :: proc(t: ^testing.T) {
	tmp_dir :: "/tmp/wayu-test-alias-sources-parse"
	os.make_directory(tmp_dir)
	defer os.remove_all(tmp_dir)

	original := wayu.WAYU_CONFIG
	wayu.WAYU_CONFIG = tmp_dir
	defer wayu.WAYU_CONFIG = original

	conf_path := fmt.aprintf("%s/alias-sources.conf", tmp_dir)
	defer delete(conf_path)
	conf_content := "dir /some/path/patterns mytool --run {name}\n"
	_ = os.write_entire_file(conf_path, transmute([]byte)string(conf_content))

	sources := wayu.read_alias_sources()
	defer wayu.cleanup_alias_sources(sources)

	testing.expect_value(t, len(sources), 1)
	testing.expect_value(t, sources[0].label, "patterns")
	testing.expect_value(t, sources[0].path, "/some/path/patterns")
	testing.expect_value(t, sources[0].command_template, "mytool --run {name}")
}

@(test)
test_read_alias_sources_skips_unknown_type :: proc(t: ^testing.T) {
	tmp_dir :: "/tmp/wayu-test-alias-sources-skip"
	os.make_directory(tmp_dir)
	defer os.remove_all(tmp_dir)

	original := wayu.WAYU_CONFIG
	wayu.WAYU_CONFIG = tmp_dir
	defer wayu.WAYU_CONFIG = original

	conf_path := fmt.aprintf("%s/alias-sources.conf", tmp_dir)
	defer delete(conf_path)
	// "file" type is not supported yet — should be skipped
	conf_content := "file /some/path/aliases.sh\n"
	_ = os.write_entire_file(conf_path, transmute([]byte)string(conf_content))

	sources := wayu.read_alias_sources()
	defer wayu.cleanup_alias_sources(sources)

	testing.expect_value(t, len(sources), 0)
}
