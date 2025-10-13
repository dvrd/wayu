package test_wayu

import "core:testing"
import "core:os"
import "core:strings"
import wayu "../../src"

@(test)
test_init_config_file_creates_file :: proc(t: ^testing.T) {
	// Test creating a new config file
	test_file := "/tmp/test_wayu_config.zsh"
	test_template := "#!/usr/bin/env zsh\n# Test template"

	// Clean up first
	os.remove(test_file)

	result := wayu.init_config_file(test_file, test_template)
	defer os.remove(test_file)

	testing.expect(t, result, "init_config_file should succeed")
	testing.expect(t, os.exists(test_file), "File should be created")

	// Verify content
	content, ok := os.read_entire_file_from_filename(test_file)
	defer delete(content)
	testing.expect(t, ok, "Should be able to read created file")
	testing.expect_value(t, string(content), test_template)
}

@(test)
test_init_config_file_skips_existing :: proc(t: ^testing.T) {
	// Test that init_config_file doesn't overwrite existing files
	test_file := "/tmp/test_wayu_existing.zsh"
	original_content := "original content"

	// Create file with original content
	os.write_entire_file(test_file, transmute([]byte)original_content)
	defer os.remove(test_file)

	// Try to init with new template
	result := wayu.init_config_file(test_file, "new template")
	testing.expect(t, result, "init_config_file should return true for existing file")

	// Verify original content is preserved
	content, ok := os.read_entire_file_from_filename(test_file)
	defer delete(content)
	testing.expect(t, ok, "Should be able to read file")
	testing.expect_value(t, string(content), original_content)
}

@(test)
test_is_common_path :: proc(t: ^testing.T) {
	// Test common path detection
	testing.expect(t, wayu.is_common_path("/usr/local/bin"), "/usr/local/bin should be common")
	testing.expect(t, wayu.is_common_path("/usr/bin"), "/usr/bin should be common")
	testing.expect(t, wayu.is_common_path("/opt/homebrew/bin"), "/opt/homebrew/bin should be common")

	testing.expect(t, !wayu.is_common_path("/random/path"), "/random/path should not be common")
	testing.expect(t, !wayu.is_common_path("/tmp"), "/tmp should not be common")
}

@(test)
test_preload_path_template_exists :: proc(t: ^testing.T) {
	// Test that PATH_TEMPLATE constant exists and is not empty
	testing.expect(t, len(wayu.PATH_TEMPLATE) > 0, "PATH_TEMPLATE should not be empty")
	testing.expect(t, strings.contains(wayu.PATH_TEMPLATE, "add_to_path"), "Should contain add_to_path function")
}

@(test)
test_preload_aliases_template_exists :: proc(t: ^testing.T) {
	// Test that ALIASES_TEMPLATE constant exists and is not empty
	testing.expect(t, len(wayu.ALIASES_TEMPLATE) > 0, "ALIASES_TEMPLATE should not be empty")
	testing.expect(t, len(wayu.ALIASES_TEMPLATE_BASH) > 0, "ALIASES_TEMPLATE_BASH should not be empty")
}

@(test)
test_preload_constants_template_exists :: proc(t: ^testing.T) {
	// Test that CONSTANTS_TEMPLATE constant exists and is not empty
	testing.expect(t, len(wayu.CONSTANTS_TEMPLATE) > 0, "CONSTANTS_TEMPLATE should not be empty")
	testing.expect(t, len(wayu.CONSTANTS_TEMPLATE_BASH) > 0, "CONSTANTS_TEMPLATE_BASH should not be empty")
}

@(test)
test_preload_init_template_exists :: proc(t: ^testing.T) {
	// Test that INIT_TEMPLATE constant exists and is not empty
	testing.expect(t, len(wayu.INIT_TEMPLATE) > 0, "INIT_TEMPLATE should not be empty")
	testing.expect(t, strings.contains(wayu.INIT_TEMPLATE, "source"), "Init should contain source commands")
	testing.expect(t, len(wayu.INIT_TEMPLATE_BASH) > 0, "INIT_TEMPLATE_BASH should not be empty")
}

@(test)
test_preload_tools_template_exists :: proc(t: ^testing.T) {
	// Test that TOOLS_TEMPLATE constant exists and is not empty
	testing.expect(t, len(wayu.TOOLS_TEMPLATE) > 0, "TOOLS_TEMPLATE should not be empty")
	testing.expect(t, len(wayu.TOOLS_TEMPLATE_BASH) > 0, "TOOLS_TEMPLATE_BASH should not be empty")
}
