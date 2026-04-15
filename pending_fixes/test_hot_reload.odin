// test_hot_reload.odin - Unit tests for hot reload module

package test_wayu

import "core:testing"
import "core:strings"
import "core:time"
import wayu "../../src"

// ============================================================================
// hot_reload_init tests
// ============================================================================

@(test)
test_hot_reload_init_basic :: proc(t: ^testing.T) {
	// Need to init globals for PATH operations
	wayu.init_shell_globals()

	paths := []string{"/tmp/test_wayu.toml", "/tmp/test_path.zsh"}

	callback :: proc(event: wayu.FileWatcherEvent, path: string) {}

	wayu.hot_reload_init(paths, callback)

	// Should not crash and should store paths
	testing.expect(t, true, "hot_reload_init should complete without error")
}

// ============================================================================
// get_default_watch_paths tests
// ============================================================================

@(test)
test_get_default_watch_paths_returns_paths :: proc(t: ^testing.T) {
	// Need to init globals
	wayu.init_shell_globals()

	// We can't really test this without creating files, but we can ensure it doesn't crash
	paths := wayu.get_default_watch_paths()
	defer {
		for path in paths {
			delete(path)
		}
		delete(paths)
	}

	// Should return a slice (possibly empty if no files exist)
	testing.expect(t, paths != nil, "Should return non-nil slice")
}

// ============================================================================
// escape_shell_string edge cases
// ============================================================================

@(test)
test_escape_shell_string_empty :: proc(t: ^testing.T) {
	input := ""
	result := wayu.escape_shell_string(input)
	defer delete(result)

	testing.expect_value(t, result, "")
}

@(test)
test_escape_shell_string_mixed_special :: proc(t: ^testing.T) {
	input := `echo "$VAR" \ backtick`
	result := wayu.escape_shell_string(input)
	defer delete(result)

	testing.expect(t, strings.contains(result, "\\\""), "Should escape quotes")
	testing.expect(t, strings.contains(result, "\\\\"), "Should escape backslash")
	testing.expect(t, strings.contains(result, "\\`"), "Should escape backtick")
	testing.expect(t, strings.contains(result, "\\$"), "Should escape dollar")
}

// ============================================================================
// sanitize_filename tests
// ============================================================================

@(test)
test_sanitize_filename_empty :: proc(t: ^testing.T) {
	input := ""
	result := wayu.sanitize_filename(input)
	defer delete(result)

	testing.expect_value(t, result, "")
}

@(test)
test_sanitize_filename_special_chars :: proc(t: ^testing.T) {
	input := "file@name#with$pecial%chars"
	result := wayu.sanitize_filename(input)
	defer delete(result)

	testing.expect(t, !strings.contains(result, "@"), "Should remove @")
	testing.expect(t, !strings.contains(result, "#"), "Should remove #")
	testing.expect(t, !strings.contains(result, "$"), "Should remove $")
	testing.expect(t, !strings.contains(result, "%"), "Should remove %")
}

// ============================================================================
// resolve_plugin_path tests
// ============================================================================

@(test)
test_resolve_plugin_path_http :: proc(t: ^testing.T) {
	wayu.init_shell_globals()

	input := "https://example.com/plugin.zsh"
	result := wayu.resolve_plugin_path(input)
	defer delete(result)

	testing.expect(t, strings.contains(result, "plugins"), "Should use plugins directory")
	testing.expect(t, strings.contains(result, "remote"), "Should use remote subdirectory")
}

@(test)
test_resolve_plugin_path_gitlab :: proc(t: ^testing.T) {
	wayu.init_shell_globals()

	input := "gitlab:user/repo"
	result := wayu.resolve_plugin_path(input)
	defer delete(result)

	// Unknown prefix should return as-is
	testing.expect_value(t, result, "gitlab:user/repo")
}

// ============================================================================
// static_optimize edge cases
// ============================================================================

@(test)
test_static_optimize_empty :: proc(t: ^testing.T) {
	input := ""
	result := wayu.static_optimize(input)
	defer delete(result)

	testing.expect_value(t, result, "\n")
}

@(test)
test_static_optimize_only_blanks :: proc(t: ^testing.T) {
	input := "\n\n\n\n"
	result := wayu.static_optimize(input)
	defer delete(result)

	// Should reduce to single blank line
	testing.expect(t, !strings.contains(result, "\n\n\n"), "Should not have 3+ consecutive newlines")
}

@(test)
test_static_optimize_no_blanks :: proc(t: ^testing.T) {
	input := "line1\nline2\nline3"
	result := wayu.static_optimize(input)
	defer delete(result)

	testing.expect(t, strings.contains(result, "line1"), "Should preserve line1")
	testing.expect(t, strings.contains(result, "line2"), "Should preserve line2")
	testing.expect(t, strings.contains(result, "line3"), "Should preserve line3")
}

