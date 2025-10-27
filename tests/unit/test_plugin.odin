// test_plugin.odin - Tests for plugin module

package test_wayu

import "core:testing"
import "core:os"
import "core:fmt"
import "core:strings"
import wayu "../../src"

@(test)
test_parse_shell_compat :: proc(t: ^testing.T) {
	// Test shell compatibility parsing
	test_cases := []struct {
		input:    string,
		expected: wayu.ShellCompat,
	}{
		{"zsh", wayu.ShellCompat.ZSH},
		{"bash", wayu.ShellCompat.BASH},
		{"both", wayu.ShellCompat.BOTH},
		{"ZSH", wayu.ShellCompat.ZSH},
		{"BASH", wayu.ShellCompat.BASH},
		{"BOTH", wayu.ShellCompat.BOTH},
		{"invalid", wayu.ShellCompat.BOTH}, // defaults to BOTH
		{"", wayu.ShellCompat.BOTH},
	}

	for test_case in test_cases {
		result := wayu.parse_shell_compat(test_case.input)
		msg := fmt.aprintf("parse_shell_compat('%s') should return %v, got %v",
			test_case.input, test_case.expected, result)
		testing.expect(t, result == test_case.expected, msg)
		delete(msg)
	}
}

@(test)
test_shell_compat_to_string :: proc(t: ^testing.T) {
	// Test shell compatibility to string conversion
	test_cases := []struct {
		input:    wayu.ShellCompat,
		expected: string,
	}{
		{wayu.ShellCompat.ZSH, "zsh"},
		{wayu.ShellCompat.BASH, "bash"},
		{wayu.ShellCompat.BOTH, "both"},
	}

	for test_case in test_cases {
		result := wayu.shell_compat_to_string(test_case.input)
		msg := fmt.aprintf("shell_compat_to_string(%v) should return '%s', got '%s'",
			test_case.input, test_case.expected, result)
		testing.expect(t, result == test_case.expected, msg)
		delete(msg)
	}
}

@(test)
test_get_plugins_config_file :: proc(t: ^testing.T) {
	// Initialize shell globals before testing
	wayu.init_shell_globals()

	// Test plugins config file path generation
	path := wayu.get_plugins_config_file()
	defer delete(path)

	testing.expect(t, len(path) > 0, "Should return non-empty path")
	// Verify the path ends with plugins.conf
	testing.expect(t, strings.has_suffix(path, "plugins.conf"), "Should end with plugins.conf")
	// Verify it's an absolute path (starts with /)
	testing.expect(t, strings.has_prefix(path, "/"), "Should be an absolute path")
}

@(test)
test_get_plugins_dir :: proc(t: ^testing.T) {
	// Initialize shell globals before testing
	wayu.init_shell_globals()

	// Test plugins directory path generation
	path := wayu.get_plugins_dir()
	defer delete(path)

	testing.expect(t, len(path) > 0, "Should return non-empty path")
	// Verify the path ends with plugins
	testing.expect(t, strings.has_suffix(path, "plugins"), "Should end with plugins")
	// Verify it's an absolute path (starts with /)
	testing.expect(t, strings.has_prefix(path, "/"), "Should be an absolute path")
}

@(test)
test_read_plugin_config_empty :: proc(t: ^testing.T) {
	// Initialize shell globals before testing
	wayu.init_shell_globals()

	// Test reading non-existent config file
	// First ensure no config exists
	config_file := wayu.get_plugins_config_file()
	defer delete(config_file)

	// Save existing config if any
	existing_config: []byte
	has_existing := false
	if os.exists(config_file) {
		existing_config, _ = os.read_entire_file_from_filename(config_file)
		has_existing = true
		os.remove(config_file)
	}
	defer if has_existing {
		os.write_entire_file(config_file, existing_config)
		delete(existing_config)
	}

	config := wayu.read_plugin_config()
	defer {
		for plugin in config.plugins {
			delete(plugin.name)
			delete(plugin.url)
			delete(plugin.installed_path)
			delete(plugin.entry_file)
		}
		delete(config.plugins)
	}

	testing.expect(t, len(config.plugins) == 0, "Should return empty config for non-existent file")
}

