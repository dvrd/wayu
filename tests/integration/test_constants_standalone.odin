// test_constants_standalone.odin - Integration tests for constants command
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

file_contains :: proc(filepath, search: string) -> bool {
	data, err := os.read_entire_file(filepath, context.allocator)
	if err != nil do return false
	defer delete(data)
	return strings.contains(string(data), search)
}

count_occurrences :: proc(filepath, search: string) -> int {
	data, err := os.read_entire_file(filepath, context.allocator)
	if err != nil do return 0
	defer delete(data)
	content := string(data)
	count := 0
	for i := 0; i <= len(content) - len(search); i += 1 {
		if content[i:i+len(search)] == search do count += 1
	}
	return count
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
	fmt.println("🔢 Testing constants command integration...")
	fmt.println()

	home := os.get_env("HOME", context.temp_allocator)
	config_dir, _ := filepath.join({home, ".config", "wayu"}, context.temp_allocator)
	constants_file, _ := filepath.join({config_dir, "constants.zsh"}, context.temp_allocator)

	results := Test_Results{test_name = "constants"}

	fmt.print("Building wayu...")
	if libc.system("task build > /dev/null 2>&1") == 0 {
		fmt.println(" ✓")
	} else {
		fmt.println(" ✗")
		os.exit(1)
	}
	fmt.println()

	// Test 1: Add simple constant
	{
		output := run_wayu(`constants add MY_VAR "test_value"`)
		defer delete(output)
		passed := file_contains(constants_file, "export MY_VAR=")
		print_test(1, "Add simple constant", passed, &results)
	}

	// Test 2: Add constant with spaces
	{
		output := run_wayu(`constants add MY_PATH "/usr/local/my path"`)
		defer delete(output)
		passed := file_contains(constants_file, "export MY_PATH=")
		print_test(2, "Add constant with spaces in value", passed, &results)
	}

	// Test 3: List constants
	{
		output := run_wayu("constants list --static")
		defer delete(output)
		passed := strings.contains(output, "MY_VAR")
		print_test(3, "List all constants", passed, &results)
	}

	// Test 4: Remove constant
	{
		output := run_wayu("constants rm MY_VAR")
		defer delete(output)
		passed := !file_contains(constants_file, "export MY_VAR=")
		print_test(4, "Remove constant", passed, &results)
	}

	// Test 5: Duplicate constant
	{
		run_wayu(`constants add DUPLICATE_TEST "first"`)
		run_wayu(`constants add DUPLICATE_TEST "second"`)
		occurrences := count_occurrences(constants_file, "export DUPLICATE_TEST=")
		passed := occurrences == 1
		print_test(5, "Duplicate constant handling", passed, &results)
	}

	// Test 6: Help command
	{
		output := run_wayu("constants help")
		defer delete(output)
		passed := strings.contains(output, "EXAMPLES") && strings.contains(output, "wayu constants")
		print_test(6, "Help command", passed, &results)
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
