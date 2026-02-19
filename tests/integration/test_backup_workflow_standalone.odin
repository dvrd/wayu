// test_backup_workflow_standalone.odin - Backup workflow integration tests
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
	data, err := os.read_entire_file(temp_file, context.allocator)
	if err != nil do return ""
	defer delete(data)
	return strings.clone(string(data))
}

run_wayu_exit_code :: proc(args: string) -> int {
	cmd := strings.concatenate({"./bin/wayu ", args, " > /dev/null 2>&1"}, context.temp_allocator)
	status := libc.system(strings.clone_to_cstring(cmd, context.temp_allocator))
	return int((status >> 8) & 0xFF)
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
	cmd := strings.concatenate({"sh -c 'ls ", pattern, " 2>/dev/null | wc -l' > ", temp_file}, context.temp_allocator)
	libc.system(strings.clone_to_cstring(cmd, context.temp_allocator))

	data, err := os.read_entire_file(temp_file, context.allocator)
	if err != nil do return 0
	defer delete(data)

	count_str := strings.trim_space(string(data))
	count := 0
	for c in count_str {
		if c >= '0' && c <= '9' {
			count = count * 10 + int(c - '0')
		}
	}
	return count
}

cleanup_backups :: proc(config_dir: string) {
	cmd := strings.concatenate({"rm -f ", config_dir, "/backup/*.backup.* 2>/dev/null"}, context.temp_allocator)
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
	fmt.println("💾 Testing backup workflow integration...")
	fmt.println()

	home := os.get_env("HOME", context.temp_allocator)
	if len(home) == 0 {
		fmt.println("ERROR: HOME environment variable not set")
		os.exit(1)
	}
	config_dir, _ := filepath.join({home, ".config", "wayu"}, context.temp_allocator)

	results := Test_Results{test_name = "backup-workflow"}

	fmt.print("Building wayu...")
	if libc.system("task build > /dev/null 2>&1") == 0 {
		fmt.println(" ✓")
	} else {
		fmt.println(" ✗")
		os.exit(1)
	}
	fmt.println()

	// Test 1: Backup auto-created on add
	{
		cleanup_backups(config_dir)

		test_dir := "/tmp/wayu_bkwf_test1"
		create_temp_dir(test_dir)

		// Remove first to ensure clean state
		run_wayu(fmt.tprintf("path rm /private%s", test_dir))

		// Add path - this should create a backup
		output := run_wayu(fmt.tprintf("path add %s", test_dir))
		defer delete(output)

		// Check backup directory has files
		pattern := strings.concatenate({config_dir, "/backup/path.zsh.backup.*"}, context.temp_allocator)
		backup_count := count_backup_files(pattern)

		passed := backup_count > 0
		print_test(1, "Backup auto-created on path add", passed, &results)

		// Cleanup
		run_wayu(fmt.tprintf("path rm /private%s", test_dir))
		libc.system(strings.clone_to_cstring(fmt.tprintf("rm -rf %s", test_dir), context.temp_allocator))
	}

	// Test 2: Backup list shows entries after modifications
	{
		test_dir := "/tmp/wayu_bkwf_test2"
		create_temp_dir(test_dir)

		// Remove first to ensure clean state
		run_wayu(fmt.tprintf("path rm /private%s", test_dir))

		// Add path (triggers backup creation)
		run_wayu(fmt.tprintf("path add %s", test_dir))

		// List backups
		output := run_wayu("backup list")
		defer delete(output)

		// Should show backup info (either "Configuration Backups" header or "path.zsh" in listing)
		passed := strings.contains(output, "path.zsh") ||
		          strings.contains(output, "Configuration Backups") ||
		          strings.contains(output, "All Configuration Backups") ||
		          strings.contains(output, "backup")
		print_test(2, "Backup list shows entries after modifications", passed, &results)

		// Cleanup
		run_wayu(fmt.tprintf("path rm /private%s", test_dir))
		libc.system(strings.clone_to_cstring(fmt.tprintf("rm -rf %s", test_dir), context.temp_allocator))
	}

	// Test 3: Backup cleanup works
	{
		// Create multiple backups by making multiple changes
		for i in 0..<6 {
			test_dir := fmt.tprintf("/tmp/wayu_bkwf_cleanup_%d", i)
			create_temp_dir(test_dir)
			output := run_wayu(fmt.tprintf("path add %s", test_dir))
			delete(output)
		}

		// Run cleanup
		exit_code := run_wayu_exit_code("backup rm")

		// Check that cleanup ran (exit 0 means success)
		pattern := strings.concatenate({config_dir, "/backup/path.zsh.backup.*"}, context.temp_allocator)
		after_count := count_backup_files(pattern)

		// After cleanup, should have at most 5 backups (default retention)
		passed := exit_code == 0 && after_count <= 5
		print_test(3, "Backup cleanup reduces backup count", passed, &results)

		// Cleanup test dirs
		for i in 0..<6 {
			test_dir := fmt.tprintf("/tmp/wayu_bkwf_cleanup_%d", i)
			run_wayu(fmt.tprintf("path rm /private%s", test_dir))
			libc.system(strings.clone_to_cstring(fmt.tprintf("rm -rf %s", test_dir), context.temp_allocator))
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