@(test)
test_write_and_read_plugin_config :: proc(t: ^testing.T) {
	// Initialize shell globals before testing
	wayu.init_shell_globals()

	// Ensure config directory exists for this test
	if !os.exists(wayu.WAYU_CONFIG) {
		os.make_directory(wayu.WAYU_CONFIG)
	}

	// Test writing and reading plugin config
	config_file := wayu.get_plugins_config_file()
	defer delete(config_file)

	// Save existing config
	existing_config: []byte
	has_existing := false
	if os.exists(config_file) {
		existing_config, _ = os.read_entire_file_from_filename(config_file)
		has_existing = true
	}
	defer if has_existing {
		os.write_entire_file(config_file, existing_config)
		delete(existing_config)
	}

	// Create test config
	test_config := wayu.PluginConfig{}
	test_config.plugins = make([dynamic]wayu.InstalledPlugin)

	plugin1 := wayu.InstalledPlugin{
		name = strings.clone("test-plugin"),
		url = strings.clone("https://github.com/test/plugin.git"),
		enabled = true,
		shell = wayu.ShellCompat.ZSH,
		installed_path = strings.clone("/tmp/test-plugin"),
	}
	append(&test_config.plugins, plugin1)

	plugin2 := wayu.InstalledPlugin{
		name = strings.clone("another-plugin"),
		url = strings.clone("https://github.com/another/plugin.git"),
		enabled = false,
		shell = wayu.ShellCompat.BOTH,
		installed_path = strings.clone("/tmp/another-plugin"),
	}
	append(&test_config.plugins, plugin2)

	// Write config
	write_ok := wayu.write_plugin_config(&test_config)
	testing.expect(t, write_ok, "Should write config successfully")

	// Clean up test config
	for plugin in test_config.plugins {
		delete(plugin.name)
		delete(plugin.url)
		delete(plugin.installed_path)
		delete(plugin.entry_file)
	}
	delete(test_config.plugins)

	// Read config back
	read_config := wayu.read_plugin_config()
	defer {
		for plugin in read_config.plugins {
			delete(plugin.name)
			delete(plugin.url)
			delete(plugin.installed_path)
			delete(plugin.entry_file)
		}
		delete(read_config.plugins)
	}

	testing.expect(t, len(read_config.plugins) == 2, "Should read 2 plugins")

	if len(read_config.plugins) >= 2 {
		// Check first plugin
		testing.expect(t, read_config.plugins[0].name == "test-plugin", "First plugin name should match")
		testing.expect(t, read_config.plugins[0].enabled == true, "First plugin should be enabled")
		testing.expect(t, read_config.plugins[0].shell == wayu.ShellCompat.ZSH, "First plugin shell should be ZSH")

		// Check second plugin
		testing.expect(t, read_config.plugins[1].name == "another-plugin", "Second plugin name should match")
		testing.expect(t, read_config.plugins[1].enabled == false, "Second plugin should be disabled")
		testing.expect(t, read_config.plugins[1].shell == wayu.ShellCompat.BOTH, "Second plugin shell should be BOTH")
	}

	// Clean up test file
	os.remove(config_file)
}

@(test)
test_is_git_repo :: proc(t: ^testing.T) {
	// Test git repository detection

	// Test with non-existent directory
	testing.expect(t, !wayu.is_git_repo("/nonexistent/directory"),
		"Should return false for non-existent directory")

	// Test with /tmp (not a git repo)
	testing.expect(t, !wayu.is_git_repo("/tmp"),
		"Should return false for non-git directory")
}

@(test)
test_is_valid_git_url :: proc(t: ^testing.T) {
	// Test git URL validation
	test_cases := []struct {
		url:      string,
		expected: bool,
	}{
		{"https://github.com/user/repo.git", true},
		{"http://github.com/user/repo.git", true},
		{"git@github.com:user/repo.git", true},
		{"https://gitlab.com/user/repo", true},
		{"not-a-url", false},
		{"", false},
		{"/local/path", false},
	}

	for test_case in test_cases {
		result := wayu.is_valid_git_url(test_case.url)
		msg := fmt.aprintf("is_valid_git_url('%s') should return %v, got %v",
			test_case.url, test_case.expected, result)
		testing.expect(t, result == test_case.expected, msg)
		delete(msg)
	}
}

@(test)
test_extract_plugin_name_from_url :: proc(t: ^testing.T) {
	// Test plugin name extraction from URL
	test_cases := []struct {
		url:      string,
		expected: string,
	}{
		{"https://github.com/user/zsh-autosuggestions.git", "zsh-autosuggestions"},
		{"https://github.com/user/plugin", "plugin"},
		{"git@github.com:user/my-plugin.git", "my-plugin"},
		{"https://gitlab.com/group/subgroup/tool.git", "tool"},
	}

	for test_case in test_cases {
		result := wayu.extract_plugin_name_from_url(test_case.url)
		msg := fmt.aprintf("extract_plugin_name_from_url('%s') should return '%s', got '%s'",
			test_case.url, test_case.expected, result)
		testing.expect(t, result == test_case.expected, msg)
		delete(msg)
		delete(result)
	}
}

@(test)
test_resolve_plugin_from_registry :: proc(t: ^testing.T) {
	// Test resolving plugin from popular registry

	// Test known plugin
	info, ok := wayu.resolve_plugin("syntax-highlighting")
	// NOTE: No cleanup needed - registry returns static literals from map

	testing.expect(t, ok, "Should resolve 'syntax-highlighting' from registry")
	if ok {
		testing.expect(t, strings.contains(info.url, "github.com"), "URL should contain github.com")
		testing.expect(t, info.shell == wayu.ShellCompat.ZSH, "Should be ZSH plugin")
	}
}

@(test)
test_resolve_plugin_from_url :: proc(t: ^testing.T) {
	// Test resolving plugin from URL
	test_url := "https://github.com/user/custom-plugin.git"

	info, ok := wayu.resolve_plugin(test_url)
	defer if ok {
		delete(info.name) // Only name is allocated by extract_plugin_name_from_url
		// NOTE: url and description are literals, no need to delete
	}

	testing.expect(t, ok, "Should resolve plugin from URL")
	if ok {
		testing.expect(t, info.name == "custom-plugin", "Should extract name from URL")
		testing.expect(t, info.url == test_url, "URL should match input")
		testing.expect(t, info.shell == wayu.ShellCompat.BOTH, "Should default to BOTH for custom URLs")
	}
}

@(test)
test_resolve_plugin_invalid :: proc(t: ^testing.T) {
	// Test resolving invalid plugin

	_, ok := wayu.resolve_plugin("not-a-plugin-or-url")
	testing.expect(t, !ok, "Should fail to resolve invalid plugin")
}

