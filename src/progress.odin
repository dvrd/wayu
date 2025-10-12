package wayu

import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

// Progress bar component
ProgressBar :: struct {
	width: int,
	filled_char: rune,
	empty_char: rune,
	show_percentage: bool,
	show_value: bool,
	style: Style,
	filled_style: Style,
	empty_style: Style,
	text_style: Style,
	current: f64,
	total: f64,
	prefix: string,
	suffix: string,
}

// Create a new progress bar
new_progress_bar :: proc(total: f64) -> ProgressBar {
	return ProgressBar{
		width = 40,
		filled_char = '█',
		empty_char = '░',
		show_percentage = true,
		show_value = false,
		style = new_style(),
		filled_style = style_foreground(new_style(), "green"),
		empty_style = style_foreground(new_style(), "grey"),
		text_style = new_style(),
		current = 0,
		total = total,
		prefix = "",
		suffix = "",
	}
}

// Set progress bar width
progress_width :: proc(pb: ^ProgressBar, width: int) -> ^ProgressBar {
	pb.width = width
	return pb
}

// Set progress bar characters
progress_chars :: proc(pb: ^ProgressBar, filled: rune, empty: rune) -> ^ProgressBar {
	pb.filled_char = filled
	pb.empty_char = empty
	return pb
}

// Set whether to show percentage
progress_show_percentage :: proc(pb: ^ProgressBar, show: bool) -> ^ProgressBar {
	pb.show_percentage = show
	return pb
}

// Set whether to show value
progress_show_value :: proc(pb: ^ProgressBar, show: bool) -> ^ProgressBar {
	pb.show_value = show
	return pb
}

// Style the progress bar container
progress_style :: proc(pb: ^ProgressBar, s: Style) -> ^ProgressBar {
	pb.style = s
	return pb
}

// Style the filled portion
progress_filled_style :: proc(pb: ^ProgressBar, s: Style) -> ^ProgressBar {
	pb.filled_style = s
	return pb
}

// Style the empty portion
progress_empty_style :: proc(pb: ^ProgressBar, s: Style) -> ^ProgressBar {
	pb.empty_style = s
	return pb
}

// Style the text
progress_text_style :: proc(pb: ^ProgressBar, s: Style) -> ^ProgressBar {
	pb.text_style = s
	return pb
}

// Set prefix text
progress_prefix :: proc(pb: ^ProgressBar, prefix: string) -> ^ProgressBar {
	if len(pb.prefix) > 0 {
		delete(pb.prefix)
	}
	pb.prefix = strings.clone(prefix)
	return pb
}

// Set suffix text
progress_suffix :: proc(pb: ^ProgressBar, suffix: string) -> ^ProgressBar {
	if len(pb.suffix) > 0 {
		delete(pb.suffix)
	}
	pb.suffix = strings.clone(suffix)
	return pb
}

// Update progress value
progress_set :: proc(pb: ^ProgressBar, current: f64) {
	pb.current = math.clamp(current, 0, pb.total)
}

// Increment progress
progress_increment :: proc(pb: ^ProgressBar, amount: f64 = 1) {
	progress_set(pb, pb.current + amount)
}

// Get progress percentage (0-100)
progress_percentage :: proc(pb: ProgressBar) -> f64 {
	if pb.total <= 0 {
		return 0
	}
	return (pb.current / pb.total) * 100
}

// Check if progress is complete
progress_is_complete :: proc(pb: ProgressBar) -> bool {
	return pb.current >= pb.total
}

