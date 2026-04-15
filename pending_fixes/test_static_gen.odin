// test_static_gen.odin - Unit tests for static generation module

package test_wayu

import "core:testing"
import "core:strings"
import wayu "../../src"

// ============================================================================
// static_generate_path tests
// ============================================================================

@(test)
test_static_generate_path_empty :: proc(t: ^testing.T) {
	entries: []string = {}
	result := wayu.static_generate_path(entries)
	defer delete(result)

	testing.expect(t, len(result) == 0, "Empty entries should produce empty output")
}

@(test)
test_static_generate_path_single :: proc(t: ^testing.T) {
	entries := []string{"/usr/local/bin"}
	result := wayu.static_generate_path(entries)
	defer delete(result)

	testing.expect(t, len(result) > 0, "Should produce output")
	testing.expect(t, strings.contains(result, "WAYU_PATHS="), "Should contain array declaration")
	testing.expect(t, strings.contains(result, "/usr/local/bin"), "Should contain path")
}

@(test)
test_static_generate_path_multiple :: proc(t: ^testing.T) {
	entries := []string{"/usr/local/bin", "/opt/homebrew/bin", "$HOME/.cargo/bin"}
	result := wayu.static_generate_path(entries)
	defer delete(result)

	testing.expect(t, strings.contains(result, "WAYU_PATHS="), "Should contain array declaration")
	testing.expect(t, strings.contains(result, "/usr/local/bin"), "Should contain first path")
	testing.expect(t, strings.contains(result, "/opt/homebrew/bin"), "Should contain second path")
	testing.expect(t, strings.contains(result, "$HOME/.cargo/bin"), "Should contain third path")
}

@(test)
test_static_generate_path_escapes :: proc(t: ^testing.T) {
	entries := []string{"/path/with\"quote"}
	result := wayu.static_generate_path(entries)
	defer delete(result)

	testing.expect(t, strings.contains(result, "\\\""), "Should escape quotes")
}

// ============================================================================
// static_generate_aliases tests
// ============================================================================

@(test)
test_static_generate_aliases_empty :: proc(t: ^testing.T) {
	aliases: []wayu.TomlAlias = {}
	result := wayu.static_generate_aliases(aliases)
	defer delete(result)

	testing.expect(t, len(result) == 0, "Empty aliases should produce empty output")
}

@(test)
test_static_generate_aliases_single :: proc(t: ^testing.T) {
	aliases := []wayu.TomlAlias{
		{name = "ll", command = "ls -la"},
	}
	result := wayu.static_generate_aliases(aliases)
	defer delete(result)

	testing.expect(t, strings.contains(result, "alias ll="), "Should contain alias definition")
	testing.expect(t, strings.contains(result, "ls -la"), "Should contain command")
}

@(test)
test_static_generate_aliases_multiple :: proc(t: ^testing.T) {
	aliases := []wayu.TomlAlias{
		{name = "ll", command = "ls -la"},
		{name = "gc", command = "git commit"},
	}
	result := wayu.static_generate_aliases(aliases)
	defer delete(result)

	testing.expect(t, strings.contains(result, "alias ll="), "Should contain first alias")
	testing.expect(t, strings.contains(result, "alias gc="), "Should contain second alias")
}

@(test)
test_static_generate_aliases_with_description :: proc(t: ^testing.T) {
	aliases := []wayu.TomlAlias{
		{name = "ll", command = "ls -la", description = "List with details"},
	}
	result := wayu.static_generate_aliases(aliases)
	defer delete(result)

	testing.expect(t, strings.contains(result, "# List with details"), "Should contain description as comment")
	testing.expect(t, strings.contains(result, "alias ll="), "Should contain alias definition")
}

@(test)
test_static_generate_aliases_escapes_quotes :: proc(t: ^testing.T) {
	aliases := []wayu.TomlAlias{
		{name = "greet", command = `echo "hello"`},
	}
	result := wayu.static_generate_aliases(aliases)
	defer delete(result)

	testing.expect(t, strings.contains(result, `\"`), "Should escape quotes")
}

// ============================================================================
// static_generate_constants tests
// ============================================================================

@(test)
test_static_generate_constants_empty :: proc(t: ^testing.T) {
	constants: []wayu.TomlConstant = {}
	result := wayu.static_generate_constants(constants)
	defer delete(result)

	testing.expect(t, len(result) == 0, "Empty constants should produce empty output")
}