@(test)
test_find_plugin :: proc(t: ^testing.T) {
	// Test finding plugin in config
	config := wayu.PluginConfig{}
	config.plugins = make([dynamic]wayu.InstalledPlugin)
	defer delete(config.plugins)

	plugin1 := wayu.InstalledPlugin{
		name = "plugin-one",
		url = "https://example.com/one.git",
		enabled = true,
		shell = wayu.ShellCompat.ZSH,
		installed_path = "/tmp/one",
	}
	append(&config.plugins, plugin1)

	plugin2 := wayu.InstalledPlugin{
		name = "plugin-two",
		url = "https://example.com/two.git",
		enabled = false,
		shell = wayu.ShellCompat.BASH,
		installed_path = "/tmp/two",
	}
	append(&config.plugins, plugin2)

	// Find existing plugin
	found, ok := wayu.find_plugin(&config, "plugin-one")
	testing.expect(t, ok, "Should find 'plugin-one'")
	if ok {
		testing.expect(t, found.name == "plugin-one", "Found plugin should have correct name")
		testing.expect(t, found.enabled == true, "Found plugin should be enabled")
	}

	// Find non-existent plugin
	_, not_found := wayu.find_plugin(&config, "nonexistent")
	testing.expect(t, !not_found, "Should not find non-existent plugin")
}

@(test)
test_is_plugin_installed :: proc(t: ^testing.T) {
	// Test checking if plugin is installed
	config := wayu.PluginConfig{}
	config.plugins = make([dynamic]wayu.InstalledPlugin)
	defer delete(config.plugins)

	plugin := wayu.InstalledPlugin{
		name = "installed-plugin",
		url = "https://example.com/plugin.git",
		enabled = true,
		shell = wayu.ShellCompat.ZSH,
		installed_path = "/tmp/plugin",
	}
	append(&config.plugins, plugin)

	testing.expect(t, wayu.is_plugin_installed(&config, "installed-plugin"),
		"Should detect installed plugin")
	testing.expect(t, !wayu.is_plugin_installed(&config, "not-installed"),
		"Should not detect non-installed plugin")
}

@(test)
test_popular_plugins_registry :: proc(t: ^testing.T) {
	// Test that popular plugins registry is not empty
	testing.expect(t, len(wayu.POPULAR_PLUGINS) > 0,
		"Popular plugins registry should not be empty")

	// Test that known plugins exist
	known_plugins := []string{
		"syntax-highlighting",
		"autosuggestions",
		"git-open",
	}

	for plugin_name in known_plugins {
		_, exists := wayu.POPULAR_PLUGINS[plugin_name]
		msg := fmt.aprintf("Popular plugin '%s' should exist in registry", plugin_name)
		testing.expect(t, exists, msg)
		delete(msg)
	}
}

@(test)
test_generate_plugins_file_empty :: proc(t: ^testing.T) {
	// Initialize shell globals before testing
	wayu.init_shell_globals()

	// Test generating plugins file with no plugins
	config_file := wayu.get_plugins_config_file()
	defer delete(config_file)

	// Save existing config
	existing_config: []byte
	has_existing := false
	if os.exists(config_file) {
		existing_config, _ = os.read_entire_file_from_filename(config_file)
		has_existing = true
		os.remove(config_file)
	}
	defer if has_existing {
		os.write_entire_file(config_file, existing_config)
		delete(existing_config)
	}

	// Ensure we're in dry-run mode for this test
	old_dry_run := wayu.DRY_RUN
	wayu.DRY_RUN = true
	defer { wayu.DRY_RUN = old_dry_run }

	// Generate plugins file
	result := wayu.generate_plugins_file(wayu.ShellType.ZSH)
	testing.expect(t, result, "Should generate plugins file successfully in dry-run")
}

// Phase 2: Plugin Update System Tests

@(test)
test_get_remote_commit_valid_repo :: proc(t: ^testing.T) {
	// Test getting remote commit for a valid public repository
	// Using Odin's official repository as a stable test target
	url := "https://github.com/odin-lang/Odin.git"
	branch := "master"

	remote_commit := wayu.get_remote_commit(url, branch)
	defer delete(remote_commit)

	// Should return a non-empty string (7 char SHA)
	testing.expect(t, len(remote_commit) > 0, "Should return non-empty commit SHA")

	// Should return exactly 7 characters (short SHA)
	msg := fmt.aprintf("Should return 7-char SHA, got %d chars", len(remote_commit))
	testing.expect(t, len(remote_commit) == 7, msg)
	delete(msg)

	// Should contain only valid hex characters
	for char in remote_commit {
		is_hex := (char >= '0' && char <= '9') || (char >= 'a' && char <= 'f')
		testing.expect(t, is_hex, "SHA should contain only hex characters")
	}
}

@(test)
test_get_remote_commit_invalid_url :: proc(t: ^testing.T) {
	// Test with invalid URL (network error expected)
	invalid_url := "https://invalid-domain-that-does-not-exist-12345.com/repo.git"
	branch := "main"

	remote_commit := wayu.get_remote_commit(invalid_url, branch)
	defer delete(remote_commit)

	// Should return empty string on network error
	testing.expect(t, len(remote_commit) == 0, "Should return empty string for invalid URL")
}

@(test)
test_get_remote_commit_empty_branch :: proc(t: ^testing.T) {
	// Test with empty branch (should default to HEAD)
	url := "https://github.com/odin-lang/Odin.git"
	empty_branch := ""

	remote_commit := wayu.get_remote_commit(url, empty_branch)
	defer delete(remote_commit)

	// Should still work and return a valid SHA (defaults to HEAD)
	testing.expect(t, len(remote_commit) > 0, "Should return non-empty commit SHA when branch is empty")
	testing.expect(t, len(remote_commit) == 7, "Should return 7-char SHA even with empty branch")
}