// Render the progress bar
progress_render :: proc(pb: ProgressBar) -> string {
	result := strings.Builder{}
	defer strings.builder_destroy(&result)

	// Add prefix
	if len(pb.prefix) > 0 {
		styled_prefix := render(pb.text_style, pb.prefix)
		strings.write_string(&result, styled_prefix)
		strings.write_string(&result, " ")
	}

	// Calculate filled and empty portions
	percentage := progress_percentage(pb)
	filled_width := int(math.round((percentage / 100.0) * f64(pb.width)))
	empty_width := pb.width - filled_width

	// Render progress bar
	strings.write_string(&result, "[")

	// Build filled and empty portions first, then style them
	filled_part := strings.Builder{}
	defer strings.builder_destroy(&filled_part)

	empty_part := strings.Builder{}
	defer strings.builder_destroy(&empty_part)

	// Filled portion
	if filled_width > 0 {
		for i in 0..<filled_width {
			strings.write_rune(&filled_part, pb.filled_char)
		}
		filled_str := strings.to_string(filled_part)
		styled_filled := render(pb.filled_style, filled_str)
		strings.write_string(&result, styled_filled)
	}

	// Empty portion
	if empty_width > 0 {
		for i in 0..<empty_width {
			strings.write_rune(&empty_part, pb.empty_char)
		}
		empty_str := strings.to_string(empty_part)
		styled_empty := render(pb.empty_style, empty_str)
		strings.write_string(&result, styled_empty)
	}

	strings.write_string(&result, "]")

	// Add percentage if enabled
	if pb.show_percentage {
		percentage_str := fmt.aprintf(" %.1f%%", percentage)
		defer delete(percentage_str)
		styled_percentage := render(pb.text_style, percentage_str)
		strings.write_string(&result, styled_percentage)
	}

	// Add value if enabled
	if pb.show_value {
		value_str := fmt.aprintf(" (%.0f/%.0f)", pb.current, pb.total)
		defer delete(value_str)
		styled_value := render(pb.text_style, value_str)
		strings.write_string(&result, styled_value)
	}

	// Add suffix
	if len(pb.suffix) > 0 {
		strings.write_string(&result, " ")
		styled_suffix := render(pb.text_style, pb.suffix)
		strings.write_string(&result, styled_suffix)
	}

	return strings.clone(strings.to_string(result))
}

// Render progress bar with custom text
progress_render_with_text :: proc(pb: ProgressBar, text: string) -> string {
	bar_str := progress_render(pb)
	defer delete(bar_str)

	if len(text) > 0 {
		styled_text := render(pb.text_style, text)
		return fmt.aprintf("%s %s", bar_str, styled_text)
	}

	return strings.clone(bar_str)
}

// Show animated progress for a duration
progress_animate :: proc(pb: ^ProgressBar, steps: int, step_duration: time.Duration) {
	step_amount := pb.total / f64(steps)

	for i in 0..<steps {
		progress_set(pb, f64(i) * step_amount)

		// Clear line and render progress
		fmt.print("\r\033[K")
		fmt.print(progress_render(pb^))

		time.sleep(step_duration)
	}

	// Final complete state
	progress_set(pb, pb.total)
	fmt.print("\r\033[K")
	fmt.print(progress_render(pb^))
	fmt.println()
}

// Create a simple indeterminate progress bar
IndeterminateBar :: struct {
	width: int,
	position: int,
	direction: int, // 1 for right, -1 for left
	char: rune,
	style: Style,
	active: bool,
}

new_indeterminate_bar :: proc(width: int) -> IndeterminateBar {
	return IndeterminateBar{
		width = width,
		position = 0,
		direction = 1,
		char = '█',
		style = style_foreground(new_style(), "blue"),
		active = false,
	}
}

// Update indeterminate bar position
indeterminate_tick :: proc(bar: ^IndeterminateBar) {
	if !bar.active {
		return
	}

	bar.position += bar.direction

	if bar.position >= bar.width - 1 {
		bar.direction = -1
	} else if bar.position <= 0 {
		bar.direction = 1
	}
}

// Render indeterminate bar
indeterminate_render :: proc(bar: IndeterminateBar) -> string {
	result := strings.Builder{}
	defer strings.builder_destroy(&result)

	strings.write_string(&result, "[")

	for i in 0..<bar.width {
		if i == bar.position {
			char_builder := strings.Builder{}
			defer strings.builder_destroy(&char_builder)
			strings.write_rune(&char_builder, bar.char)
			char_str := strings.to_string(char_builder)
			styled_char := render(bar.style, char_str)
			strings.write_string(&result, styled_char)
		} else {
			strings.write_string(&result, " ")
		}
	}

	strings.write_string(&result, "]")

	return strings.clone(strings.to_string(result))
}

// Clean up progress bar memory
progress_destroy :: proc(pb: ^ProgressBar) {
	if len(pb.prefix) > 0 {
		delete(pb.prefix)
	}
	if len(pb.suffix) > 0 {
		delete(pb.suffix)
	}
}