@(test)
test_static_generate_constants_export :: proc(t: ^testing.T) {
	constants := []wayu.TomlConstant{
		{name = "MY_VAR", value = "my_value", export = true},
	}
	result := wayu.static_generate_constants(constants)
	defer delete(result)

	testing.expect(t, strings.contains(result, "export MY_VAR="), "Should export variable")
	testing.expect(t, strings.contains(result, "my_value"), "Should contain value")
}

@(test)
test_static_generate_constants_local :: proc(t: ^testing.T) {
	constants := []wayu.TomlConstant{
		{name = "MY_VAR", value = "my_value", export = false},
	}
	result := wayu.static_generate_constants(constants)
	defer delete(result)

	testing.expect(t, strings.contains(result, "MY_VAR="), "Should contain variable")
	testing.expect(t, !strings.contains(result, "export MY_VAR="), "Should not export when export=false")
}

@(test)
test_static_generate_constants_secret :: proc(t: ^testing.T) {
	constants := []wayu.TomlConstant{
		{name = "API_KEY", value = "secret123", export = true, secret = true},
	}
	result := wayu.static_generate_constants(constants)
	defer delete(result)

	testing.expect(t, strings.contains(result, "API_KEY="), "Should contain variable")
	testing.expect(t, strings.contains(result, "secret"), "Should indicate secret")
}

// ============================================================================
// static_generate_plugins tests
// ============================================================================

@(test)
test_static_generate_plugins_empty :: proc(t: ^testing.T) {
	plugins: []wayu.TomlPlugin = {}
	result := wayu.static_generate_plugins(plugins)
	defer delete(result)

	testing.expect(t, len(result) == 0, "Empty plugins should produce empty output")
}

@(test)
test_static_generate_plugins_simple :: proc(t: ^testing.T) {
	plugins := []wayu.TomlPlugin{
		{name = "test-plugin", source = "local:/path/to/plugin"},
	}
	result := wayu.static_generate_plugins(plugins)
	defer delete(result)

	testing.expect(t, strings.contains(result, "# test-plugin"), "Should contain plugin comment")
}

// ============================================================================
// escape_shell_string tests
// ============================================================================

@(test)
test_escape_shell_string_basic :: proc(t: ^testing.T) {
	input := "hello world"
	result := wayu.escape_shell_string(input)
	defer delete(result)

	testing.expect_value(t, result, "hello world")
}

@(test)
test_escape_shell_string_quotes :: proc(t: ^testing.T) {
	input := `say "hello"`
	result := wayu.escape_shell_string(input)
	defer delete(result)

	testing.expect(t, strings.contains(result, `\"`), "Should escape double quotes")
}

@(test)
test_escape_shell_string_backslash :: proc(t: ^testing.T) {
	input := `path\to\file`
	result := wayu.escape_shell_string(input)
	defer delete(result)

	testing.expect(t, strings.contains(result, `\\`), "Should escape backslashes")
}

@(test)
test_escape_shell_string_dollar :: proc(t: ^testing.T) {
	input := "$HOME/bin"
	result := wayu.escape_shell_string(input)
	defer delete(result)

	testing.expect(t, strings.contains(result, `\$`), "Should escape dollar signs")
}

@(test)
test_escape_shell_string_backtick :: proc(t: ^testing.T) {
	input := "`echo test`"
	result := wayu.escape_shell_string(input)
	defer delete(result)

	testing.expect(t, strings.contains(result, "\\`"), "Should escape backticks")
}

// ============================================================================
// static_optimize tests
// ============================================================================

@(test)
test_static_optimize_removes_consecutive_blanks :: proc(t: ^testing.T) {
	input := "line1\n\n\nline2"
	result := wayu.static_optimize(input)
	defer delete(result)

	testing.expect(t, strings.contains(result, "line1\n\nline2"), "Should reduce multiple blanks to one")
	testing.expect(t, !strings.contains(result, "\n\n\n"), "Should not have 3 consecutive newlines")
}

@(test)
test_static_optimize_preserves_content :: proc(t: ^testing.T) {
	input := "export VAR=value\nalias ll='ls -la'"
	result := wayu.static_optimize(input)
	defer delete(result)

	testing.expect(t, strings.contains(result, "export VAR=value"), "Should preserve export")
	testing.expect(t, strings.contains(result, "alias ll='ls -la'"), "Should preserve alias")
}