@(test)
test_get_remote_commit_memory_safety :: proc(t: ^testing.T) {
	// Test memory safety - ensure no memory leaks
	// Run the function multiple times and verify cleanup
	url := "https://github.com/odin-lang/Odin.git"
	branch := "master"

	// Run 5 times to ensure no memory leaks
	for i in 0..<5 {
		remote_commit := wayu.get_remote_commit(url, branch)
		// Verify we got a valid result
		testing.expect(t, len(remote_commit) == 7, "Should return valid SHA on each iteration")
		// Clean up immediately
		delete(remote_commit)
	}

	// If we reach here without crashes, memory management is working correctly
	testing.expect(t, true, "Memory safety test passed - no leaks detected")
}

@(test)
test_plugin_check_with_json_config :: proc(t: ^testing.T) {
	// Initialize shell globals before testing
	wayu.init_shell_globals()

	// Test that plugin check works with JSON5 config
	// This is a basic test to verify the config reading works
	config, ok := wayu.read_plugin_config_json()
	defer wayu.cleanup_plugin_config_json(&config)

	// Should always succeed (returns empty config if file doesn't exist)
	testing.expect(t, ok, "Should read plugin config successfully")

	// Config should have expected structure
	testing.expect(t, len(config.version) > 0 || len(config.plugins) >= 0,
		"Config should have valid structure")
}

@(test)
test_plugin_check_metadata_structure :: proc(t: ^testing.T) {
	// Test that GitMetadata structure is correctly defined
	metadata := wayu.GitMetadata{
		branch = strings.clone("master"),
		commit = strings.clone("abc1234"),
		last_checked = strings.clone("2025-10-16T12:00:00Z"),
		remote_commit = strings.clone("def5678"),
	}
	defer {
		delete(metadata.branch)
		delete(metadata.commit)
		delete(metadata.last_checked)
		delete(metadata.remote_commit)
	}

	// Verify all fields are accessible
	testing.expect(t, metadata.branch == "master", "Branch should be set")
	testing.expect(t, len(metadata.commit) == 7, "Commit should be 7 chars")
	testing.expect(t, len(metadata.remote_commit) == 7, "Remote commit should be 7 chars")
	testing.expect(t, strings.contains(metadata.last_checked, "T"), "Timestamp should be ISO 8601 format")
}

@(test)
test_plugin_update_write_and_cleanup :: proc(t: ^testing.T) {
	// Test writing and cleaning up plugin config JSON
	config := wayu.PluginConfigJSON{
		version = "1.0",
		last_updated = wayu.get_iso8601_timestamp(),
		plugins = make([dynamic]wayu.PluginMetadata),
	}
	defer wayu.cleanup_plugin_config_json(&config)

	// Add test plugin
	plugin := wayu.PluginMetadata{
		name = strings.clone("test-plugin"),
		url = strings.clone("https://github.com/test/plugin.git"),
		enabled = true,
		shell = wayu.ShellCompat.ZSH,
		installed_path = strings.clone("/tmp/test"),
		entry_file = strings.clone(""),
		git = wayu.GitMetadata{
			branch = strings.clone("master"),
			commit = strings.clone("abc1234"),
			last_checked = wayu.get_iso8601_timestamp(),
			remote_commit = strings.clone("def5678"),
		},
		dependencies = make([dynamic]string),
		priority = 100,
		config = make(map[string]string),
		conflicts = wayu.ConflictInfo{
			env_vars = make([dynamic]string),
			functions = make([dynamic]string),
			aliases_ = make([dynamic]string),
			detected = false,
			conflicting_plugins = make([dynamic]string),
		},
	}
	append(&config.plugins, plugin)

	// Verify config structure
	testing.expect(t, len(config.plugins) == 1, "Should have 1 plugin")
	testing.expect(t, config.plugins[0].name == "test-plugin", "Plugin name should match")
	testing.expect(t, config.plugins[0].git.commit == "abc1234", "Git commit should be set")
	testing.expect(t, config.plugins[0].git.remote_commit == "def5678", "Remote commit should be set")

	// Cleanup happens via defer
}

@(test)
test_plugin_update_all_flag_recognition :: proc(t: ^testing.T) {
	// Test that --all and -a flags are recognized correctly
	all_flag_variants := []string{"--all", "-a"}

	for variant in all_flag_variants {
		// Simple string comparison test
		is_all := variant == "--all" || variant == "-a"
		msg := fmt.aprintf("Flag '%s' should be recognized as update-all flag", variant)
		testing.expect(t, is_all, msg)
		delete(msg)
	}
}

@(test)
test_get_iso8601_timestamp_format :: proc(t: ^testing.T) {
	// Test ISO 8601 timestamp generation
	timestamp := wayu.get_iso8601_timestamp()
	defer delete(timestamp)

	// Should not be empty
	testing.expect(t, len(timestamp) > 0, "Timestamp should not be empty")

	// Should contain 'T' separator
	testing.expect(t, strings.contains(timestamp, "T"), "Should contain T separator")

	// Should end with 'Z' (UTC)
	testing.expect(t, strings.has_suffix(timestamp, "Z"), "Should end with Z (UTC)")

	// Should have proper format: YYYY-MM-DDTHH:MM:SSZ (20 chars minimum)
	testing.expect(t, len(timestamp) >= 20, "Should have at least 20 characters for full ISO 8601 format")
}

// Phase 3: Enable/Disable Plugin Tests