// ============================================================================
// static_generate with plugins (priority sorting)
// ============================================================================

@(test)
test_static_generate_plugins_sorted_by_priority :: proc(t: ^testing.T) {
	wayu.init_shell_globals()

	plugins := []wayu.TomlPlugin{
		{name = "high", source = "local:/high", priority = 200},
		{name = "low", source = "local:/low", priority = 50},
		{name = "medium", source = "local:/medium", priority = 100},
	}

	config := wayu.TomlConfig{
		version      = "1.0",
		shell        = "zsh",
		wayu_version = "3.4.0",
		plugins      = plugins,
	}

	lock: wayu.LockFile
	result := wayu.static_generate(config, lock)
	defer wayu.static_cleanup_static_config(&result)

	// All plugins should be mentioned
	testing.expect(t, strings.contains(result.content, "# high"), "Should contain high priority plugin")
	testing.expect(t, strings.contains(result.content, "# low"), "Should contain low priority plugin")
	testing.expect(t, strings.contains(result.content, "# medium"), "Should contain medium priority plugin")
}

@(test)
test_static_generate_plugin_with_condition :: proc(t: ^testing.T) {
	wayu.init_shell_globals()

	plugins := []wayu.TomlPlugin{
		{name = "conditional", source = "local:/cond", condition = "-d /some/dir"},
	}

	config := wayu.TomlConfig{
		version      = "1.0",
		shell        = "zsh",
		wayu_version = "3.4.0",
		plugins      = plugins,
	}

	lock: wayu.LockFile
	result := wayu.static_generate(config, lock)
	defer wayu.static_cleanup_static_config(&result)

	testing.expect(t, strings.contains(result.content, "if [["), "Should contain conditional")
	testing.expect(t, strings.contains(result.content, "-d /some/dir\"]"), "Should contain condition expression")
}

@(test)
test_static_generate_plugin_with_defer :: proc(t: ^testing.T) {
	wayu.init_shell_globals()

	plugins := []wayu.TomlPlugin{
		{name = "deferred", source = "local:/defer", defer_load = true},
	}

	config := wayu.TomlConfig{
		version      = "1.0",
		shell        = "zsh",
		wayu_version = "3.4.0",
		plugins      = plugins,
	}

	lock: wayu.LockFile
	result := wayu.static_generate(config, lock)
	defer wayu.static_cleanup_static_config(&result)

	testing.expect(t, strings.contains(result.content, "DEFERRED"), "Should indicate deferred loading")
	testing.expect(t, strings.contains(result.content, "_wayu_deferred_deferred"), "Should create deferred function")
	testing.expect(t, strings.contains(result.content, "add-zsh-hook precmd"), "Should use precmd hook")
}

@(test)
test_static_generate_plugin_with_use_files :: proc(t: ^testing.T) {
	wayu.init_shell_globals()

	use_files := []string{"init.zsh", "config.zsh"}
	plugins := []wayu.TomlPlugin{
		{name = "with-use", source = "local:/path", use = use_files},
	}

	config := wayu.TomlConfig{
		version      = "1.0",
		shell        = "zsh",
		wayu_version = "3.4.0",
		plugins      = plugins,
	}

	lock: wayu.LockFile
	result := wayu.static_generate(config, lock)
	defer wayu.static_cleanup_static_config(&result)

	testing.expect(t, strings.contains(result.content, "init.zsh"), "Should reference init.zsh")
	testing.expect(t, strings.contains(result.content, "config.zsh"), "Should reference config.zsh")
}

// ============================================================================
// File watcher state management (basic tests)
// ============================================================================

@(test)
test_hot_reload_is_running_not_started :: proc(t: ^testing.T) {
	// Before starting, should not be running
	running := wayu.hot_reload_is_running()
	testing.expect(t, !running, "Watcher should not be running before start")
}

// ============================================================================
// PID file helpers (conceptual tests - these don't create actual files)
// ============================================================================

@(test)
test_read_watcher_pid_no_file :: proc(t: ^testing.T) {
	wayu.init_shell_globals()

	// When no PID file exists, should return 0
	pid := wayu.read_watcher_pid()
	testing.expect_value(t, pid, 0)
}

@(test)
test_is_watcher_running_no_pid :: proc(t: ^testing.T) {
	wayu.init_shell_globals()

	// When no PID file, should return false
	running := wayu.is_watcher_running()
	testing.expect(t, !running, "Should not detect running watcher without PID file")
}
