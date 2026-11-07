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
	// When the source file doesn't exist, create_backup returns ("", false).
	// ok=false signals "no backup was made" — callers must treat this as a no-op, not an error.
	fake_file := "/tmp/wayu-test-nonexistent-file"

	backup_path, ok := wayu.create_backup(fake_file)
	defer if len(backup_path) > 0 do delete(backup_path)

	testing.expect(t, !ok, "Should return false for non-existent file (no backup made)")
	testing.expect(t, backup_path == "", "Should return empty path for non-existent file")
}

@(test)
test_create_backup_existing_file :: proc(t: ^testing.T) {
	// Point wayu.data to a temp dir so backup/ can be created there
	original_data := wayu.wayu.data
	wayu.wayu.data = "/tmp/wayu-test-backup"
	os.make_directory("/tmp/wayu-test-backup")
	os.make_directory("/tmp/wayu-test-backup/backup")
	defer { wayu.wayu.data = original_data; os.remove_all("/tmp/wayu-test-backup") }

	// Create a temporary file
	test_content := "test backup content\nline 2\n"
	test_file := "/tmp/wayu-test-backup-source"

	_ = os.write_entire_file(test_file, transmute([]byte)test_content)
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
		backup_content, read_err := os.read_entire_file(backup_path, context.allocator)
		if read_err == nil {
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
			// Check that it's an absolute path
			testing.expect(t, strings.has_prefix(result, "/"),
				"Should be an absolute path")
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
	original_data := wayu.wayu.data
	wayu.wayu.data = "/tmp/wayu-test-backup-wf"
	os.make_directory("/tmp/wayu-test-backup-wf")
	defer { wayu.wayu.data = original_data; os.remove_all("/tmp/wayu-test-backup-wf") }

	// Setup test file
	test_content := "original content for backup test\n"
	test_file := "/tmp/wayu-test-backup-workflow"

	_ = os.write_entire_file(test_file, transmute([]byte)test_content)
	defer os.remove(test_file)

	// Create first backup
	backup1_path, ok1 := wayu.create_backup(test_file)
	defer if ok1 do delete(backup1_path)
	defer if ok1 do os.remove(backup1_path)

	testing.expect(t, ok1, "Should create first backup")

	// Modify file
	modified_content := "modified content\n"
	_ = os.write_entire_file(test_file, transmute([]byte)modified_content)

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

	// Should find at least 2 backups (may be more from previous test runs)
	testing.expect(t, len(backups) >= 2, "Should find at least two backups")

	// Verify backups are sorted by timestamp (most recent first)
	if len(backups) >= 2 {
		diff := time.diff(backups[0].timestamp, backups[1].timestamp)
		testing.expect(t, diff <= 0, "Backups should be sorted by timestamp (newest first)")
	}

	// Restore from backup
	restore_ok := wayu.restore_from_backup(test_file)
	testing.expect(t, restore_ok, "Should restore from backup")

	// Verify restored content
	restored_content, read_err := os.read_entire_file(test_file, context.allocator)
	if read_err == nil {
		defer delete(restored_content)
		testing.expect(t, string(restored_content) == modified_content,
			"Restored content should match most recent backup")
	}
}

@(test)
test_cleanup_old_backups :: proc(t: ^testing.T) {
	// Test backup cleanup functionality
	original_data := wayu.wayu.data
	wayu.wayu.data = "/tmp/wayu-test-backup-cleanup"
	os.make_directory("/tmp/wayu-test-backup-cleanup")
	defer { wayu.wayu.data = original_data; os.remove_all("/tmp/wayu-test-backup-cleanup") }

	// Create test file
	test_content := "content for cleanup test\n"
	test_file := "/tmp/wayu-test-cleanup"

	_ = os.write_entire_file(test_file, transmute([]byte)test_content)
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

// NOTE: This test is commented out as create_backup_with_prompt no longer exists
// after PRP-13 CLI/TUI isolation. The function was split into:
// - create_backup_cli (for CLI mode - fails immediately)
// - create_backup_tui (for TUI mode - prompts user)
//
// @(test)
// test_backup_with_prompt_success :: proc(t: ^testing.T) {
// 	// Test backup with prompt when backup succeeds
// 	test_content := "content for prompt test\n"
// 	test_file := "/tmp/wayu-test-prompt"
//
// 	os.write_entire_file(test_file, transmute([]byte)test_content)
// 	defer os.remove(test_file)
//
// 	// Test with auto_backup = true
// 	result := wayu.create_backup_with_prompt(test_file, true)
// 	testing.expect(t, result, "Should succeed when backup works")
//
// 	// Test with auto_backup = false
// 	result_no_backup := wayu.create_backup_with_prompt(test_file, false)
// 	testing.expect(t, result_no_backup, "Should succeed when auto_backup is false")
// }

@(test)
test_restore_nonexistent_backup :: proc(t: ^testing.T) {
	// Test restore when no backups exist
	fake_file := "/tmp/wayu-test-no-restore-file"

	result := wayu.restore_from_backup(fake_file)
	testing.expect(t, !result, "Should fail when no backups exist")
}
// Regression (#1): back-to-back backups within the same second used to share
// a second-resolution filename, so the second write overwrote the first and
// the pristine pre-operation copy was lost.
@(test)
test_rapid_backups_are_unique :: proc(t: ^testing.T) {
	original_data := wayu.wayu.data
	wayu.wayu.data = "/tmp/wayu-test-backup-rapid"
	os.make_directory("/tmp/wayu-test-backup-rapid")
	defer { wayu.wayu.data = original_data; os.remove_all("/tmp/wayu-test-backup-rapid") }

	test_file := "/tmp/wayu-test-backup-rapid-src"
	defer os.remove(test_file)

	contents := []string{"v0\n", "v1\n", "v2\n", "v3\n", "v4\n"}
	paths: [dynamic]string
	defer { for p in paths { delete(p) }; delete(paths) }

	for c in contents {
		_ = os.write_entire_file(test_file, transmute([]byte)c)
		p, ok := wayu.create_backup(test_file)
		testing.expect(t, ok, "backup should succeed")
		if ok { append(&paths, p) }
	}
	testing.expect_value(t, len(paths), len(contents))

	// All distinct, each holds the content it was taken from.
	for p, i in paths {
		for q, j in paths {
			if i != j { testing.expect(t, p != q, "backup paths must be unique") }
		}
		data, err := os.read_entire_file(p, context.allocator)
		if err == nil {
			testing.expect_value(t, string(data), contents[i])
			delete(data)
		}
	}

	// list_backups_for_file returns newest first: v4 .. v0.
	backups := wayu.list_backups_for_file(test_file)
	defer {
		for b in backups { delete(b.original_file); delete(b.backup_file) }
		delete(backups)
	}
	testing.expect_value(t, len(backups), len(contents))
	if len(backups) == len(contents) {
		for b, i in backups {
			testing.expect_value(t, b.backup_file, paths[len(paths) - 1 - i])
		}
	}

	// Cleanup keeps the newest N.
	removed := wayu.cleanup_old_backups(test_file, 2)
	testing.expect_value(t, removed, 3)
	testing.expect(t, os.exists(paths[4]) && os.exists(paths[3]), "newest backups kept")
	testing.expect(t, !os.exists(paths[0]), "oldest backup removed")
}

@(test)
test_parse_backup_suffix_formats :: proc(t: ^testing.T) {
	// Old second-resolution format still parses.
	old := wayu.parse_timestamp("2026-01-09_19-45-30")
	y, m, d := time.date(old)
	testing.expect(t, y == 2026 && int(m) == 1 && d == 9, "old format date")

	// New microsecond format orders after the old same-second name.
	newer, seq0 := wayu.parse_backup_suffix("2026-01-09_19-45-30.000250")
	testing.expect(t, time.diff(old, newer) > 0, "fractional part must be honoured")
	testing.expect_value(t, seq0, 0)

	// Collision sequence suffix.
	same, seq := wayu.parse_backup_suffix("2026-01-09_19-45-30.000250-3")
	testing.expect(t, time.diff(newer, same) == 0, "seq does not change time")
	testing.expect_value(t, seq, 3)
}

// Regression (#2): restore must refuse a corrupt wayu.toml backup and must
// back up the current file before overwriting it.
@(test)
test_restore_rejects_invalid_toml_backup :: proc(t: ^testing.T) {
	original_data := wayu.wayu.data
	wayu.wayu.data = "/tmp/wayu-test-restore-invalid"
	os.make_directory("/tmp/wayu-test-restore-invalid")
	os.make_directory("/tmp/wayu-test-restore-invalid/backup")
	os.make_directory("/tmp/wayu-test-restore-invalid/cfg")
	defer { wayu.wayu.data = original_data; os.remove_all("/tmp/wayu-test-restore-invalid") }

	target := "/tmp/wayu-test-restore-invalid/cfg/wayu.toml"
	good := "[paths]\nbin = \"/usr/bin\"\n"
	_ = os.write_entire_file(target, transmute([]byte)good)

	bad := "[paths\nnot = = toml\n"
	bad_backup := "/tmp/wayu-test-restore-invalid/backup/wayu.toml.backup.2030-01-01_00-00-00.000000"
	_ = os.write_entire_file(bad_backup, transmute([]byte)bad)

	ok := wayu.restore_from_backup(target)
	testing.expect(t, !ok, "restore of invalid TOML must fail")

	data, err := os.read_entire_file(target, context.allocator)
	if err == nil {
		testing.expect_value(t, string(data), good)
		delete(data)
	}
}

@(test)
test_restore_backs_up_current_first :: proc(t: ^testing.T) {
	original_data := wayu.wayu.data
	wayu.wayu.data = "/tmp/wayu-test-restore-pre"
	os.make_directory("/tmp/wayu-test-restore-pre")
	defer { wayu.wayu.data = original_data; os.remove_all("/tmp/wayu-test-restore-pre") }

	target := "/tmp/wayu-test-restore-pre-src"
	defer os.remove(target)

	_ = os.write_entire_file(target, transmute([]byte)string("old\n"))
	p, ok := wayu.create_backup(target)
	testing.expect(t, ok, "seed backup")
	if ok { delete(p) }
	_ = os.write_entire_file(target, transmute([]byte)string("current\n"))

	testing.expect(t, wayu.restore_from_backup(target), "restore succeeds")

	data, err := os.read_entire_file(target, context.allocator)
	if err == nil {
		testing.expect_value(t, string(data), "old\n")
		delete(data)
	}

	// The pre-restore "current" content must be preserved as the newest backup.
	backups := wayu.list_backups_for_file(target)
	defer {
		for b in backups { delete(b.original_file); delete(b.backup_file) }
		delete(backups)
	}
	testing.expect_value(t, len(backups), 2)
	if len(backups) > 0 {
		newest, rerr := os.read_entire_file(backups[0].backup_file, context.allocator)
		if rerr == nil {
			testing.expect_value(t, string(newest), "current\n")
			delete(newest)
		}
	}
}

// OKAMI-232: every CLI write prunes to BACKUP_KEEP_COUNT, and one process
// backs a file up only once (bulk commands keep their pre-command copy).
@(test)
test_backup_cli_retention_and_once_per_run :: proc(t: ^testing.T) {
	dir := "/tmp/wayu-test-backup-retention"
	original_data := wayu.wayu.data
	wayu.wayu.data = dir
	os.remove_all(dir)
	os.make_directory(dir)
	defer { wayu.wayu.data = original_data; os.remove_all(dir) }
	target := "/tmp/wayu-test-backup-retention-src"
	defer os.remove(target)
	defer wayu.backup_run_reset()

	count :: proc(f: string) -> int {
		b := wayu.list_backups_for_file(f)
		defer wayu.free_backup_infos(b)
		return len(b)
	}

	// Same process: only the first write is backed up.
	wayu.backup_run_reset()
	_ = os.write_entire_file(target, transmute([]byte)string("v0\n"))
	testing.expect(t, wayu.create_backup_cli(target))
	_ = os.write_entire_file(target, transmute([]byte)string("v1\n"))
	testing.expect(t, wayu.create_backup_cli(target))
	testing.expect_value(t, count(target), 1)

	// Simulated separate invocations: capped at BACKUP_KEEP_COUNT.
	for i in 0..<12 {
		wayu.backup_run_reset()
		_ = os.write_entire_file(target, transmute([]byte)fmt.tprintf("w%d\n", i))
		testing.expect(t, wayu.create_backup_cli(target))
	}
	testing.expect_value(t, count(target), wayu.BACKUP_KEEP_COUNT)
}

// OKAMI-232: restore can pick a backup, and the default skips pre-restore
// snapshots so repeated restores don't ping-pong.
@(test)
test_restore_selects_backup :: proc(t: ^testing.T) {
	dir := "/tmp/wayu-test-restore-select"
	original_data := wayu.wayu.data
	wayu.wayu.data = dir
	os.remove_all(dir)
	os.make_directory(dir)
	defer { wayu.wayu.data = original_data; os.remove_all(dir) }
	target := "/tmp/wayu-test-restore-select-src"
	defer os.remove(target)

	read :: proc(f: string) -> string {
		d, err := os.read_entire_file(f, context.temp_allocator)
		return err == nil ? string(d) : ""
	}

	for v in ([]string{"a\n", "b\n", "c\n"}) {
		_ = os.write_entire_file(target, transmute([]byte)v)
		p, ok := wayu.create_backup(target)
		if ok { delete(p) }
	}
	_ = os.write_entire_file(target, transmute([]byte)string("d\n"))
	// list (newest first): c, b, a

	testing.expect(t, wayu.restore_from_backup(target), "default restore")
	testing.expect_value(t, read(target), "c\n")
	// Second default restore: still c (skips the pre-restore copy of d).
	testing.expect(t, wayu.restore_from_backup(target), "repeat restore")
	testing.expect_value(t, read(target), "c\n")

	// list now: pre-restore(c), pre-restore(d), c, b, a  ->  #5 is "a".
	testing.expect(t, wayu.restore_from_backup(target, "5"), "restore by index")
	testing.expect_value(t, read(target), "a\n")

	// Undo via the pre-restore snapshot (newest, #1).
	testing.expect(t, wayu.restore_from_backup(target, "1"), "undo restore")
	testing.expect_value(t, read(target), "c\n")

	// By file name, and a bad selector fails without writing.
	b := wayu.list_backups_for_file(target)
	defer wayu.free_backup_infos(b)
	last := b[len(b) - 1]
	testing.expect(t, wayu.restore_from_backup(target, last.backup_file[strings.last_index(last.backup_file, "/") + 1:]))
	testing.expect_value(t, read(target), "a\n")
	testing.expect(t, !wayu.restore_from_backup(target, "99"), "out of range")
	testing.expect(t, !wayu.restore_from_backup(target, "nope"), "unknown file")
	testing.expect_value(t, read(target), "a\n")
}