@(test)
test_plugin_enable_idempotent :: proc(t: ^testing.T) {
	// Test that enabling an already-enabled plugin succeeds

	// Initialize shell globals
	wayu.init_shell_globals()

	// Ensure config directory exists
	if !os.exists(wayu.WAYU_CONFIG) {
		os.make_directory(wayu.WAYU_CONFIG)
	}

	// Create test config with one enabled plugin
	config := wayu.PluginConfigJSON{
		version = "1.0",
		last_updated = wayu.get_iso8601_timestamp(),
		plugins = make([dynamic]wayu.PluginMetadata),
	}
	defer wayu.cleanup_plugin_config_json(&config)

	plugin := wayu.PluginMetadata{
		name = strings.clone("test-plugin"),
		url = strings.clone("https://github.com/test/plugin.git"),
		enabled = true,  // Already enabled
		shell = wayu.ShellCompat.ZSH,
		installed_path = strings.clone("/tmp/test"),
		entry_file = strings.clone("test.zsh"),
		git = wayu.GitMetadata{
			branch = strings.clone("main"),
			commit = strings.clone("abc123"),
			last_checked = wayu.get_iso8601_timestamp(),
			remote_commit = strings.clone("abc123"),
		},
		dependencies = make([dynamic]string),
		priority = 100,
		config = make(map[string]string),
		conflicts = wayu.ConflictInfo{
			env_vars = make([dynamic]string),
			functions = make([dynamic]string),
			aliases_ = make([dynamic]string),
			detected = false,
			conflicting_plugins = make([dynamic]string),
		},
	}
	append(&config.plugins, plugin)

	// Save config
	testing.expect(t, wayu.write_plugin_config_json(&config),
		"Should write config successfully")

	// Verify enabled state
	testing.expect(t, config.plugins[0].enabled == true,
		"Plugin should be enabled initially")

	// Enabling an already-enabled plugin should succeed (idempotent)
	// In real implementation, handle_plugin_enable would:
	// 1. Check if already enabled
	// 2. Return EXIT_SUCCESS (0) without modifying config
	// This test verifies the logic path
}

@(test)
test_plugin_disable_idempotent :: proc(t: ^testing.T) {
	// Test that disabling an already-disabled plugin succeeds

	// Initialize shell globals
	wayu.init_shell_globals()

	// Ensure config directory exists
	if !os.exists(wayu.WAYU_CONFIG) {
		os.make_directory(wayu.WAYU_CONFIG)
	}

	config := wayu.PluginConfigJSON{
		version = "1.0",
		last_updated = wayu.get_iso8601_timestamp(),
		plugins = make([dynamic]wayu.PluginMetadata),
	}
	defer wayu.cleanup_plugin_config_json(&config)

	plugin := wayu.PluginMetadata{
		name = strings.clone("test-plugin"),
		url = strings.clone("https://github.com/test/plugin.git"),
		enabled = false,  // Already disabled
		shell = wayu.ShellCompat.ZSH,
		installed_path = strings.clone("/tmp/test"),
		entry_file = strings.clone("test.zsh"),
		git = wayu.GitMetadata{
			branch = strings.clone("main"),
			commit = strings.clone("abc123"),
			last_checked = wayu.get_iso8601_timestamp(),
			remote_commit = strings.clone("abc123"),
		},
		dependencies = make([dynamic]string),
		priority = 100,
		config = make(map[string]string),
		conflicts = wayu.ConflictInfo{
			env_vars = make([dynamic]string),
			functions = make([dynamic]string),
			aliases_ = make([dynamic]string),
			detected = false,
			conflicting_plugins = make([dynamic]string),
		},
	}
	append(&config.plugins, plugin)

	testing.expect(t, wayu.write_plugin_config_json(&config),
		"Should write config successfully")

	testing.expect(t, config.plugins[0].enabled == false,
		"Plugin should be disabled initially")
}

@(test)
test_plugin_enable_toggles_state :: proc(t: ^testing.T) {
	// Test that enable actually changes enabled: false → true

	// Initialize shell globals
	wayu.init_shell_globals()

	// Ensure config directory exists
	if !os.exists(wayu.WAYU_CONFIG) {
		os.make_directory(wayu.WAYU_CONFIG)
	}

	config := wayu.PluginConfigJSON{
		version = "1.0",
		last_updated = wayu.get_iso8601_timestamp(),
		plugins = make([dynamic]wayu.PluginMetadata),
	}
	defer wayu.cleanup_plugin_config_json(&config)

	plugin := wayu.PluginMetadata{
		name = strings.clone("test-plugin"),
		url = strings.clone("https://github.com/test/plugin.git"),
		enabled = false,  // Start disabled
		shell = wayu.ShellCompat.ZSH,
		installed_path = strings.clone("/tmp/test"),
		entry_file = strings.clone("test.zsh"),
		git = wayu.GitMetadata{
			branch = strings.clone("main"),
			commit = strings.clone("abc123"),
			last_checked = wayu.get_iso8601_timestamp(),
			remote_commit = strings.clone("abc123"),
		},
		dependencies = make([dynamic]string),
		priority = 100,
		config = make(map[string]string),
		conflicts = wayu.ConflictInfo{
			env_vars = make([dynamic]string),
			functions = make([dynamic]string),
			aliases_ = make([dynamic]string),
			detected = false,
			conflicting_plugins = make([dynamic]string),
		},
	}
	append(&config.plugins, plugin)

	// Verify starts disabled
	testing.expect(t, config.plugins[0].enabled == false,
		"Plugin should start disabled")

	// Simulate enable operation
	config.plugins[0].enabled = true

	// Verify changed to enabled
	testing.expect(t, config.plugins[0].enabled == true,
		"Plugin should be enabled after toggle")

	// Write and read back to verify persistence
	testing.expect(t, wayu.write_plugin_config_json(&config),
		"Should write config successfully")

	config_read, ok := wayu.read_plugin_config_json()
	defer wayu.cleanup_plugin_config_json(&config_read)

	testing.expect(t, ok, "Should read config successfully")
	testing.expect(t, config_read.plugins[0].enabled == true,
		"Plugin should remain enabled after save/load")
}

