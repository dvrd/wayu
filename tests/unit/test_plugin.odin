// test_plugin.odin - Tests for plugin module

package test_wayu

import "core:testing"
import "core:os"
import "core:fmt"
import "core:strings"
import wayu "../src"

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
	testing.expect(t, strings.contains(path, ".config/wayu"), "Should contain wayu config dir")
	testing.expect(t, strings.has_suffix(path, "plugins.conf"), "Should end with plugins.conf")
}

@(test)
test_get_plugins_dir :: proc(t: ^testing.T) {
	// Initialize shell globals before testing
	wayu.init_shell_globals()

	// Test plugins directory path generation
	path := wayu.get_plugins_dir()
	defer delete(path)

	testing.expect(t, len(path) > 0, "Should return non-empty path")
	testing.expect(t, strings.contains(path, ".config/wayu"), "Should contain wayu config dir")
	testing.expect(t, strings.has_suffix(path, "plugins"), "Should end with plugins")
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
