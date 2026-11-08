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


// Clean up spinner memory (idempotent).
spinner_destroy :: proc(spinner: ^Spinner) {
	spinner_free_text(spinner)
}