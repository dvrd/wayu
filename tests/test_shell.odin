package test_wayu

import "core:testing"
import "core:strings"
import wayu "../src"

@(test)
test_shell_extension_bash :: proc(t: ^testing.T) {
	ext := wayu.get_shell_extension(.BASH)
	testing.expect_value(t, ext, "bash")
}

@(test)
test_shell_extension_zsh :: proc(t: ^testing.T) {
	ext := wayu.get_shell_extension(.ZSH)
	testing.expect_value(t, ext, "zsh")
}

@(test)
test_shell_extension_unknown :: proc(t: ^testing.T) {
	ext := wayu.get_shell_extension(.UNKNOWN)
	testing.expect_value(t, ext, "sh")
}

@(test)
test_get_shell_name :: proc(t: ^testing.T) {
	bash_name := wayu.get_shell_name(.BASH)
	testing.expect_value(t, bash_name, "Bash")

	zsh_name := wayu.get_shell_name(.ZSH)
	testing.expect_value(t, zsh_name, "ZSH")

	unknown_name := wayu.get_shell_name(.UNKNOWN)
	testing.expect_value(t, unknown_name, "Unknown")
}

@(test)
test_get_shebang :: proc(t: ^testing.T) {
	bash_shebang := wayu.get_shebang(.BASH)
	testing.expect_value(t, bash_shebang, "#!/usr/bin/env bash")

	zsh_shebang := wayu.get_shebang(.ZSH)
	testing.expect_value(t, zsh_shebang, "#!/usr/bin/env zsh")

	unknown_shebang := wayu.get_shebang(.UNKNOWN)
	testing.expect_value(t, unknown_shebang, "#!/bin/sh")
}

@(test)
test_shell_supports_arrays :: proc(t: ^testing.T) {
	testing.expect_value(t, wayu.shell_supports_arrays(.BASH), true)
	testing.expect_value(t, wayu.shell_supports_arrays(.ZSH), true)
	testing.expect_value(t, wayu.shell_supports_arrays(.UNKNOWN), false)
}

@(test)
test_shell_supports_completion :: proc(t: ^testing.T) {
	testing.expect_value(t, wayu.shell_supports_completion(.BASH), true)
	testing.expect_value(t, wayu.shell_supports_completion(.ZSH), true)
	testing.expect_value(t, wayu.shell_supports_completion(.UNKNOWN), false)
}

@(test)
test_shell_supports_functions :: proc(t: ^testing.T) {
	// All shells support functions
	testing.expect_value(t, wayu.shell_supports_functions(.BASH), true)
	testing.expect_value(t, wayu.shell_supports_functions(.ZSH), true)
	testing.expect_value(t, wayu.shell_supports_functions(.UNKNOWN), true)
}

@(test)
test_parse_shell_type :: proc(t: ^testing.T) {
	bash_type := wayu.parse_shell_type("bash")
	testing.expect_value(t, bash_type, wayu.ShellType.BASH)

	bash_upper := wayu.parse_shell_type("BASH")
	testing.expect_value(t, bash_upper, wayu.ShellType.BASH)

	zsh_type := wayu.parse_shell_type("zsh")
	testing.expect_value(t, zsh_type, wayu.ShellType.ZSH)

	zsh_upper := wayu.parse_shell_type("ZSH")
	testing.expect_value(t, zsh_upper, wayu.ShellType.ZSH)

	unknown_type := wayu.parse_shell_type("fish")
	testing.expect_value(t, unknown_type, wayu.ShellType.UNKNOWN)
}

@(test)
test_validate_shell_compatibility :: proc(t: ^testing.T) {
	// Test valid shells
	bash_valid, bash_msg := wayu.validate_shell_compatibility(.BASH)
	testing.expect_value(t, bash_valid, true)
	testing.expect_value(t, bash_msg, "")

	zsh_valid, zsh_msg := wayu.validate_shell_compatibility(.ZSH)
	testing.expect_value(t, zsh_valid, true)
	testing.expect_value(t, zsh_msg, "")

	// Test unknown shell
	unknown_valid, unknown_msg := wayu.validate_shell_compatibility(.UNKNOWN)
	testing.expect_value(t, unknown_valid, false)
	testing.expect(t, len(unknown_msg) > 0, "Unknown shell should have error message")
}

@(test)
test_get_path_template :: proc(t: ^testing.T) {
	bash_template := wayu.get_path_template(.BASH)
	testing.expect(t, strings.contains(bash_template, "#!/usr/bin/env bash"), "Bash template should have bash shebang")

	zsh_template := wayu.get_path_template(.ZSH)
	testing.expect(t, strings.contains(zsh_template, "#!/usr/bin/env zsh"), "ZSH template should have zsh shebang")
}

@(test)
test_get_aliases_template :: proc(t: ^testing.T) {
	bash_template := wayu.get_aliases_template(.BASH)
	testing.expect(t, strings.contains(bash_template, "#!/usr/bin/env bash"), "Bash template should have bash shebang")

	zsh_template := wayu.get_aliases_template(.ZSH)
	testing.expect(t, strings.contains(zsh_template, "#!/usr/bin/env zsh"), "ZSH template should have zsh shebang")
}

@(test)
test_get_constants_template :: proc(t: ^testing.T) {
	bash_template := wayu.get_constants_template(.BASH)
	testing.expect(t, strings.contains(bash_template, "#!/usr/bin/env bash"), "Bash template should have bash shebang")

	zsh_template := wayu.get_constants_template(.ZSH)
	testing.expect(t, strings.contains(zsh_template, "#!/usr/bin/env zsh"), "ZSH template should have zsh shebang")
}

@(test)
test_get_init_template :: proc(t: ^testing.T) {
	bash_template := wayu.get_init_template(.BASH)
	testing.expect(t, strings.contains(bash_template, "#!/usr/bin/env bash"), "Bash template should have bash shebang")
	testing.expect(t, strings.contains(bash_template, ".bash"), "Bash init should reference .bash files")

	zsh_template := wayu.get_init_template(.ZSH)
	testing.expect(t, strings.contains(zsh_template, "#!/usr/bin/env zsh"), "ZSH template should have zsh shebang")
	testing.expect(t, strings.contains(zsh_template, ".zsh"), "ZSH init should reference .zsh files")
}

@(test)
test_get_tools_template :: proc(t: ^testing.T) {
	bash_template := wayu.get_tools_template(.BASH)
	testing.expect(t, strings.contains(bash_template, "#!/usr/bin/env bash"), "Bash template should have bash shebang")
	testing.expect(t, strings.contains(bash_template, "starship init bash"), "Bash template should have bash-specific tool initialization")

	zsh_template := wayu.get_tools_template(.ZSH)
	testing.expect(t, strings.contains(zsh_template, "#!/usr/bin/env zsh"), "ZSH template should have zsh shebang")
	testing.expect(t, strings.contains(zsh_template, "starship init zsh"), "ZSH template should have zsh-specific tool initialization")
}

// Note: detect_shell() and get_rc_file_path() are environment-dependent
// and difficult to test without mocking. They would be tested in integration tests.