// test_backup.odin - Tests for backup module

package test_wayu

import "core:testing"
import "core:os"
import "core:fmt"
import "core:strings"
import "core:time"
import wayu "../../src"

@(test)
test_create_backup_nonexistent_file :: proc(t: ^testing.T) {
	// Test backup of non-existent file should succeed (no backup needed)
	fake_file := "/tmp/wayu-test-nonexistent-file"

	backup_path, ok := wayu.create_backup(fake_file)
	defer if len(backup_path) > 0 do delete(backup_path)

	testing.expect(t, ok, "Should succeed for non-existent file")
	testing.expect(t, backup_path == "", "Should return empty path for non-existent file")
}

@(test)
test_create_backup_existing_file :: proc(t: ^testing.T) {
	// Create a temporary file
	test_content := "test backup content\nline 2\n"
	test_file := "/tmp/wayu-test-backup-source"

	os.write_entire_file(test_file, transmute([]byte)test_content)
	defer os.remove(test_file)

	// Create backup
	backup_path, ok := wayu.create_backup(test_file)
	defer if ok do delete(backup_path)
	defer if ok do os.remove(backup_path)

	testing.expect(t, ok, "Should create backup successfully")
	testing.expect(t, len(backup_path) > 0, "Should return backup path")
	testing.expect(t, strings.contains(backup_path, ".backup."), "Backup should have .backup. in name")

	// Verify backup content
	if ok {
		backup_content, read_ok := os.read_entire_file_from_filename(backup_path)
		if read_ok {
			defer delete(backup_content)
			testing.expect(t, string(backup_content) == test_content, "Backup content should match original")
		}
	}
}

@(test)
test_parse_timestamp :: proc(t: ^testing.T) {
	// Test timestamp parsing
	timestamp_str := "1640995200" // 2022-01-01 00:00:00 UTC
	parsed_time := wayu.parse_timestamp(timestamp_str)

	// Check that it parsed to a reasonable time
	unix_time := parsed_time._nsec / 1_000_000_000
	testing.expect(t, unix_time == 1640995200, "Should parse timestamp correctly")

	// Test invalid timestamp
	invalid_timestamp := "abc123"
	parsed_invalid := wayu.parse_timestamp(invalid_timestamp)
	unix_invalid := parsed_invalid._nsec / 1_000_000_000
	testing.expect(t, unix_invalid == 0, "Should handle invalid timestamp")
}

@(test)
test_get_directory_path :: proc(t: ^testing.T) {
	// Test directory path extraction
	test_cases := []struct {
		input:    string,
		expected: string,
	}{
		{"/home/user/file.txt", "/home/user"},
		{"/tmp/test.conf", "/tmp"},
		{"file.txt", "."},
		{"/file.txt", ""},
	}

	for test_case in test_cases {
		result := wayu.get_directory_path(test_case.input)
		msg := fmt.aprintf("get_directory_path('%s') should return '%s', got '%s'",
			test_case.input, test_case.expected, result)
		testing.expect(t, result == test_case.expected, msg)
		delete(msg)
	}
}

@(test)
test_get_base_name :: proc(t: ^testing.T) {
	// Test base name extraction
	test_cases := []struct {
		input:    string,
		expected: string,
	}{
		{"/home/user/file.txt", "file.txt"},
		{"/tmp/test.conf", "test.conf"},
		{"file.txt", "file.txt"},
		{"/file.txt", "file.txt"},
	}

	for test_case in test_cases {
		result := wayu.get_base_name(test_case.input)
		msg := fmt.aprintf("get_base_name('%s') should return '%s', got '%s'",
			test_case.input, test_case.expected, result)
		testing.expect(t, result == test_case.expected, msg)
		delete(msg)
	}
}

@(test)
test_format_backup_time :: proc(t: ^testing.T) {
	// Test time formatting
	// Create a known time: 2022-01-01 12:30:45
	test_time := time.unix(1640995845, 0) // 2022-01-01 12:30:45 UTC

	formatted := wayu.format_backup_time(test_time)
	defer delete(formatted)

	// Should format as YYYY-MM-DD HH:MM:SS
	testing.expect(t, strings.contains(formatted, "2022-01-01"),
		"Should contain correct date")
	testing.expect(t, strings.contains(formatted, ":10:"),
		"Should contain correct time")
}

@(test)
test_list_backups_for_nonexistent_file :: proc(t: ^testing.T) {
	// Test listing backups for non-existent file
	fake_file := "/tmp/wayu-test-no-backups-file"

	backups := wayu.list_backups_for_file(fake_file)
	defer {
		for backup in backups {
			delete(backup.original_file)
			delete(backup.backup_file)
		}
		delete(backups)
	}

	testing.expect(t, len(backups) == 0, "Should return empty list for non-existent file")
}