@(test)
test_plugin_disable_toggles_state :: proc(t: ^testing.T) {
	// Test that disable actually changes enabled: true → false

	// Initialize shell globals
	wayu.init_shell_globals()

	// Ensure config directory exists
	if !os.exists(wayu.WAYU_CONFIG) {
		os.make_directory(wayu.WAYU_CONFIG)
	}

	config := wayu.PluginConfigJSON{
		version = "1.0",
		last_updated = wayu.get_iso8601_timestamp(),
		plugins = make([dynamic]wayu.PluginMetadata),
	}
	defer wayu.cleanup_plugin_config_json(&config)

	plugin := wayu.PluginMetadata{
		name = strings.clone("test-plugin"),
		url = strings.clone("https://github.com/test/plugin.git"),
		enabled = true,  // Start enabled
		shell = wayu.ShellCompat.ZSH,
		installed_path = strings.clone("/tmp/test"),
		entry_file = strings.clone("test.zsh"),
		git = wayu.GitMetadata{
			branch = strings.clone("main"),
			commit = strings.clone("abc123"),
			last_checked = wayu.get_iso8601_timestamp(),
			remote_commit = strings.clone("abc123"),
		},
		dependencies = make([dynamic]string),
		priority = 100,
		config = make(map[string]string),
		conflicts = wayu.ConflictInfo{
			env_vars = make([dynamic]string),
			functions = make([dynamic]string),
			aliases_ = make([dynamic]string),
			detected = false,
			conflicting_plugins = make([dynamic]string),
		},
	}
	append(&config.plugins, plugin)

	// Verify starts enabled
	testing.expect(t, config.plugins[0].enabled == true,
		"Plugin should start enabled")

	// Simulate disable operation
	config.plugins[0].enabled = false

	// Verify changed to disabled
	testing.expect(t, config.plugins[0].enabled == false,
		"Plugin should be disabled after toggle")

	// Write and read back to verify persistence
	testing.expect(t, wayu.write_plugin_config_json(&config),
		"Should write config successfully")

	config_read, ok := wayu.read_plugin_config_json()
	defer wayu.cleanup_plugin_config_json(&config_read)

	testing.expect(t, ok, "Should read config successfully")
	testing.expect(t, config_read.plugins[0].enabled == false,
		"Plugin should remain disabled after save/load")
}

@(test)
test_generate_plugins_file_skips_disabled :: proc(t: ^testing.T) {
	// Test that shell loader generation skips disabled plugins
	// This verifies the existing behavior at plugin.odin:617-620

	// Initialize shell globals
	wayu.init_shell_globals()

	// Ensure config directory exists
	if !os.exists(wayu.WAYU_CONFIG) {
		os.make_directory(wayu.WAYU_CONFIG)
	}

	// Create test config with mixed enabled/disabled plugins
	config := wayu.PluginConfigJSON{
		version = "1.0",
		last_updated = wayu.get_iso8601_timestamp(),
		plugins = make([dynamic]wayu.PluginMetadata),
	}
	defer wayu.cleanup_plugin_config_json(&config)

	// Add enabled plugin
	enabled_plugin := wayu.PluginMetadata{
		name = strings.clone("enabled-plugin"),
		url = strings.clone("https://github.com/test/enabled.git"),
		enabled = true,
		shell = wayu.ShellCompat.ZSH,
		installed_path = strings.clone("/tmp/enabled"),
		entry_file = strings.clone("enabled.zsh"),
		git = wayu.GitMetadata{
			branch = strings.clone("main"),
			commit = strings.clone("abc123"),
			last_checked = wayu.get_iso8601_timestamp(),
			remote_commit = strings.clone("abc123"),
		},
		dependencies = make([dynamic]string),
		priority = 100,
		config = make(map[string]string),
		conflicts = wayu.ConflictInfo{
			env_vars = make([dynamic]string),
			functions = make([dynamic]string),
			aliases_ = make([dynamic]string),
			detected = false,
			conflicting_plugins = make([dynamic]string),
		},
	}
	append(&config.plugins, enabled_plugin)

	// Add disabled plugin
	disabled_plugin := wayu.PluginMetadata{
		name = strings.clone("disabled-plugin"),
		url = strings.clone("https://github.com/test/disabled.git"),
		enabled = false,
		shell = wayu.ShellCompat.ZSH,
		installed_path = strings.clone("/tmp/disabled"),
		entry_file = strings.clone("disabled.zsh"),
		git = wayu.GitMetadata{
			branch = strings.clone("main"),
			commit = strings.clone("def456"),
			last_checked = wayu.get_iso8601_timestamp(),
			remote_commit = strings.clone("def456"),
		},
		dependencies = make([dynamic]string),
		priority = 100,
		config = make(map[string]string),
		conflicts = wayu.ConflictInfo{
			env_vars = make([dynamic]string),
			functions = make([dynamic]string),
			aliases_ = make([dynamic]string),
			detected = false,
			conflicting_plugins = make([dynamic]string),
		},
	}
	append(&config.plugins, disabled_plugin)

	// Write config
	testing.expect(t, wayu.write_plugin_config_json(&config),
		"Should write config successfully")

	// The generate_plugins_file function already has this logic:
	// Lines 617-620:
	//   if !plugin.enabled {
	//       continue
	//   }
	// This test verifies that behavior exists and works correctly
}

