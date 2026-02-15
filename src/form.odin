// form.odin - Form component for managing multiple input fields
//
// Provides interactive forms with:
// - Multiple input fields with labels
// - Keyboard navigation (Tab, Shift+Tab, arrows)
// - Real-time validation per field
// - Preview panel for showing what will change
// - Submit/Cancel actions

package wayu

import "core:fmt"
import "core:strings"
import "core:os"

// FormField represents a single field in a form
FormField :: struct {
	label:       string,
	input:       Input,
	validation:  InputValidation,
	required:    bool,
}

// Form represents a complete form with multiple fields
Form :: struct {
	title:         string,
	fields:        []FormField,
	current_field: int,
	preview_fn:    proc(^Form) -> string, // Generate preview content
	submit_fn:     proc(^Form) -> bool,   // Handle form submission
	submitted:     bool,                  // Track if form was submitted
	cancelled:     bool,                  // Track if form was cancelled
}

// Create a new form
new_form :: proc(
	title: string,
	fields: []FormField,
	preview_fn: proc(^Form) -> string,
	submit_fn: proc(^Form) -> bool,
) -> Form {
	return Form{
		title = title,
		fields = fields,
		current_field = 0,
		preview_fn = preview_fn,
		submit_fn = submit_fn,
		submitted = false,
		cancelled = false,
	}
}

// Run the interactive form
form_run :: proc(form: ^Form) -> bool {
	// Initialize special character width mappings
	init_special_chars()

	// Enable raw mode for character-by-character input
	enable_raw_mode()

	// Terminal control sequences
	CLEAR_SCREEN :: "\033[2J\033[H"
	HIDE_CURSOR :: "\033[?25l"
	SHOW_CURSOR :: "\033[?25h"

	fmt.print(HIDE_CURSOR)

	// Ensure terminal is always restored
	defer {
		fmt.print(CLEAR_SCREEN)
		fmt.print(SHOW_CURSOR)
		disable_raw_mode()
	}

	// Focus first field
	if len(form.fields) > 0 {
		form.fields[form.current_field].input.focused = true
	}

	// Initial render
	form_render_full(form)

	// Main input loop
	for {
		input_buf: [8]byte
		n, err := os.read(os.stdin, input_buf[:])
		if err != 0 || n == 0 {
			continue
		}

		ch := input_buf[0]

		// Handle form-level navigation and actions
		if ch == 3 || ch == 'q' || ch == 'Q' { // Ctrl+C or 'q' - Cancel
			form.cancelled = true
			return false

		} else if ch == 9 { // Tab - Next field
			form_next_field(form)
			form_render_full(form)

		} else if ch == 27 && n >= 3 { // Escape sequences
			if input_buf[1] == '[' {
				switch input_buf[2] {
				case 'A': // Up arrow - Previous field
					form_prev_field(form)
					form_render_full(form)

				case 'B': // Down arrow - Next field
					form_next_field(form)
					form_render_full(form)

				case 'C': // Right arrow - Pass to input
					if form.current_field < len(form.fields) {
						field := &form.fields[form.current_field]
						input_handle_arrow(&field.input, "right")
						form_render_full(form)
					}

				case 'D': // Left arrow - Pass to input
					if form.current_field < len(form.fields) {
						field := &form.fields[form.current_field]
						input_handle_arrow(&field.input, "left")
						form_render_full(form)
					}

				case 'H': // Home - Pass to input
					if form.current_field < len(form.fields) {
						field := &form.fields[form.current_field]
						input_handle_arrow(&field.input, "home")
						form_render_full(form)
					}

				case 'F': // End - Pass to input
					if form.current_field < len(form.fields) {
						field := &form.fields[form.current_field]
						input_handle_arrow(&field.input, "end")
						form_render_full(form)
					}
				}
			}

		} else if ch == 13 || ch == 10 { // Enter - Try to submit
			if form_validate(form) {
				form.submitted = true
				success := form.submit_fn(form)
				return success
			} else {
				// Invalid - just re-render to show validation errors
				form_render_full(form)
			}

		} else {
			// Pass character to current field input
			if form.current_field < len(form.fields) {
				field := &form.fields[form.current_field]
				modified := input_handle_key(&field.input, ch)
				if modified {
					// Re-validate field
					if field.input.validator != nil {
						// Free old validation strings
						if len(field.validation.error_message) > 0 {
							delete(field.validation.error_message)
						}
						if len(field.validation.warning) > 0 {
							delete(field.validation.warning)
						}
						if len(field.validation.info) > 0 {
							delete(field.validation.info)
						}

						field.validation = field.input.validator(field.input.value)
					}
					form_render_full(form)
				}
			}
		}
	}

	return false
}