// ============================================================================
// resolve_plugin_path tests
// ============================================================================

@(test)
test_resolve_plugin_path_local :: proc(t: ^testing.T) {
	input := "local:/path/to/plugin"
	result := wayu.resolve_plugin_path(input)
	defer delete(result)

	testing.expect_value(t, result, "/path/to/plugin")
}

@(test)
test_resolve_plugin_path_github :: proc(t: ^testing.T) {
	// Need WAYU_CONFIG to be set for this test
	wayu.init_shell_globals()

	input := "github:user/repo"
	result := wayu.resolve_plugin_path(input)
	defer delete(result)

	testing.expect(t, strings.contains(result, "plugins"), "Should contain plugins directory")
	testing.expect(t, strings.contains(result, "user-repo"), "Should have sanitized repo name")
}

@(test)
test_resolve_plugin_path_unknown :: proc(t: ^testing.T) {
	input := "/absolute/path"
	result := wayu.resolve_plugin_path(input)
	defer delete(result)

	testing.expect_value(t, result, "/absolute/path")
}

// ============================================================================
// sanitize_filename tests
// ============================================================================

@(test)
test_sanitize_filename_basic :: proc(t: ^testing.T) {
	input := "https://example.com/plugin.zsh"
	result := wayu.sanitize_filename(input)
	defer delete(result)

	testing.expect(t, !strings.contains(result, "/"), "Should remove slashes")
	testing.expect(t, !strings.contains(result, ":"), "Should remove colons")
}

@(test)
test_sanitize_filename_preserves_safe :: proc(t: ^testing.T) {
	input := "plugin-name_v1.0.txt"
	result := wayu.sanitize_filename(input)
	defer delete(result)

	testing.expect_value(t, result, "plugin-name_v1.0.txt")
}

// ============================================================================
// Integration: Full static_generate tests
// ============================================================================

@(test)
test_static_generate_complete :: proc(t: ^testing.T) {
	// Need to init globals for PATH and other operations
	wayu.init_shell_globals()

	config := wayu.TomlConfig{
		version      = "1.0",
		shell        = "zsh",
		wayu_version = "3.4.0",
		path         = wayu.TomlPathConfig{
			entries = {"/usr/local/bin", "$HOME/.cargo/bin"},
			dedup   = true,
			clean   = true,
		},
		aliases = {
			{name = "ll", command = "ls -la", description = "List all"},
		},
		constants = {
			{name = "EDITOR", value = "nvim", export = true},
		},
	}

	lock: wayu.LockFile
	result := wayu.static_generate(config, lock)
	defer wayu.static_cleanup_static_config(&result)

	testing.expect_value(t, result.shell, "zsh")
	testing.expect(t, strings.contains(result.content, "#!/usr/bin/env zsh"), "Should have correct shebang")
	testing.expect(t, strings.contains(result.content, "WAYU_PATHS="), "Should have PATH array")
	testing.expect(t, strings.contains(result.content, "alias ll="), "Should have alias")
	testing.expect(t, strings.contains(result.content, "export EDITOR="), "Should have constant")
	testing.expect(t, strings.contains(result.content, "Wayu Static Configuration"), "Should have header")
}

@(test)
test_static_generate_detects_shell_from_config :: proc(t: ^testing.T) {
	config := wayu.TomlConfig{
		version      = "1.0",
		shell        = "bash",
		wayu_version = "3.4.0",
	}

	lock: wayu.LockFile
	result := wayu.static_generate(config, lock)
	defer wayu.static_cleanup_static_config(&result)

	testing.expect_value(t, result.shell, "bash")
	testing.expect(t, strings.contains(result.content, "#!/usr/bin/env bash"), "Should have bash shebang")
}

@(test)
test_static_generate_defaults_to_zsh :: proc(t: ^testing.T) {
	config := wayu.TomlConfig{
		version      = "1.0",
		shell        = "", // Empty shell
		wayu_version = "3.4.0",
	}

	lock: wayu.LockFile
	result := wayu.static_generate(config, lock)
	defer wayu.static_cleanup_static_config(&result)

	testing.expect_value(t, result.shell, "zsh")
	testing.expect(t, strings.contains(result.content, "#!/usr/bin/env zsh"), "Should default to zsh")
}
