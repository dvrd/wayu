// test_form_container.odin - Visual test for form container border
//
// Shows how the form looks with the new container border.
// Run with: odin run tests/ui/test_form_container.odin -file -out:bin/test_form_container

package test_form_container

import "core:fmt"
import "core:strings"
import "../../src"

main :: proc() {
	src.init_special_chars()

	fmt.println("=== Form Container Visual Test ===\n")
	fmt.println("This shows how a form looks with the new container border.\n")

	// Create sample form content
	content_builder := strings.builder_make()
	defer strings.builder_destroy(&content_builder)

	// Title box (with indentation to match other elements)
	title_box := src.render_title_box("Add Environment Variable")
	title_lines := strings.split(title_box, "\r\n")
	defer delete(title_lines)
	for title_line in title_lines {
		fmt.sbprintf(&content_builder, "  %s\r\n", title_line)
	}
	fmt.sbprint(&content_builder, "\r\n")
	defer delete(title_box)

	// Field labels and inputs (simulated)
	fmt.sbprintf(&content_builder, "  %sConstant Name%s\r\n", src.get_primary(), src.RESET)
	fmt.sbprintf(&content_builder, "  %s┌────────────────────────────────────────┐%s\r\n", src.get_secondary(), src.RESET)
	fmt.sbprintf(&content_builder, "  %s│%s MY_VARIABLE                          %s│%s\r\n",
		src.get_secondary(), src.RESET, src.get_secondary(), src.RESET)
	fmt.sbprintf(&content_builder, "  %s└────────────────────────────────────────┘%s\r\n\r\n", src.get_secondary(), src.RESET)

	fmt.sbprintf(&content_builder, "  %sConstant Value%s\r\n", src.get_secondary(), src.RESET)
	fmt.sbprintf(&content_builder, "  %s┌────────────────────────────────────────┐%s\r\n", src.get_secondary(), src.RESET)
	fmt.sbprintf(&content_builder, "  %s│%s test value                           %s│%s\r\n",
		src.get_secondary(), src.RESET, src.get_secondary(), src.RESET)
	fmt.sbprintf(&content_builder, "  %s└────────────────────────────────────────┘%s\r\n\r\n", src.get_secondary(), src.RESET)

	// Keyboard hints
	fmt.sbprintf(&content_builder, "  %s⌨  Tab/↑↓ Navigate  •  Enter Submit  •  Ctrl+C Cancel%s\r\n\r\n", src.DIM, src.RESET)

	// Preview box
	preview_content := strings.builder_make()
	defer strings.builder_destroy(&preview_content)
	fmt.sbprintf(&preview_content, "Will add constant:\n")
	fmt.sbprintf(&preview_content, "  %sexport MY_VARIABLE=\"test value\"%s\n\n", src.get_secondary(), src.RESET)
	fmt.sbprintf(&preview_content, "%s⚠ Constant name should be uppercase%s\n", src.get_warning(), src.RESET)

	preview_str := strings.to_string(preview_content)
	preview_box := src.render_box("Preview", preview_str)
	preview_lines := strings.split(preview_box, "\r\n")
	defer delete(preview_lines)
	for preview_line in preview_lines {
		fmt.sbprintf(&content_builder, "  %s\r\n", preview_line)
	}
	defer delete(preview_box)

	// Get form content
	form_content := strings.to_string(content_builder)

	// Wrap in container
	container := src.render_form_container(form_content)
	defer delete(container)

	// Display
	fmt.println(container)
	fmt.println()

	fmt.println("=== Inspection ===")
	fmt.println("Check that:")
	fmt.println("  ✓ Container border surrounds entire form")
	fmt.println("  ✓ All inner boxes are properly indented")
	fmt.println("  ✓ No alignment issues with borders")
	fmt.println("  ✓ Title box, fields, hints, and preview are all contained")
}
