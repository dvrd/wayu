// component_test.odin - CLI mode for component testing and golden file management
//
// This module provides the entry point for component testing via:
//   wayu -c=<component> [args...] [--snapshot | --test]
//
// Usage:
//   wayu -c=box width=10 height=3           # Render component
//   wayu -c=box width=10 height=3 --snapshot # Save golden file
//   wayu -c=box width=10 height=3 --test     # Test against golden

package wayu

import "core:fmt"
import "core:os"
import tui "tui"

// Golden file directory
GOLDEN_DIR :: "tests/golden"

// Simple test function
simple_test_function :: proc() {
	fmt.println("Test")
}

// Run component test mode
run_component_testing :: proc(component_name: string, args: []string, snapshot: bool, verify: bool) {
	// Parse component type
	component_type, ok := tui.parse_component_type(component_name)
	if !ok {
		fmt.eprintfln("ERROR: Unknown component type: %s", component_name)
		fmt.eprintln("\nAvailable components:")
		fmt.eprintln("  - box")
		fmt.eprintln("  - list-item")
		fmt.eprintln("  - header")
		fmt.eprintln("  - footer")
		fmt.eprintln("  - scroll-indicator")
		fmt.eprintln("  - empty-state")
		os.exit(1)
	}

	// Parse component arguments
	component_args := tui.parse_component_args(args)
	defer tui.component_args_destroy(&component_args)

	// Render component
	output := tui.render_component(component_type, component_args)
	defer delete(output)

	// Handle different modes
	if snapshot {
		// Save golden file
		success := save_golden(component_name, component_args, output)
		if !success {
			os.exit(1)
		}
	} else if verify {
		// Test against golden file
		success := compare_golden(component_name, component_args, output)
		if !success {
			os.exit(1)
		}
	} else {
		// Just print output
		fmt.print(output)
	}
}

// Save golden file
save_golden :: proc(component: string, args: tui.ComponentArgs, output: string) -> bool {
	// Ensure directory exists
	os.make_directory(GOLDEN_DIR)

	// Build golden file path
	filename := fmt.aprintf("%s/%s_%dx%d.txt",
		GOLDEN_DIR, component, args.width, args.height)
	defer delete(filename)

	// Write golden file
	write_err := os.write_entire_file(filename, transmute([]byte)output)
	if write_err != nil {
		fmt.eprintfln("ERROR: Failed to write golden file: %s", filename)
		return false
	}

	fmt.printfln("✓ Saved golden file: %s", filename)
	return true
}

// Compare output against golden file
compare_golden :: proc(component: string, args: tui.ComponentArgs, output: string) -> bool {
	// Build golden file path
	filename := fmt.aprintf("%s/%s_%dx%d.txt",
		GOLDEN_DIR, component, args.width, args.height)
	defer delete(filename)

	// Check if golden file exists
	if !os.exists(filename) {
		fmt.eprintfln("ERROR: Golden file not found: %s", filename)
		fmt.eprintfln("Create it with: wayu -c=%s width=%d height=%d --snapshot",
			component, args.width, args.height)
		return false
	}

	// Read golden file
	golden_data, read_err := os.read_entire_file(filename, context.allocator)
	if read_err != nil {
		fmt.eprintfln("ERROR: Failed to read golden file: %s", filename)
		return false
	}
	defer delete(golden_data)

	golden_str := string(golden_data)

	// Compare
	if output != golden_str {
		fmt.eprintfln("✗ MISMATCH: %s", filename)
		fmt.eprintln("\nExpected:")
		fmt.eprintln(golden_str)
		fmt.eprintln("\nGot:")
		fmt.eprintln(output)
		return false
	}

	fmt.printfln("✓ MATCH: %s", filename)
	return true
}
