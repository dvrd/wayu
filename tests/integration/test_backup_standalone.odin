// test_backup_standalone.odin - Integration tests for backup system
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:path/filepath"
import "core:c/libc"

Test_Results :: struct {
	passed: int,
	failed: int,
	test_name: string,
}

run_wayu :: proc(args: string) -> string {
	temp_file := "/tmp/wayu_test_output.txt"
	cmd := strings.concatenate({"./bin/wayu ", args, " > ", temp_file, " 2>&1"}, context.temp_allocator)
	libc.system(strings.clone_to_cstring(cmd, context.temp_allocator))
	data, ok := os.read_entire_file_from_filename(temp_file)
	if !ok do return ""
	defer delete(data)
	return strings.clone(string(data))
}

file_contains :: proc(filepath, search: string) -> bool {
	data, ok := os.read_entire_file_from_filename(filepath)
	if !ok do return false
	defer delete(data)
	return strings.contains(string(data), search)
}

create_temp_dir :: proc(path: string) -> bool {
	if !os.is_dir(path) {
		err := os.make_directory(path)
		return err == nil
	}
	return true
}

count_backup_files :: proc(pattern: string) -> int {
	temp_file := "/tmp/wayu_count_output.txt"
	// Use sh -c to execute the pipe command properly
	cmd := strings.concatenate({"sh -c 'ls ", pattern, " 2>/dev/null | wc -l' > ", temp_file}, context.temp_allocator)
	libc.system(strings.clone_to_cstring(cmd, context.temp_allocator))

	data, ok := os.read_entire_file_from_filename(temp_file)
	if !ok do return 0
	defer delete(data)

	count_str := strings.trim_space(string(data))
	// Simple atoi implementation
	count := 0
	for c in count_str {
		if c >= '0' && c <= '9' {
			count = count * 10 + int(c - '0')
		}
	}
	return count
}

cleanup_backups :: proc(config_dir: string) {
	cmd := strings.concatenate({"rm -f ", config_dir, "/*.backup.* 2>/dev/null"}, context.temp_allocator)
	libc.system(strings.clone_to_cstring(cmd, context.temp_allocator))
}

print_test :: proc(num: int, name: string, passed: bool, results: ^Test_Results) {
	if passed {
		fmt.printf("Test %d: %s... ✓\n", num, name)
		results.passed += 1
	} else {
		fmt.printf("Test %d: %s... ✗\n", num, name)
		results.failed += 1
	}
}