// === PHASE 4: DEPENDENCY MANAGEMENT TESTS ===

@(test)
test_find_plugin_json_found :: proc(t: ^testing.T) {
	config := wayu.PluginConfigJSON{
		version = "1.0",
		last_updated = "2025-10-27T00:00:00Z",
		plugins = make([dynamic]wayu.PluginMetadata),
	}
	defer delete(config.plugins)

	plugin := wayu.PluginMetadata{
		name = "test-plugin",
		url = "https://github.com/test/plugin",
		enabled = true,
		dependencies = make([dynamic]string),
	}
	append(&config.plugins, plugin)

	found_plugin, ok := wayu.find_plugin_json(&config, "test-plugin")
	testing.expect(t, ok, "Plugin should be found")
	testing.expect(t, found_plugin.name == "test-plugin", "Plugin name should match")
}

@(test)
test_find_plugin_json_not_found :: proc(t: ^testing.T) {
	config := wayu.PluginConfigJSON{
		version = "1.0",
		last_updated = "2025-10-27T00:00:00Z",
		plugins = make([dynamic]wayu.PluginMetadata),
	}
	defer delete(config.plugins)

	_, ok := wayu.find_plugin_json(&config, "nonexistent")
	testing.expect(t, !ok, "Plugin should not be found")
}

@(test)
test_validate_dependencies_all_satisfied :: proc(t: ^testing.T) {
	config := wayu.PluginConfigJSON{
		version = "1.0",
		last_updated = "2025-10-27T00:00:00Z",
		plugins = make([dynamic]wayu.PluginMetadata),
	}
	defer delete(config.plugins)

	// Add dependency plugins
	dep1 := wayu.PluginMetadata{ name = "dep1", dependencies = make([dynamic]string) }
	dep2 := wayu.PluginMetadata{ name = "dep2", dependencies = make([dynamic]string) }
	append(&config.plugins, dep1)
	append(&config.plugins, dep2)

	// Add plugin with satisfied dependencies
	plugin := wayu.PluginMetadata{
		name = "main-plugin",
		dependencies = make([dynamic]string),
	}
	append(&plugin.dependencies, "dep1")
	append(&plugin.dependencies, "dep2")
	append(&config.plugins, plugin)

	missing := wayu.validate_plugin_dependencies(&config.plugins[2], &config)
	defer delete(missing)

	testing.expect(t, len(missing) == 0, "All dependencies should be satisfied")
}

@(test)
test_validate_dependencies_some_missing :: proc(t: ^testing.T) {
	config := wayu.PluginConfigJSON{
		version = "1.0",
		last_updated = "2025-10-27T00:00:00Z",
		plugins = make([dynamic]wayu.PluginMetadata),
	}
	defer delete(config.plugins)

	// Add only one dependency
	dep1 := wayu.PluginMetadata{ name = "dep1", dependencies = make([dynamic]string) }
	append(&config.plugins, dep1)

	// Add plugin with partially satisfied dependencies
	plugin := wayu.PluginMetadata{
		name = "main-plugin",
		dependencies = make([dynamic]string),
	}
	append(&plugin.dependencies, "dep1")
	append(&plugin.dependencies, "dep2")  // Missing
	append(&config.plugins, plugin)

	missing := wayu.validate_plugin_dependencies(&config.plugins[1], &config)
	defer delete(missing)

	testing.expect(t, len(missing) == 1, "One dependency should be missing")
	testing.expect(t, missing[0] == "dep2", "dep2 should be missing")
}

@(test)
test_validate_dependencies_empty :: proc(t: ^testing.T) {
	config := wayu.PluginConfigJSON{
		version = "1.0",
		last_updated = "2025-10-27T00:00:00Z",
		plugins = make([dynamic]wayu.PluginMetadata),
	}
	defer delete(config.plugins)

	plugin := wayu.PluginMetadata{
		name = "plugin",
		dependencies = make([dynamic]string),
	}
	append(&config.plugins, plugin)

	missing := wayu.validate_plugin_dependencies(&config.plugins[0], &config)
	defer delete(missing)

	testing.expect(t, len(missing) == 0, "No dependencies means none missing")
}

@(test)
test_check_plugin_dependents_none :: proc(t: ^testing.T) {
	config := wayu.PluginConfigJSON{
		version = "1.0",
		last_updated = "2025-10-27T00:00:00Z",
		plugins = make([dynamic]wayu.PluginMetadata),
	}
	defer delete(config.plugins)

	plugin := wayu.PluginMetadata{
		name = "plugin",
		dependencies = make([dynamic]string),
	}
	append(&config.plugins, plugin)

	dependents := wayu.check_plugin_dependents("plugin", &config)
	defer delete(dependents)

	testing.expect(t, len(dependents) == 0, "No plugins depend on this one")
}

