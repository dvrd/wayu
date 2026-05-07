package test_wayu

import "core:testing"
import "core:strings"
import wayu "../../src"

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
test_shell_extension_fish :: proc(t: ^testing.T) {
	ext := wayu.get_shell_extension(.FISH)
	testing.expect_value(t, ext, "fish")
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

	fish_name := wayu.get_shell_name(.FISH)
	testing.expect_value(t, fish_name, "Fish")

	unknown_name := wayu.get_shell_name(.UNKNOWN)
	testing.expect_value(t, unknown_name, "Unknown")
}

@(test)
test_get_shebang :: proc(t: ^testing.T) {
	bash_shebang := wayu.get_shebang(.BASH)
	testing.expect_value(t, bash_shebang, "#!/usr/bin/env bash")

	zsh_shebang := wayu.get_shebang(.ZSH)
	testing.expect_value(t, zsh_shebang, "#!/usr/bin/env zsh")

	fish_shebang := wayu.get_shebang(.FISH)
	testing.expect_value(t, fish_shebang, "#!/usr/bin/env fish")

	unknown_shebang := wayu.get_shebang(.UNKNOWN)
	testing.expect_value(t, unknown_shebang, "#!/bin/sh")
}

@(test)
test_shell_supports_arrays :: proc(t: ^testing.T) {
	testing.expect_value(t, wayu.shell_supports_arrays(.BASH), true)
	testing.expect_value(t, wayu.shell_supports_arrays(.ZSH), true)
	testing.expect_value(t, wayu.shell_supports_arrays(.FISH), true)
	testing.expect_value(t, wayu.shell_supports_arrays(.UNKNOWN), false)
}

@(test)
test_shell_supports_completion :: proc(t: ^testing.T) {
	testing.expect_value(t, wayu.shell_supports_completion(.BASH), true)
	testing.expect_value(t, wayu.shell_supports_completion(.ZSH), true)
	testing.expect_value(t, wayu.shell_supports_completion(.FISH), true)
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

	fish_type := wayu.parse_shell_type("fish")
	testing.expect_value(t, fish_type, wayu.ShellType.FISH)

	fish_upper := wayu.parse_shell_type("FISH")
	testing.expect_value(t, fish_upper, wayu.ShellType.FISH)

	unknown_type := wayu.parse_shell_type("tcsh")
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

	fish_valid, fish_msg := wayu.validate_shell_compatibility(.FISH)
	testing.expect_value(t, fish_valid, true)
	testing.expect_value(t, fish_msg, "")

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
	// tools.{zsh,bash} is the user escape hatch for tool init that the
	// declarative [tools] table in wayu.toml doesn't model. Verify the
	// shebang is correct and the template points users at [tools].
	bash_template := wayu.get_tools_template(.BASH)
	testing.expect(t, strings.contains(bash_template, "#!/usr/bin/env bash"), "Bash template should have bash shebang")
	testing.expect(t, strings.contains(bash_template, "[tools]") ||
	               strings.contains(bash_template, "starship init bash"),
	               "Bash template should reference [tools] (or keep a starship example for legacy users)")

	zsh_template := wayu.get_tools_template(.ZSH)
	testing.expect(t, strings.contains(zsh_template, "#!/usr/bin/env zsh"), "ZSH template should have zsh shebang")
	testing.expect(t, strings.contains(zsh_template, "[tools]"),
	               "ZSH template should point users at the declarative [tools] table")
}

// Regression test for D2: verify get_*_template routes all four ShellType
// variants correctly after collapsing the six near-identical getters into a
// shared `select_template` dispatch helper. See thoughts/code_review_2026-04-24.md D2.
@(test)
test_template_routing_all_shells :: proc(t: ^testing.T) {
	// Fish routing was not covered by the existing per-getter tests.
	fish_path := wayu.get_path_template(.FISH)
	testing.expect(t, strings.contains(fish_path, "#!/usr/bin/env fish") ||
	                  strings.contains(fish_path, "fish_user_paths"),
	                  "Fish path template should be the fish-specific one")

	fish_aliases := wayu.get_aliases_template(.FISH)
	testing.expect(t, len(fish_aliases) > 0, "Fish aliases template should be non-empty")

	fish_init := wayu.get_init_template(.FISH)
	testing.expect(t, strings.contains(fish_init, "fish") || strings.contains(fish_init, ".fish"),
	                  "Fish init template should mention fish")

	// UNKNOWN must fall back to Bash template (matches pre-refactor behavior).
	unknown_path := wayu.get_path_template(.UNKNOWN)
	bash_path := wayu.get_path_template(.BASH)
	testing.expect(t, unknown_path == bash_path,
	                  "UNKNOWN must fall back to the Bash template")

	unknown_extra := wayu.get_extra_template(.UNKNOWN)
	bash_extra := wayu.get_extra_template(.BASH)
	testing.expect(t, unknown_extra == bash_extra,
	                  "UNKNOWN extra must fall back to the Bash extra template")
}

// Note: detect_shell() and get_rc_file_path() are environment-dependent
// and difficult to test without mocking. They would be tested in integration tests.