// test_path_clean_dedup_standalone.odin - PATH clean and dedup integration tests
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
	fmt.println("🧹 Testing PATH clean/dedup integration...")
	fmt.println()

	home := os.get_env("HOME", context.temp_allocator)
	config_dir := filepath.join({home, ".config", "wayu"}, context.temp_allocator)
	path_file := filepath.join({config_dir, "path.zsh"}, context.temp_allocator)

	results := Test_Results{test_name = "path-clean-dedup"}

	fmt.print("Building wayu...")
	if libc.system("task build > /dev/null 2>&1") == 0 {
		fmt.println(" ✓")
	} else {
		fmt.println(" ✗")
		os.exit(1)
	}
	fmt.println()

	// Test 1: path clean requires --yes flag
	{
		exit_code := run_wayu_exit_code("path clean")

		// Without --yes, should fail with non-zero exit code
		// (either EXIT_GENERAL=1 for requiring confirmation, or 0 if no missing paths)
		output := run_wayu("path clean")
		defer delete(output)

		// It should either require --yes (exit 1 with confirmation message)
		// or succeed because there are no missing paths (exit 0 with success message)
		passed := (exit_code != 0 && strings.contains(output, "--yes")) ||
		          (exit_code == 0 && (strings.contains(output, "No missing") || strings.contains(output, "no missing")))
		print_test(1, "path clean requires --yes or reports no missing", passed, &results)
	}

	// Test 2: path dedup requires --yes flag
	{
		exit_code := run_wayu_exit_code("path dedup")

		output := run_wayu("path dedup")
		defer delete(output)

		// It should either require --yes (exit 1 with confirmation message)
		// or succeed because there are no duplicates (exit 0 with success message)
		passed := (exit_code != 0 && strings.contains(output, "--yes")) ||
		          (exit_code == 0 && (strings.contains(output, "No duplicate") || strings.contains(output, "no duplicate")))
		print_test(2, "path dedup requires --yes or reports no duplicates", passed, &results)
	}

	// Test 3: path clean --dry-run doesn't remove entries
	{
		test_dir := "/tmp/wayu_cleandedup_test"
		create_temp_dir(test_dir)

		// Ensure clean state and add for real
		run_wayu(fmt.tprintf("path rm /private%s", test_dir))
		run_wayu(fmt.tprintf("path add %s", test_dir))

		// Verify it was added
		list_before := run_wayu("path list --static")
		defer delete(list_before)
		was_added := strings.contains(list_before, "wayu_cleandedup_test")

		// Dry-run clean with --yes
		exit_code := run_wayu_exit_code("--dry-run path clean --yes")

		// Verify path is still present after dry-run
		list_after := run_wayu("path list --static")
		defer delete(list_after)
		still_present := strings.contains(list_after, "wayu_cleandedup_test")

		passed := was_added && still_present
		print_test(3, "path clean --dry-run doesn't remove entries", passed, &results)

		// Real cleanup
		run_wayu(fmt.tprintf("path rm /private%s", test_dir))
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