// Navigate to next field
form_next_field :: proc(form: ^Form) {
	if len(form.fields) == 0 do return

	// Unfocus current field
	form.fields[form.current_field].input.focused = false

	// Move to next
	form.current_field = (form.current_field + 1) % len(form.fields)

	// Focus new field
	form.fields[form.current_field].input.focused = true
}

// Navigate to previous field
form_prev_field :: proc(form: ^Form) {
	if len(form.fields) == 0 do return

	// Unfocus current field
	form.fields[form.current_field].input.focused = false

	// Move to previous
	form.current_field = (form.current_field - 1 + len(form.fields)) % len(form.fields)

	// Focus new field
	form.fields[form.current_field].input.focused = true
}

// Validate all form fields
form_validate :: proc(form: ^Form) -> bool {
	all_valid := true

	for field, i in form.fields {
		// Free old validation strings
		if len(form.fields[i].validation.error_message) > 0 {
			delete(form.fields[i].validation.error_message)
		}
		if len(form.fields[i].validation.warning) > 0 {
			delete(form.fields[i].validation.warning)
		}
		if len(form.fields[i].validation.info) > 0 {
			delete(form.fields[i].validation.info)
		}

		// Check required fields
		if field.required && len(field.input.value) == 0 {
			form.fields[i].validation = InputValidation{
				valid = false,
				error_message = "This field is required",
				warning = "",
				info = "",
			}
			all_valid = false
			continue
		}

		// Run field validator
		if field.input.validator != nil {
			result := field.input.validator(field.input.value)
			form.fields[i].validation = result
			if !result.valid {
				all_valid = false
			}
		}
	}

	return all_valid
}

// Render the complete form UI
form_render_full :: proc(form: ^Form) {
	// Clear screen and scrollback buffer, move to top
	fmt.print("\033[2J\033[3J\033[H")

	// Build form content
	content_builder := strings.builder_make()
	defer strings.builder_destroy(&content_builder)

	// Title box (with indentation to match other elements)
	title_box := render_title_box(form.title)
	// Use temp allocator for lines array since it's only needed during rendering
	title_lines := strings.split(title_box, "\r\n", context.temp_allocator)
	// No need to defer delete - temp allocator manages this
	for title_line in title_lines {
		fmt.sbprintf(&content_builder, "  %s\r\n", title_line)
	}
	fmt.sbprint(&content_builder, "\r\n")
	defer delete(title_box)

	// Render each field
	for field, i in form.fields {
		is_current := i == form.current_field

		// Field label
		label_color := get_secondary()
		if is_current {
			label_color = get_primary()
		}
		fmt.sbprintf(&content_builder, "  %s%s%s\r\n", label_color, field.label, RESET)

		// Input field (need to get mutable reference)
		field_input := form.fields[i].input
		input_render_str := input_render(&field_input)
		// Use temp allocator for lines array since it's only needed during rendering
		input_lines := strings.split(input_render_str, "\r\n", context.temp_allocator)
		// No need to defer delete - temp allocator manages this
		for input_line in input_lines {
			fmt.sbprintf(&content_builder, "  %s\r\n", input_line)
		}
		defer delete(input_render_str)

		// Validation feedback for current field
		if is_current {
			validation_str := input_render_validation(field.validation)
			if len(validation_str) > 0 {
				// Indent validation messages
				// Use temp allocator for lines array since it's only needed during rendering
				lines := strings.split(validation_str, "\r\n", context.temp_allocator)
				// No need to defer delete - temp allocator manages this
				for line in lines {
					if len(line) > 0 {
						fmt.sbprintf(&content_builder, "  %s\r\n", line)
					}
				}
				defer delete(validation_str)
			}
		}

		fmt.sbprint(&content_builder, "\r\n")
	}

	// Keyboard hints
	fmt.sbprintf(&content_builder, "  %s⌨  Tab/↑↓ Navigate  •  Enter Submit  •  Ctrl+C Cancel%s\r\n\r\n", DIM, RESET)

	// Preview panel (if function provided)
	if form.preview_fn != nil {
		preview_content := form.preview_fn(form)
		if len(preview_content) > 0 {
			preview_box := render_box("Preview", preview_content)
			// Use temp allocator for lines array since it's only needed during rendering
			preview_lines := strings.split(preview_box, "\r\n", context.temp_allocator)
			// No need to defer delete - temp allocator manages this
			for preview_line in preview_lines {
				fmt.sbprintf(&content_builder, "  %s\r\n", preview_line)
			}
			defer delete(preview_box)
			defer delete(preview_content)
		}
	}

	// Get form content
	form_content := strings.to_string(content_builder)

	// Wrap in container border
	container := render_form_container(form_content)
	defer delete(container)

	// Print the container
	fmt.print(container)
}

