package wayu

import "core:fmt"
import "core:time"
import "core:strings"

// Spinner component for loading states
Spinner :: struct {
	frames: []string,
	current_frame: int,
	style: Style,
	text: string,
	active: bool,
	speed: time.Duration, // Time between frame updates
}

// Predefined spinner types
SpinnerType :: enum {
	Dots,
	Line,
	Arrow,
	Bounce,
	Arc,
	Clock,
}

// Create a new spinner with predefined type
new_spinner :: proc(spinner_type: SpinnerType) -> Spinner {
	frames: []string
	speed := 100 * time.Millisecond

	switch spinner_type {
	case .Dots:
		frames = {"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}
	case .Line:
		frames = {"|", "/", "-", "\\"}
		speed = 150 * time.Millisecond
	case .Arrow:
		frames = {"←", "↖", "↑", "↗", "→", "↘", "↓", "↙"}
	case .Bounce:
		frames = {"⠁", "⠂", "⠄", "⠂"}
		speed = 200 * time.Millisecond
	case .Arc:
		frames = {"◜", "◠", "◝", "◞", "◡", "◟"}
		speed = 120 * time.Millisecond
	case .Clock:
		frames = {"🕐", "🕑", "🕒", "🕓", "🕔", "🕕", "🕖", "🕗", "🕘", "🕙", "🕚", "🕛"}
		speed = 200 * time.Millisecond
	}

	return Spinner{
		frames = frames,
		current_frame = 0,
		style = new_style(),
		text = "",
		active = false,
		speed = speed,
	}
}

// Create a custom spinner with specific frames
new_custom_spinner :: proc(frames: []string, speed: time.Duration) -> Spinner {
	return Spinner{
		frames = frames,
		current_frame = 0,
		style = new_style(),
		text = "",
		active = false,
		speed = speed,
	}
}

// Set spinner text
spinner_text :: proc(spinner: ^Spinner, text: string) -> ^Spinner {
	spinner.text = strings.clone(text)
	return spinner
}

// Style the spinner
spinner_style :: proc(spinner: ^Spinner, s: Style) -> ^Spinner {
	spinner.style = s
	return spinner
}

// Start the spinner animation
spinner_start :: proc(spinner: ^Spinner) {
	spinner.active = true
	spinner.current_frame = 0
}

// Stop the spinner animation
spinner_stop :: proc(spinner: ^Spinner) {
	spinner.active = false
}

// Update spinner to next frame
spinner_tick :: proc(spinner: ^Spinner) {
	if !spinner.active || len(spinner.frames) == 0 {
		return
	}

	spinner.current_frame = (spinner.current_frame + 1) % len(spinner.frames)
}

// Render current spinner frame
spinner_render :: proc(spinner: Spinner) -> string {
	if len(spinner.frames) == 0 {
		return ""
	}

	frame := spinner.frames[spinner.current_frame]
	styled_frame := render(spinner.style, frame)

	if len(spinner.text) > 0 {
		return fmt.aprintf("%s %s", styled_frame, spinner.text)
	}

	return styled_frame
}

// Render spinner with custom text for this frame only
spinner_render_with_text :: proc(spinner: Spinner, text: string) -> string {
	if len(spinner.frames) == 0 {
		return text
	}

	frame := spinner.frames[spinner.current_frame]
	styled_frame := render(spinner.style, frame)

	return fmt.aprintf("%s %s", styled_frame, text)
}

// Show spinner for a specific duration with text updates
spinner_show_for :: proc(spinner: ^Spinner, duration: time.Duration, text_updates: []string = {}) {
	if !spinner.active {
		spinner_start(spinner)
	}

	start_time := time.now()
	text_index := 0
	last_update := time.now()

	for time.since(start_time) < duration {
		// Update text if provided
		if len(text_updates) > 0 && text_index < len(text_updates) {
			update_interval := duration / time.Duration(len(text_updates))
			if time.since(last_update) >= update_interval {
				spinner.text = text_updates[text_index]
				text_index += 1
				last_update = time.now()
			}
		}

		// Clear line and render spinner
		fmt.print("\r\033[K") // Clear current line
		fmt.print(spinner_render(spinner^))

		time.sleep(spinner.speed)
		spinner_tick(spinner)
	}

	// Clear final spinner
	fmt.print("\r\033[K")
	spinner_stop(spinner)
}

// Simple loading animation with completion message
spinner_loading :: proc(spinner: ^Spinner, loading_text: string, completion_text: string, duration: time.Duration) {
	spinner.text = loading_text
	spinner_start(spinner)

	start_time := time.now()
	for time.since(start_time) < duration {
		fmt.print("\r\033[K") // Clear current line
		fmt.print(spinner_render(spinner^))

		time.sleep(spinner.speed)
		spinner_tick(spinner)
	}

	// Show completion
	fmt.print("\r\033[K")
	success_style := style_foreground(new_style(), "green")
	success_mark := render(success_style, "✓")
	fmt.printf("%s %s\n", success_mark, completion_text)

	spinner_stop(spinner)
}


// Clean up spinner memory
spinner_destroy :: proc(spinner: ^Spinner) {
	if len(spinner.text) > 0 {
		delete(spinner.text)
	}
}