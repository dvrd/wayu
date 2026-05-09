// test_visual_alignment.odin - Visual width verification test
//
// Verifies that all lines in a box have the same visual width.
// Run with: odin run tests/ui/test_visual_alignment.odin -file -out:bin/test_visual

package test_visual

import "core:fmt"
import "core:strings"
import "../../src"

main :: proc() {
	src.init_special_chars()

	// Build preview with both types of lines
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	fmt.sbprintf(&builder, "Will add constant:\n")
	fmt.sbprintf(&builder, "  %sexport MY_TEST=\"test value\"%s\n\n", src.get_secondary(), src.RESET)
	fmt.sbprintf(&builder, "%s⚠ Constant already exists (will be updated)%s\n", src.get_warning(), src.RESET)

	preview := strings.to_string(builder)
	box := src.render_box("Preview", preview)
	defer delete(box)

	// Strip ANSI and \r
	clean_builder := strings.builder_make()
	defer strings.builder_destroy(&clean_builder)

	in_escape := false
	for r in box {
		if r == '\x1b' {
			in_escape = true
		} else if in_escape && r == 'm' {
			in_escape = false
		} else if !in_escape && r != '\r' {
			strings.write_rune(&clean_builder, r)
		}
	}

	clean_box := strings.to_string(clean_builder)
	lines := strings.split(clean_box, "\n")
	defer delete(lines)

	fmt.println("=== Visual Alignment Check ===\n")

	// Check visual widths
	line1 := lines[1]
	line4 := lines[4]

	visual_width_1 := src.get_string_visual_width(line1)
	visual_width_4 := src.get_string_visual_width(line4)
	visual_width_top := src.get_string_visual_width(lines[0])
	visual_width_bottom := src.get_string_visual_width(lines[len(lines)-1])

	fmt.println("Visual Width Analysis:")
	fmt.printf("  Line 1 (no wide char): %d\n", visual_width_1)
	fmt.printf("  Line 4 (with ⚠):      %d\n", visual_width_4)
	fmt.printf("  Top border:           %d\n", visual_width_top)
	fmt.printf("  Bottom border:        %d\n", visual_width_bottom)
	fmt.println()

	all_match := visual_width_1 == visual_width_4 &&
	             visual_width_1 == visual_width_top &&
	             visual_width_1 == visual_width_bottom

	if all_match {
		fmt.println("✓ All lines have the same visual width - borders are aligned!")
		fmt.printf("  All lines: %d visual width\n", visual_width_1)
	} else {
		fmt.println("✗ MISALIGNMENT DETECTED: Visual widths differ!")
		fmt.printf("  Expected all to be: %d\n", visual_width_top)
	}
}
