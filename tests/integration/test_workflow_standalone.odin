// test_workflow_standalone.odin - Full lifecycle integration tests
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
	fmt.println("🔄 Testing full workflow integration...")
	fmt.println()

	home := os.get_env("HOME", context.temp_allocator)
	config_dir := filepath.join({home, ".config", "wayu"}, context.temp_allocator)
	path_file := filepath.join({config_dir, "path.zsh"}, context.temp_allocator)
	alias_file := filepath.join({config_dir, "aliases.zsh"}, context.temp_allocator)
	constants_file := filepath.join({config_dir, "constants.zsh"}, context.temp_allocator)

	results := Test_Results{test_name = "workflow"}

	fmt.print("Building wayu...")
	if libc.system("task build > /dev/null 2>&1") == 0 {
		fmt.println(" ✓")
	} else {
		fmt.println(" ✗")
		os.exit(1)
	}
	fmt.println()

	// Test 1: PATH full workflow (init → add → list → remove → verify)
	{
		test_dir := "/tmp/wayu_workflow_path"
		create_temp_dir(test_dir)

		// Ensure clean state - remove if exists (macOS resolves /tmp to /private/tmp)
		run_wayu(fmt.tprintf("path rm /private%s", test_dir))

		// Add path
		exit_code := run_wayu_exit_code(fmt.tprintf("path add %s", test_dir))
		add_ok := exit_code == 0

		// List and verify present
		list_output := run_wayu("path list --static")
		defer delete(list_output)
		list_ok := strings.contains(list_output, "wayu_workflow_path")

		// Remove path (macOS resolves /tmp to /private/tmp)
		rm_exit := run_wayu_exit_code(fmt.tprintf("path rm /private%s", test_dir))
		rm_ok := rm_exit == 0

		// Verify removed
		list_after := run_wayu("path list --static")
		defer delete(list_after)
		gone_ok := !strings.contains(list_after, "wayu_workflow_path")

		passed := add_ok && list_ok && rm_ok && gone_ok
		print_test(1, "PATH full workflow (add → list → remove → verify)", passed, &results)

		// Cleanup
		libc.system(strings.clone_to_cstring(fmt.tprintf("rm -rf %s", test_dir), context.temp_allocator))
	}

	// Test 2: Alias full workflow (add → list → remove → verify)
	{
		// Ensure clean state
		run_wayu("alias rm wftest")

		// Add alias
		exit_code := run_wayu_exit_code(`alias add wftest "echo workflow"`)
		add_ok := exit_code == 0

		// List and verify present
		list_output := run_wayu("alias list --static")
		defer delete(list_output)
		list_ok := strings.contains(list_output, "wftest")

		// Remove alias
		rm_exit := run_wayu_exit_code("alias rm wftest")
		rm_ok := rm_exit == 0

		// Verify removed
		list_after := run_wayu("alias list --static")
		defer delete(list_after)
		gone_ok := !strings.contains(list_after, "wftest")

		passed := add_ok && list_ok && rm_ok && gone_ok
		print_test(2, "Alias full workflow (add → list → remove → verify)", passed, &results)
	}

	// Test 3: Constants full workflow (add → list → remove → verify)
	{
		// Ensure clean state
		run_wayu("constants rm WFTEST_VAR")

		// Add constant
		exit_code := run_wayu_exit_code(`constants add WFTEST_VAR "hello_workflow"`)
		add_ok := exit_code == 0

		// List and verify present
		list_output := run_wayu("constants list --static")
		defer delete(list_output)
		list_ok := strings.contains(list_output, "WFTEST_VAR")

		// Remove constant
		rm_exit := run_wayu_exit_code("constants rm WFTEST_VAR")
		rm_ok := rm_exit == 0

		// Verify removed
		list_after := run_wayu("constants list --static")
		defer delete(list_after)
		gone_ok := !strings.contains(list_after, "WFTEST_VAR")

		passed := add_ok && list_ok && rm_ok && gone_ok
		print_test(3, "Constants full workflow (add → list → remove → verify)", passed, &results)
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
