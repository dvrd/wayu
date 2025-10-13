// input.odin - Text input component with cursor and editing
//
// Provides an interactive text input field with:
// - Cursor positioning and navigation
// - Character insertion and deletion
// - Visual rendering with borders
// - Real-time validation feedback

package wayu

import "core:fmt"
import "core:strings"
import "core:os"

// InputValidation extends ValidationResult with additional UI feedback
InputValidation :: struct {
	valid:         bool,
	error_message: string,
	warning:       string,
	info:          string,
}

// Input represents a text input field
Input :: struct {
	value:       string,        // Current input value
	cursor_pos:  int,           // Cursor position in string
	placeholder: string,        // Placeholder text when empty
	validator:   proc(string) -> InputValidation, // Optional validator
	width:       int,           // Display width
	focused:     bool,          // Whether input has focus
	validation:  InputValidation, // Current validation state
}

// Create a new input field
new_input :: proc(placeholder: string, width: int) -> Input {
	return Input{
		value = "",
		cursor_pos = 0,
		placeholder = placeholder,
		validator = nil,
		width = width,
		focused = false,
		validation = InputValidation{valid = true, error_message = "", warning = "", info = ""},
	}
}

// Create input with validator
new_input_with_validator :: proc(
	placeholder: string,
	width: int,
	validator: proc(string) -> InputValidation,
) -> Input {
	input := new_input(placeholder, width)
	input.validator = validator
	return input
}

// Handle keyboard input
input_handle_key :: proc(input: ^Input, ch: byte) -> bool {
	// Returns true if input was modified
	modified := false

	switch ch {
	case 127, 8: // Backspace/Delete
		if input.cursor_pos > 0 {
			input_delete_before_cursor(input)
			modified = true
		}

	case 3: // Ctrl+C
		return false // Signal cancellation

	case 13, 10: // Enter
		return false // Signal completion

	case: // Regular character
		if ch >= 32 && ch <= 126 {
			input_insert_at_cursor(input, ch)
			modified = true
		}
	}

	// Handle escape sequences (arrow keys) separately in calling code

	// Validate if modified
	if modified && input.validator != nil {
		input.validation = input.validator(input.value)
	}

	return modified
}

// Handle arrow key navigation
input_handle_arrow :: proc(input: ^Input, direction: string) {
	switch direction {
	case "left":
		if input.cursor_pos > 0 {
			input.cursor_pos -= 1
		}

	case "right":
		if input.cursor_pos < len(input.value) {
			input.cursor_pos += 1
		}

	case "home":
		input.cursor_pos = 0

	case "end":
		input.cursor_pos = len(input.value)
	}
}

// Insert character at cursor position
input_insert_at_cursor :: proc(input: ^Input, ch: byte) {
	// Build new value with inserted character
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	// Add characters before cursor
	if input.cursor_pos > 0 {
		strings.write_string(&builder, input.value[:input.cursor_pos])
	}

	// Add new character
	strings.write_byte(&builder, ch)

	// Add characters after cursor
	if input.cursor_pos < len(input.value) {
		strings.write_string(&builder, input.value[input.cursor_pos:])
	}

	// Update value (free old, assign new)
	if len(input.value) > 0 {
		delete(input.value)
	}
	input.value = strings.clone(strings.to_string(builder))
	input.cursor_pos += 1
}

// Delete character before cursor
input_delete_before_cursor :: proc(input: ^Input) {
	if input.cursor_pos == 0 || len(input.value) == 0 {
		return
	}

	// Build new value without character before cursor
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	// Add characters before cursor (excluding last one)
	if input.cursor_pos > 1 {
		strings.write_string(&builder, input.value[:input.cursor_pos - 1])
	}

	// Add characters after cursor
	if input.cursor_pos < len(input.value) {
		strings.write_string(&builder, input.value[input.cursor_pos:])
	}

	// Update value
	if len(input.value) > 0 {
		delete(input.value)
	}
	input.value = strings.clone(strings.to_string(builder))
	input.cursor_pos -= 1
}

// Delete character at cursor
input_delete_at_cursor :: proc(input: ^Input) {
	if input.cursor_pos >= len(input.value) {
		return
	}

	// Build new value without character at cursor
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	// Add characters before cursor
	if input.cursor_pos > 0 {
		strings.write_string(&builder, input.value[:input.cursor_pos])
	}

	// Add characters after cursor (skip one)
	if input.cursor_pos + 1 < len(input.value) {
		strings.write_string(&builder, input.value[input.cursor_pos + 1:])
	}

	// Update value
	if len(input.value) > 0 {
		delete(input.value)
	}
	input.value = strings.clone(strings.to_string(builder))
	// Cursor position stays the same
}

