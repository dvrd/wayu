package test_wayu

import "core:testing"
import "core:os"
import "core:strings"
import wayu "../src"

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
