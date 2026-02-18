// test_exit_codes_standalone.odin - Integration tests for BSD sysexits.h exit codes
// Verifies that the compiled wayu binary returns correct exit codes for various scenarios
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:c/libc"

// Exit code constants (must match src/exit_codes.odin)
EXIT_SUCCESS :: 0
EXIT_USAGE   :: 64
EXIT_CONFIG  :: 78

Test_Results :: struct {
	passed: int,
	failed: int,
	test_name: string,
}

// Extract POSIX exit code from libc.system() return value
// On POSIX, exit code = (status >> 8) & 0xFF
extract_exit_code :: proc(status: i32) -> i32 {
	return (status >> 8) & 0xFF
}

// Run a command with an isolated HOME directory (empty temp dir, no wayu config)
run_with_temp_home :: proc(cmd: string) -> i32 {
	tmp_dir := "/tmp/wayu_exit_code_test"

	// Clean up any previous run
	cleanup_cmd := fmt.ctprintf("rm -rf %s", tmp_dir)
	libc.system(cleanup_cmd)

	os.make_directory(tmp_dir)
	defer {
		cleanup := fmt.ctprintf("rm -rf %s", tmp_dir)
		libc.system(cleanup)
	}

	full_cmd := fmt.ctprintf("HOME=%s %s > /dev/null 2>&1", tmp_dir, cmd)
	status := libc.system(full_cmd)
	return extract_exit_code(status)
}

// Run a command with an initialized wayu config in an isolated HOME
run_with_initialized_home :: proc(cmd: string) -> i32 {
	tmp_dir := "/tmp/wayu_exit_code_test_init"

	// Clean up any previous run
	cleanup_cmd := fmt.ctprintf("rm -rf %s", tmp_dir)
	libc.system(cleanup_cmd)

	// Create HOME and .config directory (init needs .config to exist)
	mkdir_cmd := fmt.ctprintf("mkdir -p %s/.config", tmp_dir)
	libc.system(mkdir_cmd)
	defer {
		cleanup := fmt.ctprintf("rm -rf %s", tmp_dir)
		libc.system(cleanup)
	}

	// First initialize wayu config in the temp HOME
	init_cmd := fmt.ctprintf("HOME=%s ./bin/wayu init > /dev/null 2>&1", tmp_dir)
	libc.system(init_cmd)

	// Now run the actual command
	full_cmd := fmt.ctprintf("HOME=%s %s > /dev/null 2>&1", tmp_dir, cmd)
	status := libc.system(full_cmd)
	return extract_exit_code(status)
}

// Run a command using the real HOME (for commands that don't need isolation)
run_command :: proc(cmd: string) -> i32 {
	full_cmd := fmt.ctprintf("%s > /dev/null 2>&1", cmd)
	status := libc.system(full_cmd)
	return extract_exit_code(status)
}

print_test :: proc(num: int, name: string, expected: i32, actual: i32, results: ^Test_Results) {
	passed := expected == actual
	if passed {
		fmt.printf("Test %d: %s... ✓ (exit %d)\n", num, name, actual)
		results.passed += 1
	} else {
		fmt.printf("Test %d: %s... ✗ (expected %d, got %d)\n", num, name, expected, actual)
		results.failed += 1
	}
}

main :: proc() {
	fmt.println("🔢 Testing BSD sysexits.h exit codes...")
	fmt.println()

	results := Test_Results{test_name = "exit_codes"}

	// Build
	fmt.print("Building wayu...")
	if libc.system("task build > /dev/null 2>&1") == 0 {
		fmt.println(" ✓")
	} else {
		fmt.println(" ✗")
		os.exit(1)
	}
	fmt.println()

	// Test 1: No arguments → EXIT_SUCCESS (shows help)
	{
		code := run_command("./bin/wayu")
		print_test(1, "No args shows help (EXIT_SUCCESS)", EXIT_SUCCESS, code, &results)
	}

	// Test 2: Unknown command → EXIT_USAGE
	{
		code := run_command("./bin/wayu foobar")
		print_test(2, "Unknown command (EXIT_USAGE)", EXIT_USAGE, code, &results)
	}

	// Test 3: path add with no args → EXIT_USAGE
	{
		code := run_with_initialized_home("./bin/wayu path add")
		print_test(3, "path add no args (EXIT_USAGE)", EXIT_USAGE, code, &results)
	}

	// Test 4: alias add with no args → EXIT_USAGE
	{
		code := run_with_initialized_home("./bin/wayu alias add")
		print_test(4, "alias add no args (EXIT_USAGE)", EXIT_USAGE, code, &results)
	}

	// Test 5: constants add with no args → EXIT_USAGE
	{
		code := run_with_initialized_home("./bin/wayu constants add")
		print_test(5, "constants add no args (EXIT_USAGE)", EXIT_USAGE, code, &results)
	}

	// Test 6: path rm with no args → EXIT_USAGE
	{
		code := run_with_initialized_home("./bin/wayu path rm")
		print_test(6, "path rm no args (EXIT_USAGE)", EXIT_USAGE, code, &results)
	}

	// Test 7: path unknown action → EXIT_USAGE
	{
		code := run_with_initialized_home("./bin/wayu path foobar")
		print_test(7, "path unknown action (EXIT_USAGE)", EXIT_USAGE, code, &results)
	}

	// Test 8: path list with no config → EXIT_CONFIG
	{
		code := run_with_temp_home("./bin/wayu path list")
		print_test(8, "path list no config (EXIT_CONFIG)", EXIT_CONFIG, code, &results)
	}

	// Test 9: help → EXIT_SUCCESS
	{
		code := run_command("./bin/wayu help")
		print_test(9, "help command (EXIT_SUCCESS)", EXIT_SUCCESS, code, &results)
	}

	// Test 10: version → EXIT_SUCCESS
	{
		code := run_command("./bin/wayu version")
		print_test(10, "version command (EXIT_SUCCESS)", EXIT_SUCCESS, code, &results)
	}

	// Test 11: path add with valid path after init → EXIT_SUCCESS
	{
		code := run_with_initialized_home("./bin/wayu path add /tmp")
		print_test(11, "path add after init (EXIT_SUCCESS)", EXIT_SUCCESS, code, &results)
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