// Render title box
render_title_box :: proc(title: string) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	width := 68 // Standard width (interior content width, not including │ borders)
	title_visual_width := get_string_visual_width(title)
	// Subtract 2 for the padding spaces around title
	padding_left := (width - title_visual_width) / 2
	padding_right := width - title_visual_width - padding_left

	// Top border
	fmt.sbprintf(&builder, "%s╭", get_primary())
	for i in 0 ..< width {
		strings.write_string(&builder, "─")
	}
	fmt.sbprintf(&builder, "╮%s\r\n", RESET)

	// Title line
	fmt.sbprintf(&builder, "%s│%s", get_primary(), RESET)
	for i in 0 ..< padding_left {
		strings.write_byte(&builder, ' ')
	}
	fmt.sbprintf(&builder, "%s%s%s%s", BOLD, get_primary(), title, RESET)
	for i in 0 ..< padding_right {
		strings.write_byte(&builder, ' ')
	}
	fmt.sbprintf(&builder, "%s│%s", get_primary(), RESET)

	// Bottom border
	fmt.sbprintf(&builder, "\r\n%s╰", get_primary())
	for i in 0 ..< width {
		strings.write_string(&builder, "─")
	}
	fmt.sbprintf(&builder, "╯%s", RESET)

	return strings.clone(strings.to_string(builder))
}