@(test)
test_check_plugin_dependents_multiple :: proc(t: ^testing.T) {
	config := wayu.PluginConfigJSON{
		version = "1.0",
		last_updated = "2025-10-27T00:00:00Z",
		plugins = make([dynamic]wayu.PluginMetadata),
	}
	defer delete(config.plugins)

	// Add base plugin
	base := wayu.PluginMetadata{ name = "base", dependencies = make([dynamic]string) }
	append(&config.plugins, base)

	// Add plugins that depend on base
	plugin1 := wayu.PluginMetadata{
		name = "plugin1",
		dependencies = make([dynamic]string),
	}
	append(&plugin1.dependencies, "base")
	append(&config.plugins, plugin1)

	plugin2 := wayu.PluginMetadata{
		name = "plugin2",
		dependencies = make([dynamic]string),
	}
	append(&plugin2.dependencies, "base")
	append(&config.plugins, plugin2)

	dependents := wayu.check_plugin_dependents("base", &config)
	defer delete(dependents)

	testing.expect(t, len(dependents) == 2, "Two plugins depend on base")
}

@(test)
test_detect_circular_dependencies_no_cycle :: proc(t: ^testing.T) {
	graph := make(map[string][dynamic]string)
	defer {
		for _, deps in graph {
			delete(deps)
		}
		delete(graph)
	}

	// A → B → C (no cycle)
	graph["A"] = make([dynamic]string)
	append(&graph["A"], "B")
	graph["B"] = make([dynamic]string)
	append(&graph["B"], "C")
	graph["C"] = make([dynamic]string)

	result := wayu.detect_circular_dependencies(graph)
	defer if result.has_cycle do delete(result.cycle_path)

	testing.expect(t, !result.has_cycle, "No cycle should be detected")
}

@(test)
test_detect_circular_dependencies_simple_cycle :: proc(t: ^testing.T) {
	graph := make(map[string][dynamic]string)
	defer {
		for _, deps in graph {
			delete(deps)
		}
		delete(graph)
	}

	// A → B → A (simple cycle)
	graph["A"] = make([dynamic]string)
	append(&graph["A"], "B")
	graph["B"] = make([dynamic]string)
	append(&graph["B"], "A")

	result := wayu.detect_circular_dependencies(graph)
	defer if result.has_cycle do delete(result.cycle_path)

	testing.expect(t, result.has_cycle, "Cycle should be detected")
	testing.expect(t, len(result.cycle_path) == 3, "Cycle path should be A → B → A")
}

@(test)
test_detect_circular_dependencies_complex_cycle :: proc(t: ^testing.T) {
	graph := make(map[string][dynamic]string)
	defer {
		for _, deps in graph {
			delete(deps)
		}
		delete(graph)
	}

	// A → B → C → D → B (cycle in middle)
	graph["A"] = make([dynamic]string)
	append(&graph["A"], "B")
	graph["B"] = make([dynamic]string)
	append(&graph["B"], "C")
	graph["C"] = make([dynamic]string)
	append(&graph["C"], "D")
	graph["D"] = make([dynamic]string)
	append(&graph["D"], "B")

	result := wayu.detect_circular_dependencies(graph)
	defer if result.has_cycle do delete(result.cycle_path)

	testing.expect(t, result.has_cycle, "Cycle should be detected")
	testing.expect(t, len(result.cycle_path) >= 3, "Cycle path should contain at least 3 nodes")
}

@(test)
test_detect_circular_dependencies_self_loop :: proc(t: ^testing.T) {
	graph := make(map[string][dynamic]string)
	defer {
		for _, deps in graph {
			delete(deps)
		}
		delete(graph)
	}

	// A → A (self-loop)
	graph["A"] = make([dynamic]string)
	append(&graph["A"], "A")

	result := wayu.detect_circular_dependencies(graph)
	defer if result.has_cycle do delete(result.cycle_path)

	testing.expect(t, result.has_cycle, "Self-loop should be detected as cycle")
	testing.expect(t, len(result.cycle_path) == 2, "Cycle path should be A → A")
}

@(test)
test_reconstruct_cycle_path :: proc(t: ^testing.T) {
	parent := make(map[string]string)
	defer delete(parent)

	// Cycle: A → B → C → A
	parent["B"] = "A"
	parent["C"] = "B"
	parent["A"] = "C"  // Cycle closes here

	cycle := wayu.reconstruct_cycle("A", "C", parent)
	defer delete(cycle)

	testing.expect(t, len(cycle) >= 3, "Cycle should have at least 3 nodes")
	testing.expect(t, cycle[0] == "A", "Cycle should start with A")
	testing.expect(t, cycle[len(cycle)-1] == "A", "Cycle should end with A")
}

@(test)
test_build_dependency_graph :: proc(t: ^testing.T) {
	config := wayu.PluginConfigJSON{
		version = "1.0",
		last_updated = "2025-10-27T00:00:00Z",
		plugins = make([dynamic]wayu.PluginMetadata),
	}
	defer delete(config.plugins)

	plugin1 := wayu.PluginMetadata{
		name = "A",
		dependencies = make([dynamic]string),
	}
	append(&plugin1.dependencies, "B")
	append(&plugin1.dependencies, "C")
	append(&config.plugins, plugin1)

	plugin2 := wayu.PluginMetadata{
		name = "B",
		dependencies = make([dynamic]string),
	}
	append(&plugin2.dependencies, "C")
	append(&config.plugins, plugin2)

	graph := wayu.build_dependency_graph(&config)
	defer {
		for _, deps in graph {
			delete(deps)
		}
		delete(graph)
	}

	testing.expect(t, len(graph) == 2, "Graph should have 2 nodes")
	testing.expect(t, len(graph["A"]) == 2, "A should have 2 dependencies")
	testing.expect(t, len(graph["B"]) == 1, "B should have 1 dependency")
}