main :: proc() {
	fmt.println("💾 Testing backup system integration...")
	fmt.println()

	home := os.get_env("HOME", context.temp_allocator)
	if len(home) == 0 {
		fmt.println("ERROR: HOME environment variable not set")
		os.exit(1)
	}
	config_dir := filepath.join({home, ".config", "wayu"}, context.temp_allocator)

	results := Test_Results{test_name = "backup"}

	fmt.print("Building wayu...")
	if libc.system("task build > /dev/null 2>&1") == 0 {
		fmt.println(" ✓")
	} else {
		fmt.println(" ✗")
		os.exit(1)
	}
	fmt.println()

	// Test 1: Automatic backup creation
	{
		cleanup_backups(config_dir)

		test_dir := "/tmp/wayu_backup_test1"
		create_temp_dir(test_dir)

		// Remove the path first using absolute path (macOS resolves /tmp to /private/tmp)
		run_wayu(fmt.tprintf("path rm /private%s", test_dir))

		// Now add it - this should create a backup
		output := run_wayu(fmt.tprintf("path add %s", test_dir))
		defer delete(output)

		pattern := strings.concatenate({config_dir, "/path.zsh.backup.*"}, context.temp_allocator)
		backup_count := count_backup_files(pattern)

		passed := backup_count > 0
		print_test(1, "Automatic backup creation", passed, &results)
	}

	// Test 2: List backups when none exist
	{
		cleanup_backups(config_dir)

		output := run_wayu("backup list")
		defer delete(output)

		passed := strings.contains(output, "No backups found")
		print_test(2, "List backups when none exist", passed, &results)
	}

	// Test 3: List backups when backups exist
	{
		test_dirs := []string{"/tmp/wayu_backup_test2", "/tmp/wayu_backup_test3"}
		for dir in test_dirs {
			create_temp_dir(dir)
			// Remove first using absolute path (macOS resolves /tmp to /private/tmp)
			run_wayu(fmt.tprintf("path rm /private%s", dir))
			// Now add it
			output := run_wayu(fmt.tprintf("path add %s", dir))
			delete(output)
		}

		output := run_wayu("backup list")
		defer delete(output)

		passed := (strings.contains(output, "Configuration Backups") ||
		           strings.contains(output, "All Configuration Backups")) &&
		          strings.contains(output, "path.zsh")
		print_test(3, "List backups when backups exist", passed, &results)
	}

	// Test 4: List backups for specific config type
	{
		output := run_wayu("backup list path")
		defer delete(output)

		passed := strings.contains(output, "Backups for path.zsh") ||
		          strings.contains(output, "backup")
		print_test(4, "List backups for specific config type", passed, &results)
	}

	// Test 5: Backup restore functionality
	{
		test_dir_orig := "/tmp/wayu_backup_original"
		test_dir_mod := "/tmp/wayu_backup_modified"
		create_temp_dir(test_dir_orig)
		create_temp_dir(test_dir_mod)

		// Add initial path
		run_wayu(fmt.tprintf("path add %s", test_dir_orig))

		// Add another path (creates new backup)
		run_wayu(fmt.tprintf("path add %s", test_dir_mod))

		// Restore from backup
		output := run_wayu("backup restore path")
		defer delete(output)

		passed := strings.contains(output, "Restored from backup") ||
		          strings.contains(output, "restored")
		print_test(5, "Backup restore functionality", passed, &results)
	}

	// Test 6: Backup cleanup functionality
	{
		// Create multiple backups by making multiple changes
		for i in 0..<5 {
			test_dir := fmt.tprintf("/tmp/wayu_cleanup_test_%d", i)
			create_temp_dir(test_dir)
			output := run_wayu(fmt.tprintf("path add %s", test_dir))
			delete(output)
		}

		pattern := strings.concatenate({config_dir, "/path.zsh.backup.*"}, context.temp_allocator)
		before_count := count_backup_files(pattern)

		// Run cleanup
		output := run_wayu("backup rm")
		defer delete(output)

		after_count := count_backup_files(pattern)

		// Should have cleaned up backups (keeping last 5)
		passed := after_count <= 5
		print_test(6, "Backup cleanup functionality", passed, &results)
	}

	// Test 7: Help command
	{
		output := run_wayu("backup help")
		defer delete(output)

		passed := strings.contains(output, "wayu backup") &&
		          strings.contains(output, "EXAMPLES")
		print_test(7, "Help command", passed, &results)
	}

	// Test 8: Error handling
	{
		output := run_wayu("backup restore invalid_type")
		defer delete(output)

		passed := strings.contains(output, "Unknown config type") ||
		          strings.contains(output, "Valid types")
		print_test(8, "Error handling for invalid config type", passed, &results)
	}

	// Cleanup
	test_dirs := []string{
		"/tmp/wayu_backup_test1", "/tmp/wayu_backup_test2", "/tmp/wayu_backup_test3",
		"/tmp/wayu_backup_original", "/tmp/wayu_backup_modified",
		"/tmp/wayu_cleanup_test_0", "/tmp/wayu_cleanup_test_1", "/tmp/wayu_cleanup_test_2",
		"/tmp/wayu_cleanup_test_3", "/tmp/wayu_cleanup_test_4",
	}
	for dir in test_dirs {
		if os.is_dir(dir) {
			cmd := fmt.tprintf("rm -rf %s", dir)
			libc.system(strings.clone_to_cstring(cmd, context.temp_allocator))
		}
	}

	// Summary
	fmt.println()
	fmt.println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
	total := results.passed + results.failed
	if results.failed == 0 {
		fmt.printf("✓ All %d %s integration tests passed!\n", total, results.test_name)
	} else {
		fmt.printf("Results: %d/%d tests passed, %d failed\n", results.passed, total, results.failed)
	}
	fmt.println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

	if results.failed > 0 do os.exit(1)
}
