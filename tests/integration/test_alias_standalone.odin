// test_alias_standalone.odin - Integration tests for alias command
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

count_occurrences :: proc(filepath, search: string) -> int {
	data, ok := os.read_entire_file_from_filename(filepath)
	if !ok do return 0
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
	fmt.println("🔗 Testing alias command integration...")
	fmt.println()

	home := os.get_env("HOME", context.temp_allocator)
	config_dir := filepath.join({home, ".config", "wayu"}, context.temp_allocator)
	alias_file := filepath.join({config_dir, "aliases.zsh"}, context.temp_allocator)

	results := Test_Results{test_name = "alias"}

	fmt.print("Building wayu...")
	if libc.system("task build > /dev/null 2>&1") == 0 {
		fmt.println(" ✓")
	} else {
		fmt.println(" ✗")
		os.exit(1)
	}
	fmt.println()

	// Test 1: Add simple alias
	{
		output := run_wayu(`alias add ll "ls -la"`)
		defer delete(output)
		passed := file_contains(alias_file, "alias ll=")
		print_test(1, "Add simple alias", passed, &results)
	}

	// Test 2: Add alias with args
	{
		output := run_wayu(`alias add gco "git checkout"`)
		defer delete(output)
		passed := file_contains(alias_file, "alias gco=")
		print_test(2, "Add alias with arguments", passed, &results)
	}

	// Test 3: List aliases
	{
		output := run_wayu("alias list")
		defer delete(output)
		passed := strings.contains(output, "ll")
		print_test(3, "List all aliases", passed, &results)
	}

	// Test 4: Remove alias
	{
		output := run_wayu("alias rm ll")
		defer delete(output)
		passed := !file_contains(alias_file, "alias ll=")
		print_test(4, "Remove alias", passed, &results)
	}

	// Test 5: Duplicate alias
	{
		run_wayu(`alias add myalias "echo first"`)
		run_wayu(`alias add myalias "echo second"`)
		occurrences := count_occurrences(alias_file, "alias myalias=")
		passed := occurrences == 1
		print_test(5, "Duplicate alias handling", passed, &results)
	}

	// Test 6: Help command
	{
		output := run_wayu("alias help")
		defer delete(output)
		passed := strings.contains(output, "EXAMPLES") && strings.contains(output, "wayu alias")
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
