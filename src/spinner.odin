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
	owns_text: bool,  // text was cloned by spinner_text
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

// Frame tables live in static read-only memory. (A slice literal assigned
// inside new_spinner was backed by that proc's stack frame, so the returned
// Spinner pointed at dead stack memory.)
@(rodata, private="file")
SPINNER_FRAMES_DOTS := [?]string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}
@(rodata, private="file")
SPINNER_FRAMES_LINE := [?]string{"|", "/", "-", "\\"}
@(rodata, private="file")
SPINNER_FRAMES_ARROW := [?]string{"←", "↖", "↑", "↗", "→", "↘", "↓", "↙"}
@(rodata, private="file")
SPINNER_FRAMES_BOUNCE := [?]string{"⠁", "⠂", "⠄", "⠂"}
@(rodata, private="file")
SPINNER_FRAMES_ARC := [?]string{"◜", "◠", "◝", "◞", "◡", "◟"}
@(rodata, private="file")
SPINNER_FRAMES_CLOCK := [?]string{"🕐", "🕑", "🕒", "🕓", "🕔", "🕕", "🕖", "🕗", "🕘", "🕙", "🕚", "🕛"}

// Create a new spinner with predefined type
new_spinner :: proc(spinner_type: SpinnerType) -> Spinner {
	frames: []string
	speed := 100 * time.Millisecond

	switch spinner_type {
	case .Dots:
		frames = SPINNER_FRAMES_DOTS[:]
	case .Line:
		frames = SPINNER_FRAMES_LINE[:]
		speed = 150 * time.Millisecond
	case .Arrow:
		frames = SPINNER_FRAMES_ARROW[:]
	case .Bounce:
		frames = SPINNER_FRAMES_BOUNCE[:]
		speed = 200 * time.Millisecond
	case .Arc:
		frames = SPINNER_FRAMES_ARC[:]
		speed = 120 * time.Millisecond
	case .Clock:
		frames = SPINNER_FRAMES_CLOCK[:]
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

// Set spinner text (cloned; freed by spinner_stop/spinner_destroy, and any
// previous text is released here).
spinner_text :: proc(spinner: ^Spinner, text: string) -> ^Spinner {
	spinner_free_text(spinner)
	spinner.text = strings.clone(text)
	spinner.owns_text = true
	return spinner
}

@(private="file")
spinner_free_text :: proc(spinner: ^Spinner) {
	if spinner.owns_text && len(spinner.text) > 0 {
		delete(spinner.text)
	}
	spinner.text = ""
	spinner.owns_text = false
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

// Stop the spinner animation. Releases the text set by spinner_text —
// callers typically stop a spinner and drop it without spinner_destroy.
spinner_stop :: proc(spinner: ^Spinner) {
	spinner.active = false
	spinner_free_text(spinner)
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
		defer delete(styled_frame)
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
	defer delete(styled_frame)

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
				spinner_free_text(spinner)
				spinner.text = text_updates[text_index]
				text_index += 1
				last_update = time.now()
			}
		}

		// Clear line and render spinner
		fmt.print("\r\033[K") // Clear current line
		frame := spinner_render(spinner^)
		fmt.print(frame)
		delete(frame)

		time.sleep(spinner.speed)
		spinner_tick(spinner)
	}

	// Clear final spinner
	fmt.print("\r\033[K")
	spinner_stop(spinner)
}

// Simple loading animation with completion message
spinner_loading :: proc(spinner: ^Spinner, loading_text: string, completion_text: string, duration: time.Duration) {
	spinner_free_text(spinner)
	spinner.text = loading_text
	spinner_start(spinner)

	start_time := time.now()
	for time.since(start_time) < duration {
		fmt.print("\r\033[K") // Clear current line
		frame := spinner_render(spinner^)
		fmt.print(frame)
		delete(frame)

		time.sleep(spinner.speed)
		spinner_tick(spinner)
	}

	// Show completion
	fmt.print("\r\033[K")
	success_style := style_foreground(new_style(), "green")
	success_mark := render(success_style, "✓")
	defer delete(success_mark)
	fmt.printf("%s %s\n", success_mark, completion_text)

	spinner_stop(spinner)
}


// Clean up spinner memory (idempotent).
spinner_destroy :: proc(spinner: ^Spinner) {
	spinner_free_text(spinner)
}