// Render a generic box with title and content
render_box :: proc(title: string, content: string) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	width := 68

	// Top border with title
	fmt.sbprintf(&builder, "%s╭─ %s ", get_secondary(), title)
	title_visual_width := get_string_visual_width(title)
	remaining := width - title_visual_width - 3  // -3 for "─ " before title and " " after title
	for i in 0 ..< remaining {
		strings.write_string(&builder, "─")
	}
	fmt.sbprintf(&builder, "╮%s\r\n", RESET)

	// Content (split by lines)
	// Use temp allocator for lines array since it's only needed during rendering
	lines := strings.split(content, "\n", context.temp_allocator)
	// No need to defer delete - temp allocator manages this

	for line in lines {
		trimmed := strings.trim_right_space(line)

		// Strip ANSI codes for width calculation
		stripped := trimmed
		// Simple ANSI stripping (remove escape sequences)
		if strings.contains(trimmed, "\x1b[") {
			// Count actual visible width by extracting visible characters
			visible_chars := strings.builder_make()
			defer strings.builder_destroy(&visible_chars)

			in_escape := false
			for r in trimmed {
				if r == '\x1b' {
					in_escape = true
				} else if in_escape && r == 'm' {
					in_escape = false
				} else if !in_escape {
					strings.write_rune(&visible_chars, r)
				}
			}

			visible_str := strings.to_string(visible_chars)
			visual_width := get_string_visual_width(visible_str)

			fmt.sbprintf(&builder, "%s│%s %s", get_secondary(), RESET, trimmed)
			// Padding calculation: width (68) - visual_width - 2 (for leading and final spaces)
			padding := width - visual_width - 2
			for i in 0 ..< padding {
				strings.write_byte(&builder, ' ')
			}
			strings.write_byte(&builder, ' ')  // Final space before right border
		} else {
			// No ANSI codes
			line_visual_width := get_string_visual_width(trimmed)
			fmt.sbprintf(&builder, "%s│%s %s", get_secondary(), RESET, trimmed)
			padding := width - line_visual_width - 2  // -2 for leading space and final space before │
			for i in 0 ..< padding {
				strings.write_byte(&builder, ' ')
			}
			strings.write_byte(&builder, ' ')  // Final space before right border
		}

		fmt.sbprintf(&builder, "%s│%s\r\n", get_secondary(), RESET)
	}

	// Bottom border
	fmt.sbprintf(&builder, "%s╰", get_secondary())
	for i in 0 ..< width {
		strings.write_string(&builder, "─")
	}
	fmt.sbprintf(&builder, "╯%s", RESET)

	return strings.clone(strings.to_string(builder))
}

// Render form container with border
render_form_container :: proc(content: string) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	width := 74  // Container width (interior content width)

	// Top border
	fmt.sbprintf(&builder, "%s┌", get_primary())
	for i in 0 ..< width {
		strings.write_string(&builder, "─")
	}
	fmt.sbprintf(&builder, "┐%s\r\n", RESET)

	// Content lines
	// Use temp allocator for lines array since it's only needed during rendering
	lines := strings.split(content, "\r\n", context.temp_allocator)
	// No need to defer delete - temp allocator manages this

	for line in lines {
		// Strip ANSI codes for width calculation
		visible_chars := strings.builder_make()
		defer strings.builder_destroy(&visible_chars)

		in_escape := false
		for r in line {
			if r == '\x1b' {
				in_escape = true
			} else if in_escape && r == 'm' {
				in_escape = false
			} else if !in_escape {
				strings.write_rune(&visible_chars, r)
			}
		}

		visible_str := strings.to_string(visible_chars)
		visual_width := get_string_visual_width(visible_str)

		// Write line with content (no extra space after │)
		fmt.sbprintf(&builder, "%s│%s", get_primary(), RESET)
		fmt.sbprintf(&builder, "%s", line)

		// Calculate padding needed to reach the right border
		// width - visual_width already in line
		padding := width - visual_width
		for i in 0 ..< padding {
			strings.write_byte(&builder, ' ')
		}
		fmt.sbprintf(&builder, "%s│%s\r\n", get_primary(), RESET)
	}

	// Bottom border
	fmt.sbprintf(&builder, "%s└", get_primary())
	for i in 0 ..< width {
		strings.write_string(&builder, "─")
	}
	fmt.sbprintf(&builder, "┘%s", RESET)

	return strings.clone(strings.to_string(builder))
}

// Get field value by index
form_get_field_value :: proc(form: ^Form, field_index: int) -> string {
	if field_index >= 0 && field_index < len(form.fields) {
		return strings.clone(form.fields[field_index].input.value)
	}
	return ""
}

// Clean up form resources
form_destroy :: proc(form: ^Form) {
	for field, i in form.fields {
		// Need mutable reference
		field_input := form.fields[i].input
		input_destroy(&field_input)
		if len(field.validation.error_message) > 0 {
			delete(field.validation.error_message)
		}
		if len(field.validation.warning) > 0 {
			delete(field.validation.warning)
		}
		if len(field.validation.info) > 0 {
			delete(field.validation.info)
		}
	}
}