// Render the input field
input_render :: proc(input: ^Input) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	// Top border
	strings.write_string(&builder, "┌")
	for i in 0 ..< input.width - 2 {
		strings.write_string(&builder, "─")
	}
	strings.write_string(&builder, "┐\r\n")

	// Content line
	strings.write_string(&builder, "│ ")

	display_text := input.value
	display_len := len(display_text)

	// Show placeholder if empty
	if display_len == 0 {
		fmt.sbprintf(&builder, "%s%s%s", DIM, input.placeholder, RESET)
		padding_needed := input.width - 4 - len(input.placeholder)
		for i in 0 ..< padding_needed {
			strings.write_byte(&builder, ' ')
		}
	} else {
		// Show value with cursor
		if input.focused {
			// Render value with cursor indicator
			before_cursor := ""
			cursor_char := "█" // Block cursor
			after_cursor := ""

			if input.cursor_pos > 0 {
				before_cursor = display_text[:input.cursor_pos]
			}
			if input.cursor_pos < display_len {
				cursor_char = string([]byte{display_text[input.cursor_pos]})
				if input.cursor_pos + 1 < display_len {
					after_cursor = display_text[input.cursor_pos + 1:]
				}
			}

			// Write with cursor highlight
			strings.write_string(&builder, before_cursor)
			fmt.sbprintf(&builder, "%s%s%s%s", BOLD, get_primary(), cursor_char, RESET)
			strings.write_string(&builder, after_cursor)

			// Calculate padding
			visible_len := display_len
			if input.cursor_pos < display_len {
				visible_len = display_len // Cursor replaces char
			} else {
				visible_len = display_len + 1 // Cursor at end
			}
			padding_needed := input.width - 4 - visible_len
			for i in 0 ..< padding_needed {
				strings.write_byte(&builder, ' ')
			}
		} else {
			// Not focused - just show text
			strings.write_string(&builder, display_text)
			padding_needed := input.width - 4 - display_len
			for i in 0 ..< padding_needed {
				strings.write_byte(&builder, ' ')
			}
		}
	}

	strings.write_string(&builder, " │\r\n")

	// Bottom border
	strings.write_string(&builder, "└")
	for i in 0 ..< input.width - 2 {
		strings.write_string(&builder, "─")
	}
	strings.write_string(&builder, "┘")

	return strings.clone(strings.to_string(builder))
}

// Render validation feedback
input_render_validation :: proc(validation: InputValidation) -> string {
	if validation.valid && len(validation.warning) == 0 && len(validation.info) == 0 {
		return ""
	}

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	strings.write_string(&builder, "\r\n")

	// Error message
	if !validation.valid && len(validation.error_message) > 0 {
		fmt.sbprintf(&builder, "%s✗ %s%s\r\n", get_error(), validation.error_message, RESET)
	}

	// Warning message
	if len(validation.warning) > 0 {
		fmt.sbprintf(&builder, "%s⚠ %s%s\r\n", get_warning(), validation.warning, RESET)
	}

	// Info message
	if len(validation.info) > 0 {
		fmt.sbprintf(&builder, "%sℹ %s%s\r\n", get_secondary(), validation.info, RESET)
	}

	// Success indicator
	if validation.valid && len(validation.error_message) == 0 {
		fmt.sbprintf(&builder, "%s✓ Valid input%s\r\n", get_success(), RESET)
	}

	return strings.clone(strings.to_string(builder))
}

// Clean up input resources
input_destroy :: proc(input: ^Input) {
	if len(input.value) > 0 {
		delete(input.value)
	}
	if len(input.validation.error_message) > 0 {
		delete(input.validation.error_message)
	}
	if len(input.validation.warning) > 0 {
		delete(input.validation.warning)
	}
	if len(input.validation.info) > 0 {
		delete(input.validation.info)
	}
}

// Set input value programmatically
input_set_value :: proc(input: ^Input, value: string) {
	if len(input.value) > 0 {
		delete(input.value)
	}
	input.value = strings.clone(value)
	input.cursor_pos = len(input.value)

	// Validate
	if input.validator != nil {
		input.validation = input.validator(input.value)
	}
}

// Get input value (caller must delete)
input_get_value :: proc(input: ^Input) -> string {
	return strings.clone(input.value)
}

// Clear input
input_clear :: proc(input: ^Input) {
	if len(input.value) > 0 {
		delete(input.value)
	}
	input.value = ""
	input.cursor_pos = 0
	input.validation = InputValidation{valid = true, error_message = "", warning = "", info = ""}
}
