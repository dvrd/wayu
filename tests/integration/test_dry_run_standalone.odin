// test_dry_run_standalone.odin - Dry-run mode integration tests
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

run_wayu_exit_code :: proc(args: string) -> int {
	cmd := strings.concatenate({"./bin/wayu ", args, " > /dev/null 2>&1"}, context.temp_allocator)
	status := libc.system(strings.clone_to_cstring(cmd, context.temp_allocator))
	return int((status >> 8) & 0xFF)
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
	fmt.println("🔒 Testing dry-run mode integration...")
	fmt.println()

	home := os.get_env("HOME", context.temp_allocator)
	config_dir := filepath.join({home, ".config", "wayu"}, context.temp_allocator)
	path_file := filepath.join({config_dir, "path.zsh"}, context.temp_allocator)

	results := Test_Results{test_name = "dry-run"}

	fmt.print("Building wayu...")
	if libc.system("task build > /dev/null 2>&1") == 0 {
		fmt.println(" ✓")
	} else {
		fmt.println(" ✗")
		os.exit(1)
	}
	fmt.println()

	// Test 1: Dry-run path add does NOT modify files
	{
		test_dir := "/tmp/wayu_dryrun_test1"
		create_temp_dir(test_dir)

		// Ensure clean state
		run_wayu(fmt.tprintf("path rm /private%s", test_dir))

		// Dry-run add
		exit_code := run_wayu_exit_code(fmt.tprintf("--dry-run path add %s", test_dir))
		exit_ok := exit_code == 0

		// Verify NOT present in config file
		list_output := run_wayu("path list --static")
		defer delete(list_output)
		not_present := !strings.contains(list_output, "wayu_dryrun_test1")

		passed := exit_ok && not_present
		print_test(1, "Dry-run path add does NOT modify files", passed, &results)

		// Cleanup
		libc.system(strings.clone_to_cstring(fmt.tprintf("rm -rf %s", test_dir), context.temp_allocator))
	}

	// Test 2: Dry-run path rm does NOT remove entries
	{
		test_dir := "/tmp/wayu_dryrun_test2"
		create_temp_dir(test_dir)

		// Ensure clean state and add for real
		run_wayu(fmt.tprintf("path rm /private%s", test_dir))
		run_wayu(fmt.tprintf("path add %s", test_dir))

		// Dry-run remove (macOS resolves /tmp to /private/tmp)
		exit_code := run_wayu_exit_code(fmt.tprintf("--dry-run path rm /private%s", test_dir))
		exit_ok := exit_code == 0

		// Verify STILL present in config file
		list_output := run_wayu("path list --static")
		defer delete(list_output)
		still_present := strings.contains(list_output, "wayu_dryrun_test2")

		passed := exit_ok && still_present
		print_test(2, "Dry-run path rm does NOT remove entries", passed, &results)

		// Real cleanup
		run_wayu(fmt.tprintf("path rm /private%s", test_dir))
		libc.system(strings.clone_to_cstring(fmt.tprintf("rm -rf %s", test_dir), context.temp_allocator))
	}

	// Test 3: Dry-run output contains preview text
	{
		test_dir := "/tmp/wayu_dryrun_test3"
		create_temp_dir(test_dir)

		// Ensure clean state
		run_wayu(fmt.tprintf("path rm /private%s", test_dir))

		// Dry-run add and capture output
		output := run_wayu(fmt.tprintf("--dry-run path add %s", test_dir))
		defer delete(output)

		// Verify output contains dry-run indicator
		passed := strings.contains(output, "DRY RUN") || strings.contains(output, "dry-run") || strings.contains(output, "dry run")
		print_test(3, "Dry-run output contains preview text", passed, &results)

		// Cleanup
		libc.system(strings.clone_to_cstring(fmt.tprintf("rm -rf %s", test_dir), context.temp_allocator))
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
