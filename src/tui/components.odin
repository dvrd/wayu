// tui_components.odin - Component testing framework for TUI components
//
// This module provides headless rendering and testing for individual TUI components.
// Used by component_test.odin for CLI-based visual regression testing.

package wayu_tui

import "core:fmt"
import "core:strconv"
import "core:strings"

// Component types available for testing
ComponentType :: enum {
	BOX,
	LIST_ITEM,
	HEADER,
	FOOTER,
	SCROLL_INDICATOR,
	EMPTY_STATE,
}

// Arguments for component rendering
ComponentArgs :: struct {
	// Common args
	width:    int,
	height:   int,

	// Text content
	text:     string,
	title:    string,
	message:  string,

	// State
	selected: bool,

	// Numeric data
	count:    int,
	start:    int,  // For scroll indicator
	end:      int,
	total:    int,

	// Visual elements
	emoji:    string,
	shortcuts: string,  // Comma-separated "key=action" pairs
}

// Parse component type from string
parse_component_type :: proc(name: string) -> (ComponentType, bool) {
	switch name {
	case "box":
		return .BOX, true
	case "list-item", "list_item":
		return .LIST_ITEM, true
	case "header":
		return .HEADER, true
	case "footer":
		return .FOOTER, true
	case "scroll", "scroll-indicator", "scroll_indicator":
		return .SCROLL_INDICATOR, true
	case "empty", "empty-state", "empty_state":
		return .EMPTY_STATE, true
	case:
		return .BOX, false  // Default, but signal error
	}
}

// Parse component arguments from CLI
parse_component_args :: proc(args: []string) -> ComponentArgs {
	result := ComponentArgs{
		width = 80,   // Default terminal width
		height = 24,  // Default terminal height
		selected = false,
	}

	for arg in args {
		if !strings.contains(arg, "=") do continue

		parts := strings.split(arg, "=")
		defer delete(parts)

		if len(parts) != 2 do continue

		key := strings.trim_space(parts[0])
		value := strings.trim_space(parts[1])

		switch key {
		case "width":
			result.width, _ = strconv.parse_int(value)
		case "height":
			result.height, _ = strconv.parse_int(value)
		case "text":
			result.text = strings.clone(value)
		case "title":
			result.title = strings.clone(value)
		case "message":
			result.message = strings.clone(value)
		case "selected":
			result.selected = (value == "true" || value == "1")
		case "count":
			result.count, _ = strconv.parse_int(value)
		case "start":
			result.start, _ = strconv.parse_int(value)
		case "end":
			result.end, _ = strconv.parse_int(value)
		case "total":
			result.total, _ = strconv.parse_int(value)
		case "emoji":
			result.emoji = strings.clone(value)
		case "shortcuts":
			result.shortcuts = strings.clone(value)
		}
	}

	return result
}

// Free component args memory
component_args_destroy :: proc(args: ^ComponentArgs) {
	if args.text != "" do delete(args.text)
	if args.title != "" do delete(args.title)
	if args.message != "" do delete(args.message)
	if args.emoji != "" do delete(args.emoji)
	if args.shortcuts != "" do delete(args.shortcuts)
}

// Render component to plain text string (headless)
render_component :: proc(type: ComponentType, args: ComponentArgs) -> string {
	// Create headless screen buffer
	screen := screen_create(args.width, args.height)
	defer screen_destroy(&screen)

	// Clear to spaces
	screen_clear(&screen)

	// Render based on component type
	switch type {
	case .BOX:
		// Render box filling entire screen
		render_box(&screen, 0, 0, args.width, args.height)

	case .LIST_ITEM:
		// Render list item with selection indicator
		prefix: string
		if args.selected {
			prefix = "> "
		} else {
			prefix = "  "
		}
		text := fmt.tprintf("%s%s", prefix, args.text)
		// Note: tprintf() uses temp buffer, do NOT delete
		render_text(&screen, 0, 0, text)

	case .HEADER:
		// Render header with emoji and title
		header_line: string
		if args.emoji != "" {
			header_line = fmt.tprintf("%s %s", args.emoji, args.title)
		} else {
			header_line = args.title
		}
		// Note: tprintf() uses temp buffer, do NOT delete
		render_text(&screen, 2, 0, header_line)

		// Render count if provided
		if args.count > 0 {
			count_line := fmt.tprintf("%d entries", args.count)
			// Note: tprintf() uses temp buffer, do NOT delete
			render_text(&screen, 2, 1, count_line)
		}

	case .FOOTER:
		// Render footer at bottom
		render_text(&screen, 2, args.height - 1, args.shortcuts)

	case .SCROLL_INDICATOR:
		// Render scroll position
		scroll_text := fmt.tprintf("Showing %d-%d of %d",
			args.start, args.end, args.total)
		// Note: tprintf() uses temp buffer, do NOT delete
		render_text(&screen, 2, 0, scroll_text)

	case .EMPTY_STATE:
		// Center message vertically and horizontally
		y := args.height / 2
		x := (args.width - len(args.message)) / 2
		render_text(&screen, x, y, args.message)
	}

	// Convert to plain text
	output := screen_to_string(&screen)
	return output
}
