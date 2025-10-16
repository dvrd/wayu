package test_wayu

import "core:testing"
import "core:strings"
import tui "../../src/tui"

// Helper to count lines in output
count_lines :: proc(s: string) -> int {
	if len(s) == 0 do return 0
	count := 1
	for c in s {
		if c == '\n' do count += 1
	}
	return count
}

// Box component tests
@(test)
test_box_small :: proc(t: ^testing.T) {
	args := tui.ComponentArgs{width = 10, height = 3}
	output := tui.render_component(.BOX, args)
	defer delete(output)

	testing.expect(t, len(output) > 0, "Box output should not be empty")
	lines := count_lines(output)
	testing.expect_value(t, lines, 3)
}

@(test)
test_box_large :: proc(t: ^testing.T) {
	args := tui.ComponentArgs{width = 80, height = 24}
	output := tui.render_component(.BOX, args)
	defer delete(output)

	testing.expect(t, len(output) > 0, "Box output should not be empty")
	lines := count_lines(output)
	testing.expect_value(t, lines, 24)
}

// List item component tests
@(test)
test_list_item_unselected :: proc(t: ^testing.T) {
	args := tui.ComponentArgs{
		width = 40,
		height = 1,
		text = strings.clone("Sample item"),
		selected = false,
	}
	defer delete(args.text)

	output := tui.render_component(.LIST_ITEM, args)
	defer delete(output)

	testing.expect(t, len(output) > 0, "List item output should not be empty")
	testing.expect(t, strings.contains(output, "Sample item"), "Output should contain item text")
	testing.expect(t, strings.contains(output, "  "), "Unselected item should have two spaces prefix")
}

@(test)
test_list_item_selected :: proc(t: ^testing.T) {
	args := tui.ComponentArgs{
		width = 40,
		height = 1,
		text = strings.clone("Selected item"),
		selected = true,
	}
	defer delete(args.text)

	output := tui.render_component(.LIST_ITEM, args)
	defer delete(output)

	testing.expect(t, len(output) > 0, "List item output should not be empty")
	testing.expect(t, strings.contains(output, "Selected item"), "Output should contain item text")
	testing.expect(t, strings.contains(output, "> "), "Selected item should have '> ' prefix")
}

// Header component tests
@(test)
test_header_plain :: proc(t: ^testing.T) {
	args := tui.ComponentArgs{
		width = 60,
		height = 3,
		title = strings.clone("Test Header"),
		count = 0,
	}
	defer delete(args.title)

	output := tui.render_component(.HEADER, args)
	defer delete(output)

	testing.expect(t, len(output) > 0, "Header output should not be empty")
	testing.expect(t, strings.contains(output, "Test Header"), "Output should contain title")
}

@(test)
test_header_with_emoji_and_count :: proc(t: ^testing.T) {
	args := tui.ComponentArgs{
		width = 60,
		height = 3,
		title = strings.clone("Path Manager"),
		emoji = strings.clone("🚀"),
		count = 15,
	}
	defer delete(args.title)
	defer delete(args.emoji)

	output := tui.render_component(.HEADER, args)
	defer delete(output)

	testing.expect(t, len(output) > 0, "Header output should not be empty")
	testing.expect(t, strings.contains(output, "Path Manager"), "Output should contain title")
	testing.expect(t, strings.contains(output, "🚀"), "Output should contain emoji")
	testing.expect(t, strings.contains(output, "15 entries"), "Output should contain count")
}

// Footer component tests
@(test)
test_footer_simple :: proc(t: ^testing.T) {
	args := tui.ComponentArgs{
		width = 80,
		height = 3,
		shortcuts = strings.clone("q=quit • h=help"),
	}
	defer delete(args.shortcuts)

	output := tui.render_component(.FOOTER, args)
	defer delete(output)

	testing.expect(t, len(output) > 0, "Footer output should not be empty")
	testing.expect(t, strings.contains(output, "q=quit"), "Output should contain shortcuts")
}

@(test)
test_footer_complex :: proc(t: ^testing.T) {
	args := tui.ComponentArgs{
		width = 80,
		height = 3,
		shortcuts = strings.clone("j/k=nav • enter=select • q=quit • ?=help"),
	}
	defer delete(args.shortcuts)

	output := tui.render_component(.FOOTER, args)
	defer delete(output)

	testing.expect(t, len(output) > 0, "Footer output should not be empty")
	testing.expect(t, strings.contains(output, "j/k=nav"), "Output should contain navigation shortcuts")
}

