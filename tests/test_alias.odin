package test_wayu

import "core:testing"
import "core:strings"
import wayu "../src"

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