@(test)
test_get_config_file_path :: proc(t: ^testing.T) {
	// Initialize shell globals before testing
	wayu.init_shell_globals()

	// Test config file path resolution
	test_cases := []struct {
		config_type: string,
		should_work: bool,
	}{
		{"path", true},
		{"alias", true},
		{"constants", true},
		{"invalid", false},
		{"", false},
	}

	for test_case in test_cases {
		result := wayu.get_config_file_path(test_case.config_type)
		defer if len(result) > 0 do delete(result)

		if test_case.should_work {
			msg := fmt.aprintf("Should return path for '%s'", test_case.config_type)
			testing.expect(t, len(result) > 0, msg)
			delete(msg)
			testing.expect(t, strings.contains(result, ".config/wayu"),
				"Should contain wayu config directory")
		} else {
			msg := fmt.aprintf("Should return empty for invalid type '%s'", test_case.config_type)
			testing.expect(t, result == "", msg)
			delete(msg)
		}
	}
}

@(test)
test_backup_workflow :: proc(t: ^testing.T) {
	// Test complete backup workflow: create -> list -> restore

	// Setup test file
	test_content := "original content for backup test\n"
	test_file := "/tmp/wayu-test-backup-workflow"

	os.write_entire_file(test_file, transmute([]byte)test_content)
	defer os.remove(test_file)

	// Create first backup
	backup1_path, ok1 := wayu.create_backup(test_file)
	defer if ok1 do delete(backup1_path)
	defer if ok1 do os.remove(backup1_path)

	testing.expect(t, ok1, "Should create first backup")

	// Modify file
	modified_content := "modified content\n"
	os.write_entire_file(test_file, transmute([]byte)modified_content)

	// Add a small delay to ensure different timestamps
	time.sleep(1_000_000_000) // 1 second

	// Create second backup
	backup2_path, ok2 := wayu.create_backup(test_file)
	defer if ok2 do delete(backup2_path)
	defer if ok2 do os.remove(backup2_path)

	testing.expect(t, ok2, "Should create second backup")

	// List backups
	backups := wayu.list_backups_for_file(test_file)
	defer {
		for backup in backups {
			delete(backup.original_file)
			delete(backup.backup_file)
		}
		delete(backups)
	}

	testing.expect(t, len(backups) == 2, "Should find two backups")

	// Verify backups are sorted by timestamp (most recent first)
	if len(backups) == 2 {
		diff := time.diff(backups[0].timestamp, backups[1].timestamp)
		testing.expect(t, diff <= 0, "Backups should be sorted by timestamp (newest first)")
	}

	// Restore from backup
	restore_ok := wayu.restore_from_backup(test_file)
	testing.expect(t, restore_ok, "Should restore from backup")

	// Verify restored content
	restored_content, read_ok := os.read_entire_file_from_filename(test_file)
	if read_ok {
		defer delete(restored_content)
		testing.expect(t, string(restored_content) == modified_content,
			"Restored content should match most recent backup")
	}
}

@(test)
test_cleanup_old_backups :: proc(t: ^testing.T) {
	// Test backup cleanup functionality

	// Create test file
	test_content := "content for cleanup test\n"
	test_file := "/tmp/wayu-test-cleanup"

	os.write_entire_file(test_file, transmute([]byte)test_content)
	defer os.remove(test_file)

	// Create multiple backups
	backup_paths: [dynamic]string
	defer {
		for path in backup_paths {
			delete(path)
			os.remove(path)
		}
		delete(backup_paths)
	}

	for i in 0..<7 {
		backup_path, ok := wayu.create_backup(test_file)
		if ok {
			append(&backup_paths, backup_path)
		}
		// Sleep briefly to ensure different timestamps
		time.sleep(1_000_000_000) // 1 second
	}

	testing.expect(t, len(backup_paths) == 7, "Should create 7 backups")

	// Clean up old backups (keep only 3)
	removed_count := wayu.cleanup_old_backups(test_file, 3)

	testing.expect(t, removed_count == 4, "Should remove 4 old backups")

	// Verify only 3 backups remain
	remaining_backups := wayu.list_backups_for_file(test_file)
	defer {
		for backup in remaining_backups {
			delete(backup.original_file)
			delete(backup.backup_file)
		}
		delete(remaining_backups)
	}

	testing.expect(t, len(remaining_backups) == 3, "Should have 3 backups remaining")
}

@(test)
test_backup_with_prompt_success :: proc(t: ^testing.T) {
	// Test backup with prompt when backup succeeds
	test_content := "content for prompt test\n"
	test_file := "/tmp/wayu-test-prompt"

	os.write_entire_file(test_file, transmute([]byte)test_content)
	defer os.remove(test_file)

	// Test with auto_backup = true
	result := wayu.create_backup_with_prompt(test_file, true)
	testing.expect(t, result, "Should succeed when backup works")

	// Test with auto_backup = false
	result_no_backup := wayu.create_backup_with_prompt(test_file, false)
	testing.expect(t, result_no_backup, "Should succeed when auto_backup is false")
}

@(test)
test_restore_nonexistent_backup :: proc(t: ^testing.T) {
	// Test restore when no backups exist
	fake_file := "/tmp/wayu-test-no-restore-file"

	result := wayu.restore_from_backup(fake_file)
	testing.expect(t, !result, "Should fail when no backups exist")
}