// Scroll indicator component tests
@(test)
test_scroll_indicator_start :: proc(t: ^testing.T) {
	args := tui.ComponentArgs{
		width = 50,
		height = 1,
		start = 1,
		end = 10,
		total = 50,
	}

	output := tui.render_component(.SCROLL_INDICATOR, args)
	defer delete(output)

	testing.expect(t, len(output) > 0, "Scroll indicator output should not be empty")
	testing.expect(t, strings.contains(output, "Showing 1-10 of 50"), "Output should contain scroll info")
}

@(test)
test_scroll_indicator_middle :: proc(t: ^testing.T) {
	args := tui.ComponentArgs{
		width = 50,
		height = 1,
		start = 21,
		end = 30,
		total = 100,
	}

	output := tui.render_component(.SCROLL_INDICATOR, args)
	defer delete(output)

	testing.expect(t, len(output) > 0, "Scroll indicator output should not be empty")
	testing.expect(t, strings.contains(output, "Showing 21-30 of 100"), "Output should contain scroll info")
}

// Empty state component tests
@(test)
test_empty_state_short_message :: proc(t: ^testing.T) {
	args := tui.ComponentArgs{
		width = 60,
		height = 10,
		message = strings.clone("No items found"),
	}
	defer delete(args.message)

	output := tui.render_component(.EMPTY_STATE, args)
	defer delete(output)

	testing.expect(t, len(output) > 0, "Empty state output should not be empty")
	testing.expect(t, strings.contains(output, "No items found"), "Output should contain message")
}

@(test)
test_empty_state_long_message :: proc(t: ^testing.T) {
	args := tui.ComponentArgs{
		width = 80,
		height = 20,
		message = strings.clone("No configuration entries found. Add one to get started."),
	}
	defer delete(args.message)

	output := tui.render_component(.EMPTY_STATE, args)
	defer delete(output)

	testing.expect(t, len(output) > 0, "Empty state output should not be empty")
	testing.expect(t, strings.contains(output, "No configuration entries found"), "Output should contain message")
}

// Component args parsing tests
@(test)
test_parse_component_args_width_height :: proc(t: ^testing.T) {
	args := []string{"width=40", "height=10"}
	parsed := tui.parse_component_args(args)
	defer tui.component_args_destroy(&parsed)

	testing.expect_value(t, parsed.width, 40)
	testing.expect_value(t, parsed.height, 10)
}

@(test)
test_parse_component_args_text :: proc(t: ^testing.T) {
	args := []string{"text=Sample text", "selected=true"}
	parsed := tui.parse_component_args(args)
	defer tui.component_args_destroy(&parsed)

	testing.expect_value(t, parsed.text, "Sample text")
	testing.expect_value(t, parsed.selected, true)
}

@(test)
test_parse_component_args_count :: proc(t: ^testing.T) {
	args := []string{"count=42", "start=1", "end=10", "total=100"}
	parsed := tui.parse_component_args(args)
	defer tui.component_args_destroy(&parsed)

	testing.expect_value(t, parsed.count, 42)
	testing.expect_value(t, parsed.start, 1)
	testing.expect_value(t, parsed.end, 10)
	testing.expect_value(t, parsed.total, 100)
}

// Component type parsing tests
@(test)
test_parse_component_type_valid :: proc(t: ^testing.T) {
	box_type, ok := tui.parse_component_type("box")
	testing.expect_value(t, ok, true)
	testing.expect_value(t, box_type, tui.ComponentType.BOX)

	list_type, ok2 := tui.parse_component_type("list-item")
	testing.expect_value(t, ok2, true)
	testing.expect_value(t, list_type, tui.ComponentType.LIST_ITEM)

	header_type, ok3 := tui.parse_component_type("header")
	testing.expect_value(t, ok3, true)
	testing.expect_value(t, header_type, tui.ComponentType.HEADER)
}

@(test)
test_parse_component_type_invalid :: proc(t: ^testing.T) {
	_, ok := tui.parse_component_type("invalid")
	testing.expect_value(t, ok, false)

	_, ok2 := tui.parse_component_type("")
	testing.expect_value(t, ok2, false)
}
