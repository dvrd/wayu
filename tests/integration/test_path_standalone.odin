// test_path_standalone.odin - Integration tests for path command (standalone)
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:path/filepath"
import "core:c/libc"

// Test result tracking
Test_Results :: struct {
	passed: int,
	failed: int,
	test_name: string,
}

// Run wayu command
run_wayu :: proc(args: string) -> string {
	temp_file := "/tmp/wayu_test_output.txt"
	cmd := strings.concatenate({"./bin/wayu ", args, " > ", temp_file, " 2>&1"}, context.temp_allocator)
	libc.system(strings.clone_to_cstring(cmd, context.temp_allocator))

	data, err := os.read_entire_file(temp_file, context.allocator)
	if err != nil do return ""
	defer delete(data)
	return strings.clone(string(data))
}

// Check if file contains string
file_contains :: proc(filepath, search: string) -> bool {
	data, err := os.read_entire_file(filepath, context.allocator)
	if err != nil do return false
	defer delete(data)
	return strings.contains(string(data), search)
}

// Create temp dir
create_temp_dir :: proc(path: string) -> bool {
	if !os.is_dir(path) {
		err := os.make_directory(path)
		return err == nil
	}
	return true
}

// Count occurrences
count_occurrences :: proc(filepath, search: string) -> int {
	data, err := os.read_entire_file(filepath, context.allocator)
	if err != nil do return 0
	defer delete(data)

	content := string(data)
	count := 0
	for i := 0; i <= len(content) - len(search); i += 1 {
		if content[i:i+len(search)] == search {
			count += 1
		}
	}
	return count
}

// Print test result
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
	fmt.println("🛤️  Testing PATH command integration...")
	fmt.println()

	// Setup
	home := os.get_env("HOME", context.temp_allocator)
	config_dir, _ := filepath.join({home, ".config", "wayu"}, context.temp_allocator)
	path_file, _ := filepath.join({config_dir, "path.zsh"}, context.temp_allocator)

	results := Test_Results{test_name = "PATH"}

	// Build
	fmt.print("Building wayu...")
	if libc.system("task build > /dev/null 2>&1") == 0 {
		fmt.println(" ✓")
	} else {
		fmt.println(" ✗")
		os.exit(1)
	}
	fmt.println()

	// Test 1: Add single path
	{
		test_dir := "/tmp/wayu_test_path1"
		create_temp_dir(test_dir)
		output := run_wayu(fmt.tprintf("path add %s", test_dir))
		defer delete(output)
		success := !strings.contains(output, "ERROR")
		passed := success && file_contains(path_file, test_dir)
		print_test(1, "Add single path", passed, &results)
	}

	// Test 2: Add multiple paths
	{
		test_dirs := []string{"/tmp/wayu_test_path2", "/tmp/wayu_test_path3"}
		for dir in test_dirs {
			create_temp_dir(dir)
			output := run_wayu(fmt.tprintf("path add %s", dir))
			delete(output)
		}
		all_present := true
		for dir in test_dirs {
			if !file_contains(path_file, dir) {
				all_present = false
				break
			}
		}
		print_test(2, "Add multiple paths", all_present, &results)
	}

	// Test 3: List paths
	{
		output := run_wayu("path list --static")
		defer delete(output)
		passed := strings.contains(output, "/tmp/wayu_test_path")
		print_test(3, "List all paths", passed, &results)
	}

	// Test 4: Remove path
	{
		// Use the absolute path that was saved (macOS resolves /tmp to /private/tmp)
		test_dir := "/private/tmp/wayu_test_path1"
		output := run_wayu(fmt.tprintf("path rm %s", test_dir))
		defer delete(output)
		passed := !file_contains(path_file, test_dir)
		print_test(4, "Remove path by name", passed, &results)
	}

	// Test 5: Duplicate handling
	{
		test_dir := "/tmp/wayu_test_duplicate"
		create_temp_dir(test_dir)
		run_wayu(fmt.tprintf("path add %s", test_dir))
		output2 := run_wayu(fmt.tprintf("path add %s", test_dir))
		defer delete(output2)
		occurrences := count_occurrences(path_file, test_dir)
		passed := occurrences == 1 || strings.contains(output2, "already")
		print_test(5, "Duplicate path handling", passed, &results)
	}

	// Test 6: Non-existent path
	{
		fake_path := "/tmp/nonexistent_wayu_path_123456789"
		output := run_wayu(fmt.tprintf("path add %s", fake_path))
		defer delete(output)
		passed := strings.contains(output, "does not exist") ||
		          strings.contains(output, "not found") ||
		          strings.contains(output, "Could not resolve")
		print_test(6, "Non-existent path handling", passed, &results)
	}

	// Test 7: Help command
	{
		output := run_wayu("path help")
		defer delete(output)
		passed := strings.contains(output, "EXAMPLES") && strings.contains(output, "wayu path")
		print_test(7, "Help command", passed, &results)
	}

	// Cleanup
	test_dirs := []string{
		"/tmp/wayu_test_path1", "/tmp/wayu_test_path2", "/tmp/wayu_test_path3",
		"/tmp/wayu_test_duplicate", "/tmp/nonexistent_wayu_path_123456789",
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
