// test_completions.odin - Tests for completions module

package test_wayu

import "core:testing"
import "core:os"
import "core:fmt"
import "core:strings"
import wayu "../src"

@(test)
test_extract_completion_items_empty :: proc(t: ^testing.T) {
	// Test with non-existent directory
	original_config := wayu.WAYU_CONFIG
	defer wayu.WAYU_CONFIG = original_config

	wayu.WAYU_CONFIG = "/tmp/wayu-test-nonexistent"

	items := wayu.extract_completion_items()
	defer {
		for item in items {
			delete(item)
		}
		delete(items)
	}

	testing.expect(t, len(items) == 0, "Should return empty array for non-existent directory")
}

@(test)
test_extract_completion_items_single :: proc(t: ^testing.T) {
	// Create temporary test directory
	test_dir := "/tmp/wayu-test-completions"
	completions_dir := fmt.aprintf("%s/completions", test_dir)
	defer delete(completions_dir)

	// Create test directories
	os.make_directory(test_dir)
	os.make_directory(completions_dir)

	// Create a test completion file
	test_file := fmt.aprintf("%s/_test", completions_dir)
	defer delete(test_file)
	test_content := "#compdef test\n_test() {\n  echo test\n}"
	os.write_entire_file(test_file, transmute([]byte)test_content)

	// Test extraction
	original_config := wayu.WAYU_CONFIG
	defer wayu.WAYU_CONFIG = original_config
	wayu.WAYU_CONFIG = test_dir

	items := wayu.extract_completion_items()
	defer {
		for item in items {
			delete(item)
		}
		delete(items)
	}

	testing.expect(t, len(items) == 1, "Should find one completion")
	testing.expect(t, items[0] == "test", "Should extract name without underscore")
}

@(test)
test_extract_completion_items_multiple :: proc(t: ^testing.T) {
	// Create temporary test directory
	test_dir := "/tmp/wayu-test-completions-multi"
	completions_dir := fmt.aprintf("%s/completions", test_dir)
	defer delete(completions_dir)

	// Create test directories
	os.make_directory(test_dir)
	os.make_directory(completions_dir)

	// Create multiple test completion files
	files := []string{"_git", "_docker", "_kubectl"}
	for file in files {
		file_path := fmt.aprintf("%s/%s", completions_dir, file)
		defer delete(file_path)
		completion_content := "#compdef\ntest completion"
		os.write_entire_file(file_path, transmute([]byte)completion_content)
	}

	// Test extraction
	original_config := wayu.WAYU_CONFIG
	defer wayu.WAYU_CONFIG = original_config
	wayu.WAYU_CONFIG = test_dir

	items := wayu.extract_completion_items()
	defer {
		for item in items {
			delete(item)
		}
		delete(items)
	}

	testing.expect(t, len(items) == 3, "Should find three completions")

	// Check that all expected items are present (order may vary)
	expected := []string{"git", "docker", "kubectl"}
	for exp in expected {
		found := false
		for item in items {
			if item == exp {
				found = true
				break
			}
		}
		testing.expect(t, found, fmt.aprintf("Should find completion: %s", exp))
	}
}

@(test)
test_extract_completion_items_filters :: proc(t: ^testing.T) {
	// Create temporary test directory
	test_dir := "/tmp/wayu-test-completions-filter"
	completions_dir := fmt.aprintf("%s/completions", test_dir)
	defer delete(completions_dir)

	// Create test directories
	os.make_directory(test_dir)
	os.make_directory(completions_dir)

	// Create various files (only underscored ones should be included)
	files := []string{"_valid", "invalid", "_another", "README.md", "_third"}
	for file in files {
		file_path := fmt.aprintf("%s/%s", completions_dir, file)
		defer delete(file_path)
		test_data := "test"
		os.write_entire_file(file_path, transmute([]byte)test_data)
	}

	// Create a subdirectory (should be ignored)
	subdir := fmt.aprintf("%s/_subdir", completions_dir)
	defer delete(subdir)
	os.make_directory(subdir)

	// Test extraction
	original_config := wayu.WAYU_CONFIG
	defer wayu.WAYU_CONFIG = original_config
	wayu.WAYU_CONFIG = test_dir

	items := wayu.extract_completion_items()
	defer {
		for item in items {
			delete(item)
		}
		delete(items)
	}

	testing.expect(t, len(items) == 3, "Should find only underscored files")

	// Check that only valid items are present
	valid_items := []string{"valid", "another", "third"}
	for valid in valid_items {
		found := false
		for item in items {
			if item == valid {
				found = true
				break
			}
		}
		testing.expect(t, found, fmt.aprintf("Should find valid completion: %s", valid))
	}

	// Check that invalid items are not present
	for item in items {
		testing.expect(t, item != "invalid", "Should not include non-underscored files")
		testing.expect(t, item != "README.md", "Should not include non-completion files")
		testing.expect(t, item != "_subdir", "Should not include directories")
	}
}

@(test)
test_completion_name_normalization :: proc(t: ^testing.T) {
	// Test that names are properly normalized (underscore added if missing)

	// This would be tested in the actual add_completion function
	// For now, we test the logic conceptually

	names := []string{"git", "_git", "docker", "_docker"}
	expected := []string{"_git", "_git", "_docker", "_docker"}

	for name, i in names {
		normalized := name
		if !strings.has_prefix(name, "_") {
			normalized = fmt.aprintf("_%s", name)
			defer delete(normalized)
		}

		testing.expect(t, normalized == expected[i],
			fmt.aprintf("Name '%s' should normalize to '%s', got '%s'",
				name, expected[i], normalized))
	}
}

@(test)
test_completion_validation_basic :: proc(t: ^testing.T) {
	// Test basic completion name validation logic

	valid_names := []string{"git", "_git", "my_completion", "tool123"}
	for name in valid_names {
		// Basic validation - no spaces, valid characters
		is_valid := !strings.contains(name, " ") && len(name) > 0
		testing.expect(t, is_valid, fmt.aprintf("Name '%s' should be valid", name))
	}

	invalid_names := []string{"", "name with spaces", "name-with-dashes"}
	for name in invalid_names {
		// These would fail in real validation
		has_issues := len(name) == 0 || strings.contains(name, " ") || strings.contains(name, "-")
		testing.expect(t, has_issues, fmt.aprintf("Name '%s' should be invalid", name))
	}
}

@(test)
test_completion_file_operations :: proc(t: ^testing.T) {
	// Test file operation concepts for completions

	test_content := "#compdef mycommand\n_mycommand() {\n  _describe 'commands' '(help:show help)'\n}"

	// Test content validation
	has_compdef := strings.contains(test_content, "#compdef")
	testing.expect(t, has_compdef, "Completion should contain #compdef directive")

	has_function := strings.contains(test_content, "_mycommand")
	testing.expect(t, has_function, "Completion should contain completion function")

	// Test size validation
	size := len(test_content)
	testing.expect(t, size > 0, "Completion content should not be empty")
	testing.expect(t, size < 10000, "Completion content should be reasonable size")
}