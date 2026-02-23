package test_wayu

import "core:testing"
import "core:strings"
import wayu "../../src"

// ── Tests ────────────────────────────────────────────────────────────────────

@(test)
test_input_render_normal :: proc(t: ^testing.T) {
	// Short text — fits inside the box without truncation.
	input := wayu.new_input("placeholder", 20)
	wayu.input_set_value(&input, "hello")
	defer wayu.input_destroy(&input)

	rendered := wayu.input_render(&input)
	defer delete(rendered)

	lines := strings.split(rendered, "\r\n")
	defer delete(lines)

	testing.expect(t, len(lines) >= 3, "Rendered input must have 3 lines")

	top_border := lines[0]
	testing.expect(t, strings.has_prefix(top_border, "┌"), "Top border must start with ┌")
	testing.expect(t, strings.has_suffix(top_border, "┐"), "Top border must end with ┐")

	bottom_border := lines[2]
	testing.expect(t, strings.has_prefix(bottom_border, "└"), "Bottom border must start with └")
	testing.expect(t, strings.has_suffix(bottom_border, "┘"), "Bottom border must end with ┘")

	// Content line must end with " │"
	content_line := lines[1]
	testing.expect(t, strings.has_suffix(content_line, " │"), "Content line must end with ' │'")
}

@(test)
test_input_render_placeholder :: proc(t: ^testing.T) {
	// Empty value — placeholder must be shown, box must close correctly.
	input := wayu.new_input("type here", 20)
	defer wayu.input_destroy(&input)

	rendered := wayu.input_render(&input)
	defer delete(rendered)

	testing.expect(t, strings.contains(rendered, "type here"),
		"Placeholder text must appear in rendered output")

	lines := strings.split(rendered, "\r\n")
	defer delete(lines)
	testing.expect(t, len(lines) >= 3, "Rendered input must have 3 lines")

	content_line := lines[1]
	testing.expect(t, strings.has_suffix(content_line, " │"),
		"Content line must end with ' │' even with placeholder")
}

@(test)
test_input_render_overflow_unfocused :: proc(t: ^testing.T) {
	// Text longer than content_width (width - 4) must NOT produce negative
	// padding. The box must still close with " │".
	// width=10 → content_width=6. Text "hello world" (11 chars) overflows.
	input := wayu.new_input("", 10)
	wayu.input_set_value(&input, "hello world")
	defer wayu.input_destroy(&input)

	rendered := wayu.input_render(&input)
	defer delete(rendered)

	lines := strings.split(rendered, "\r\n")
	defer delete(lines)
	testing.expect(t, len(lines) >= 3, "Rendered input must have 3 lines")

	content_line := lines[1]
	testing.expect(t, strings.has_suffix(content_line, " │"),
		"Content line must end with ' │' even when text overflows")

	// Must contain truncation indicator.
	testing.expect(t, strings.contains(content_line, "..."),
		"Overflowed unfocused text must show '...' truncation")
}

@(test)
test_input_render_overflow_focused :: proc(t: ^testing.T) {
	// Focused input with text longer than content_width must still close the box.
	// width=10 → content_width=6. Text "hello world" (11 chars) overflows.
	input := wayu.new_input("", 10)
	input.focused = true
	wayu.input_set_value(&input, "hello world")
	defer wayu.input_destroy(&input)

	rendered := wayu.input_render(&input)
	defer delete(rendered)

	lines := strings.split(rendered, "\r\n")
	defer delete(lines)
	testing.expect(t, len(lines) >= 3, "Rendered input must have 3 lines")

	content_line := lines[1]
	testing.expect(t, strings.has_suffix(content_line, " │"),
		"Focused content line must end with ' │' even when text overflows")

	// Must contain truncation indicator.
	testing.expect(t, strings.contains(content_line, "..."),
		"Overflowed focused text must show '...' truncation")
}

@(test)
test_input_render_exact_fit :: proc(t: ^testing.T) {
	// Text exactly equal to content_width — no truncation, no negative padding.
	// width=10 → content_width=6. Text "hello!" (6 chars) fits exactly.
	input := wayu.new_input("", 10)
	wayu.input_set_value(&input, "hello!")
	defer wayu.input_destroy(&input)

	rendered := wayu.input_render(&input)
	defer delete(rendered)

	lines := strings.split(rendered, "\r\n")
	defer delete(lines)

	content_line := lines[1]
	testing.expect(t, strings.has_suffix(content_line, " │"),
		"Exact-fit content line must end with ' │'")
	testing.expect(t, !strings.contains(content_line, "..."),
		"Exact-fit text must not show truncation indicator")
}

@(test)
test_input_render_border_width_consistent :: proc(t: ^testing.T) {
	// Top and bottom borders must have the same byte length regardless of
	// text content (overflow or not).
	// Use a long literal string to trigger overflow without strings.repeat.
	input := wayu.new_input("placeholder", 20)
	wayu.input_set_value(&input, "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
	defer wayu.input_destroy(&input)

	rendered := wayu.input_render(&input)
	defer delete(rendered)

	lines := strings.split(rendered, "\r\n")
	defer delete(lines)
	testing.expect(t, len(lines) >= 3, "Must have 3 lines")

	top_len    := len(lines[0])
	bottom_len := len(lines[2])
	testing.expect_value(t, top_len, bottom_len)
}
