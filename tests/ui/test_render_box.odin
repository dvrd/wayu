// test_render_box.odin - Simplified UI alignment tests
//
// Verifies that preview boxes render correctly with proper border alignment.
// Shows only results (✓/✗) and summary.
// Run with: odin run tests/ui/test_render_box.odin -file -out:bin/test_render

package test_ui

import "core:fmt"
import "core:strings"
import "core:os"
import "../../src"

// Strip ANSI escape codes and carriage returns from a string
strip_ansi :: proc(s: string) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	in_escape := false
	for r in s {
		if r == '\x1b' {
			in_escape = true
		} else if in_escape && r == 'm' {
			in_escape = false
		} else if !in_escape && r != '\r' {
			strings.write_rune(&builder, r)
		}
	}

	return strings.clone(strings.to_string(builder))
}

// Verify that all lines in a box have the same visual width
verify_box_alignment :: proc(box: string, test_name: string) -> bool {
	clean_box := strip_ansi(box)
	defer delete(clean_box)

	lines := strings.split(clean_box, "\n")
	defer delete(lines)

	if len(lines) < 3 {
		fmt.printf("✗ %s: Not enough lines\n", test_name)
		return false
	}

	top_width := src.get_string_visual_width(lines[0])
	bottom_width := src.get_string_visual_width(lines[len(lines)-1])

	failed := false

	if top_width != bottom_width {
		fmt.printf("✗ %s: Top (%d) != Bottom (%d)\n", test_name, top_width, bottom_width)
		failed = true
	}

	for line, i in lines[1:len(lines)-1] {
		line_width := src.get_string_visual_width(line)
		if line_width != top_width {
			fmt.printf("✗ %s: Line %d width (%d) != Border (%d)\n", test_name, i+1, line_width, top_width)
			failed = true
		}
	}

	if !failed {
		fmt.printf("✓ %s\n", test_name)
	}

	return !failed
}

main :: proc() {
	src.init_special_chars()

	fmt.println("=== UI Alignment Tests ===\n")

	passed := 0
	failed_count := 0

	// Test 1: Constants preview with warning symbol
	{
		content := strings.builder_make()
		defer strings.builder_destroy(&content)
		fmt.sbprintf(&content, "Will add constant:\n")
		fmt.sbprintf(&content, "  %sexport MY_TEST=\"test value\"%s\n\n", src.get_secondary(), src.RESET)
		fmt.sbprintf(&content, "%s⚠ Constant already exists (will be updated)%s\n", src.get_warning(), src.RESET)

		preview := strings.to_string(content)
		box := src.render_box("Preview", preview)
		defer delete(box)

		if verify_box_alignment(box, "Constants preview with ⚠") {
			passed += 1
		} else {
			failed_count += 1
		}
	}

	// Test 2: Path preview with sparkles emoji
	{
		content := strings.builder_make()
		defer strings.builder_destroy(&content)
		fmt.sbprintf(&content, "Will add to PATH:\n")
		fmt.sbprintf(&content, "  %s/usr/local/bin%s\n\n", src.get_secondary(), src.RESET)
		fmt.sbprintf(&content, "%s✨ New path will be added to the end%s\n", src.get_secondary(), src.RESET)

		preview := strings.to_string(content)
		box := src.render_box("Preview", preview)
		defer delete(box)

		if verify_box_alignment(box, "Path preview with ✨") {
			passed += 1
		} else {
			failed_count += 1
		}
	}

	// Test 3: Multiple wide characters
	{
		content := strings.builder_make()
		defer strings.builder_destroy(&content)
		fmt.sbprintf(&content, "%s⚠ Warning message%s\n", src.get_warning(), src.RESET)
		fmt.sbprintf(&content, "%s✨ Info message%s\n", src.get_secondary(), src.RESET)
		fmt.sbprintf(&content, "%s✓ Success message%s\n", src.get_secondary(), src.RESET)

		preview := strings.to_string(content)
		box := src.render_box("Preview", preview)
		defer delete(box)

		if verify_box_alignment(box, "Multiple wide characters") {
			passed += 1
		} else {
			failed_count += 1
		}
	}

	// Test 4: Title box - short title
	{
		title_box := src.render_title_box("Add Constant")
		defer delete(title_box)

		if verify_box_alignment(title_box, "Title box - short") {
			passed += 1
		} else {
			failed_count += 1
		}
	}

	// Test 5: Title box - long title
	{
		title_box := src.render_title_box("Interactive Configuration Manager")
		defer delete(title_box)

		if verify_box_alignment(title_box, "Title box - long") {
			passed += 1
		} else {
			failed_count += 1
		}
	}

	// Test 6: Title box - title with emoji
	{
		title_box := src.render_title_box("✨ Configuration")
		defer delete(title_box)

		if verify_box_alignment(title_box, "Title box with emoji") {
			passed += 1
		} else {
			failed_count += 1
		}
	}

	// Test 7: Input field - empty with placeholder
	{
		input := src.new_input("Enter value", 40)
		defer src.input_destroy(&input)

		input_str := src.input_render(&input)
		defer delete(input_str)

		if verify_box_alignment(input_str, "Input field - empty") {
			passed += 1
		} else {
			failed_count += 1
		}
	}

	// Test 8: Input field - with text, focused
	{
		input := src.new_input("Enter value", 40)
		input.focused = true
		src.input_set_value(&input, "test value")
		defer src.input_destroy(&input)

		input_str := src.input_render(&input)
		defer delete(input_str)

		if verify_box_alignment(input_str, "Input field - focused") {
			passed += 1
		} else {
			failed_count += 1
		}
	}

	fmt.println()
	fmt.println("=== Test Summary ===")
	fmt.printf("Passed: %d\n", passed)
	fmt.printf("Failed: %d\n", failed_count)
	fmt.println()

	if failed_count > 0 {
		os.exit(1)
	}
}
