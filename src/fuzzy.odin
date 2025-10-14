package wayu

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/unix"
import "core:c/libc"
import "core:slice"
import "core:c"

// Enhanced fuzzy finder implementation with rich metadata, details panels, and actions
// This provides interactive fuzzy matching with real-time filtering, details, and keyboard actions

// ============================================================================
// Terminal State Management with termios
// ============================================================================

foreign import libc_term "system:c"

STDIN_FILENO :: 0
TCSANOW :: 0

// ICANON and ECHO flags for terminal modes
ICANON :: 0x00000100  // Canonical input (line buffering)
ECHO   :: 0x00000008  // Echo input characters

termios :: struct {
	c_iflag:  c.uint,
	c_oflag:  c.uint,
	c_cflag:  c.uint,
	c_lflag:  c.uint,
	c_line:   c.uchar,
	c_cc:     [32]c.uchar,
	c_ispeed: c.uint,
	c_ospeed: c.uint,
}

foreign libc_term {
	tcgetattr :: proc(fd: c.int, termios_p: ^termios) -> c.int ---
	tcsetattr :: proc(fd: c.int, optional_actions: c.int, termios_p: ^termios) -> c.int ---
}

// Global variable to save terminal state
saved_termios: termios

// Enable raw mode with proper terminal state saving
// Returns false if terminal control failed
enable_raw_mode :: proc() -> bool {
	// Save current terminal state
	if tcgetattr(STDIN_FILENO, &saved_termios) != 0 {
		debug("Failed to get terminal attributes")
		return false
	}

	// Create raw mode settings
	raw := saved_termios
	raw.c_lflag &= ~(c.uint(ECHO) | c.uint(ICANON))

	// Apply raw mode
	if tcsetattr(STDIN_FILENO, TCSANOW, &raw) != 0 {
		debug("Failed to set terminal to raw mode")
		return false
	}

	debug("Terminal set to raw mode")
	return true
}

// Restore terminal to saved state
disable_raw_mode :: proc() {
	tcsetattr(STDIN_FILENO, TCSANOW, &saved_termios)
	debug("Terminal restored to original state")
}

// ============================================================================
// Enhanced Fuzzy Finder Structures
// ============================================================================

// FuzzyItem represents a single item in the fuzzy finder with rich metadata
FuzzyItem :: struct {
	display:  string,                  // What the user sees
	value:    string,                  // Underlying value
	metadata: map[string]string,       // Additional data
	icon:     string,                  // Emoji or symbol
	color:    string,                  // Color override
}

// FuzzyAction represents a keyboard action that can be performed on an item
FuzzyAction :: struct {
	name:        string,
	key_name:    string,               // Display name (e.g., "Del", "Ctrl+U")
	key_code:    u8,                   // Key code to match
	handler:     proc(^FuzzyItem) -> bool,  // Returns true to refresh list
	description: string,               // Help text
}

// FuzzyView is the main structure for the enhanced fuzzy finder
FuzzyView :: struct {
	// Data
	items:          []FuzzyItem,
	filtered_items: [dynamic]FuzzyItem,

	// State
	filter_query:   [dynamic]u8,
	selected_index: int,
	scroll_offset:  int,

	// UI config
	title:          string,
	show_details:   bool,
	details_fn:     proc(^FuzzyItem) -> string,
	actions:        []FuzzyAction,

	// Layout
	visible_items:  int,               // How many items shown at once
	details_height: int,               // Height of details panel
}

// Legacy structure for backward compatibility
FuzzyResult :: struct {
	text:  string,
	score: int,
}

fuzzy_find :: proc(items: []string, query: string) -> []FuzzyResult {
	if len(query) == 0 {
		results := make([]FuzzyResult, len(items))
		for item, i in items {
			results[i] = {text = item, score = 0}
		}
		return results
	}

	results := make([dynamic]FuzzyResult)
	query_lower := strings.to_lower(query)
	defer delete(query_lower)

	for item in items {
		item_lower := strings.to_lower(item)
		score := calculate_fuzzy_score(item_lower, query_lower)
		delete(item_lower) // Clean up immediately after use

		if score > 0 {
			append(&results, FuzzyResult{text = item, score = score})
		}
	}

	// Sort by score (higher is better)
	slice.sort_by(results[:], proc(a, b: FuzzyResult) -> bool {
		return a.score > b.score
	})

	final_results := make([]FuzzyResult, len(results))
	for i in 0..<len(results) {
		final_results[i] = results[i]
	}
	delete(results) // Clean up the dynamic array
	return final_results
}

calculate_fuzzy_score :: proc(text: string, query: string) -> int {
	if len(query) == 0 do return 1
	if len(text) == 0 do return 0

	score := 0
	text_idx := 0

	for query_char in query {
		found := false
		for text_idx < len(text) {
			if rune(text[text_idx]) == query_char {
				score += 1
				text_idx += 1
				found = true
				break
			}
			text_idx += 1
		}
		if !found do return 0
	}

	// Bonus for exact matches
	if strings.contains(text, query) {
		score += len(query) * 2
	}

	// Bonus for matches at the beginning
	if strings.has_prefix(text, query) {
		score += len(query) * 3
	}

	return score
}

// ============================================================================
// Enhanced Fuzzy Finder Implementation
// ============================================================================

// Create a new enhanced fuzzy view
new_fuzzy_view :: proc(
	title: string,
	items: []FuzzyItem,
	details_fn: proc(^FuzzyItem) -> string = nil,
	actions: []FuzzyAction = {},
) -> FuzzyView {
	view := FuzzyView{
		items = items,
		filtered_items = make([dynamic]FuzzyItem),
		filter_query = make([dynamic]u8),
		selected_index = 0,
		scroll_offset = 0,
		title = title,
		show_details = details_fn != nil,
		details_fn = details_fn,
		actions = actions,
		visible_items = 10,
		details_height = 12,
	}

	// Initialize with all items
	for item in items {
		append(&view.filtered_items, item)
	}

	return view
}

// Update filter and rebuild filtered items list
fuzzy_update_filter :: proc(view: ^FuzzyView) {
	clear(&view.filtered_items)

	filter_str := string(view.filter_query[:])
	filter_lower := strings.to_lower(filter_str)
	defer delete(filter_lower)

	for item in view.items {
		if len(filter_str) == 0 {
			// No filter - show all
			append(&view.filtered_items, item)
		} else {
			// Check if display text matches filter
			display_lower := strings.to_lower(item.display)
			defer delete(display_lower)

			if strings.contains(display_lower, filter_lower) {
				append(&view.filtered_items, item)
			}
		}
	}

	// Ensure selected index is valid
	if view.selected_index >= len(view.filtered_items) {
		view.selected_index = max(0, len(view.filtered_items) - 1)
	}
}

// Update scroll offset to keep selected item visible
fuzzy_update_scroll :: proc(view: ^FuzzyView) {
	// Ensure selected item is in view
	if view.selected_index < view.scroll_offset {
		view.scroll_offset = view.selected_index
	} else if view.selected_index >= view.scroll_offset + view.visible_items {
		view.scroll_offset = view.selected_index - view.visible_items + 1
	}
}

// Render title box with fixed width
fuzzy_render_title :: proc(title: string) -> string {
	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	width :: 60

	// Top border
	fmt.sbprintf(&builder, "%s╭%s╮%s\r\n",
		get_primary(),
		strings.repeat("─", width),
		RESET)

	// Title line with padding - use visible_width for emojis
	title_len := visible_width(title)
	padding := (width - title_len) / 2
	remaining := width - title_len - padding

	fmt.sbprintf(&builder, "%s│%s%s%s%s%s%s│%s\r\n",
		get_primary(),
		strings.repeat(" ", padding),
		BOLD,
		title,
		RESET,
		strings.repeat(" ", remaining),
		get_primary(),
		RESET)

	// Bottom border
	fmt.sbprintf(&builder, "%s╰%s╯%s",
		get_primary(),
		strings.repeat("─", width),
		RESET)

	return strings.clone(strings.to_string(builder))
}

// Render filter input with cursor
fuzzy_render_filter :: proc(filter: []u8) -> string {
	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	// Filter prompt
	fmt.sbprintf(&builder, "\r\n%sFilter:%s ", get_secondary(), RESET)
	fmt.sbprintf(&builder, "%s", string(filter))
	fmt.sbprintf(&builder, "%s█%s", get_primary(), RESET)  // Cursor

	return strings.clone(strings.to_string(builder))
}

// Render keyboard shortcuts hint
fuzzy_render_shortcuts :: proc(actions: []FuzzyAction) -> string {
	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	fmt.sbprintf(&builder, "%s  ", get_muted())
	fmt.sbprintf(&builder, "Arrows: Navigate  •  Enter: Select  •  Esc: Quit")

	// Add action shortcuts
	for action in actions {
		fmt.sbprintf(&builder, "  •  %s: %s", action.key_name, action.description)
	}

	fmt.sbprintf(&builder, "%s\r\n", RESET)

	return strings.clone(strings.to_string(builder))
}

// Render items list
fuzzy_render_items :: proc(view: ^FuzzyView) -> string {
	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	// Calculate visible range
	visible_start := view.scroll_offset
	visible_end := min(len(view.filtered_items), visible_start + view.visible_items)

	// Border top
	fmt.sbprintf(&builder, "\r\n%s┌%s┐%s\r\n",
		get_muted(),
		strings.repeat("─", 60),
		RESET)

	// Items
	if len(view.filtered_items) == 0 {
		fmt.sbprintf(&builder, "%s│ No matches found%s│%s\r\n",
			get_muted(),
			strings.repeat(" ", 45),
			RESET)
	} else {
		for i in visible_start..<visible_end {
			item := view.filtered_items[i]

			if i == view.selected_index {
				// Highlighted selection
				icon_part := ""
				if item.icon != "" {
					icon_part = fmt.tprintf("%s ", item.icon)
				}
				content := fmt.tprintf("▸ %s%s", icon_part, item.display)
				fmt.sbprintf(&builder, "%s%s│ %s%s ",
					get_primary(), BOLD,
					content,
					RESET)

				// Padding to align border - use visible_width
				// Total line: │ + space + content + space + padding + │ = 62 chars
				// Internal: space(1) + content + space(1) + padding = 60 chars
				// Therefore: content + padding = 58
				content_len := visible_width(content) + 1 // content + 1 space after
				padding := max(0, 59 - content_len)  // 59 - (content+1) = 58 - content
				fmt.sbprintf(&builder, "%s", strings.repeat(" ", padding))
				fmt.sbprintf(&builder, "%s│%s\r\n", get_primary(), RESET)
			} else {
				// Regular item
				color := item.color != "" ? item.color : RESET
				icon_part := ""
				if item.icon != "" {
					icon_part = fmt.tprintf("%s ", item.icon)
				}
				content := fmt.tprintf("  %s%s", icon_part, item.display)
				fmt.sbprintf(&builder, "%s│ %s%s ",
					get_muted(),
					content,
					RESET)

				// Padding - use visible_width
				content_len := visible_width(content) + 1 // content + 1 space after
				padding := max(0, 59 - content_len)  // Same calculation as selected items
				fmt.sbprintf(&builder, "%s", strings.repeat(" ", padding))
				fmt.sbprintf(&builder, "%s│%s\r\n", get_muted(), RESET)
			}
		}
	}

	// Border bottom
	fmt.sbprintf(&builder, "%s└%s┘%s\r\n",
		get_muted(),
		strings.repeat("─", 60),
		RESET)

	return strings.clone(strings.to_string(builder))
}

// Render details panel with fixed width
fuzzy_render_details :: proc(view: ^FuzzyView) -> string {
	if !view.show_details || view.details_fn == nil {
		return ""
	}

	if len(view.filtered_items) == 0 || view.selected_index >= len(view.filtered_items) {
		return ""
	}

	item := &view.filtered_items[view.selected_index]
	details_content := view.details_fn(item)
	defer delete(details_content)

	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	width :: 60

	// Top border with title
	fmt.sbprintf(&builder, "%s╭─ Details %s╮%s\r\n",
		get_secondary(),
		strings.repeat("─", width - 10),
		RESET)

	// Split content into lines and render each
	lines := strings.split(details_content, "\n")
	defer delete(lines)

	for line in lines {
		// Strip ANSI codes for width calculation
		clean_line := line
		line_width := visible_width(clean_line)

		// Left border
		fmt.sbprintf(&builder, "%s│%s ", get_secondary(), RESET)

		// Content
		fmt.sbprintf(&builder, "%s", line)

		// Padding: │ + space(1) + line + padding + │ = 62 chars total
		// Internal: space(1) + line + padding = 60 chars
		// Therefore: line + padding = 59
		padding := max(0, 59 - line_width)
		fmt.sbprintf(&builder, "%s", strings.repeat(" ", padding))

		// Right border
		fmt.sbprintf(&builder, "%s│%s\r\n", get_secondary(), RESET)
	}

	// Bottom border
	fmt.sbprintf(&builder, "%s╰%s╯%s",
		get_secondary(),
		strings.repeat("─", width),
		RESET)

	return strings.clone(strings.to_string(builder))
}

// Main render function
fuzzy_render :: proc(view: ^FuzzyView) -> string {
	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	// Title
	title := fuzzy_render_title(view.title)
	defer delete(title)
	fmt.sbprintf(&builder, "%s\r\n", title)

	// Filter input
	filter := fuzzy_render_filter(view.filter_query[:])
	defer delete(filter)
	fmt.sbprintf(&builder, "%s\r\n", filter)

	// Keyboard shortcuts
	shortcuts := fuzzy_render_shortcuts(view.actions)
	defer delete(shortcuts)
	fmt.sbprintf(&builder, "%s", shortcuts)

	// Items list
	items := fuzzy_render_items(view)
	defer delete(items)
	fmt.sbprintf(&builder, "%s", items)

	// Details panel
	if view.show_details {
		details := fuzzy_render_details(view)
		if len(details) > 0 {
			defer delete(details)
			fmt.sbprintf(&builder, "\r\n%s", details)
		}
	}

	return strings.clone(strings.to_string(builder))
}

// Handle keyboard input
fuzzy_handle_key :: proc(view: ^FuzzyView, ch: u8, n: int, input_buf: []byte) -> (continue_loop: bool, has_result: bool) {
	// Control sequences
	if ch == 3 { // Ctrl+C
		return false, false
	} else if ch == 27 { // Esc
		return false, false
	} else if ch == 13 || ch == 10 { // Enter
		if len(view.filtered_items) > 0 && view.selected_index < len(view.filtered_items) {
			return false, true
		}
	} else if ch == 14 { // Ctrl+N - Move down
		if len(view.filtered_items) > 0 {
			view.selected_index = (view.selected_index + 1) % len(view.filtered_items)
			fuzzy_update_scroll(view)
		}
	} else if ch == 16 { // Ctrl+P - Move up
		if len(view.filtered_items) > 0 {
			view.selected_index = (view.selected_index - 1 + len(view.filtered_items)) % len(view.filtered_items)
			fuzzy_update_scroll(view)
		}
	} else if ch == 127 || ch == 8 { // Backspace/Delete
		if len(view.filter_query) > 0 {
			ordered_remove(&view.filter_query, len(view.filter_query) - 1)
			fuzzy_update_filter(view)
			view.selected_index = 0
			view.scroll_offset = 0
		}
	} else if ch >= 32 && ch <= 126 { // Printable characters
		append(&view.filter_query, ch)
		fuzzy_update_filter(view)
		view.selected_index = 0
		view.scroll_offset = 0
	} else if ch == 27 && n >= 3 { // ESC sequence (arrow keys)
		if input_buf[1] == '[' {
			switch input_buf[2] {
			case 'A': // Up arrow
				if len(view.filtered_items) > 0 {
					view.selected_index = (view.selected_index - 1 + len(view.filtered_items)) % len(view.filtered_items)
					fuzzy_update_scroll(view)
				}
			case 'B': // Down arrow
				if len(view.filtered_items) > 0 {
					view.selected_index = (view.selected_index + 1) % len(view.filtered_items)
					fuzzy_update_scroll(view)
				}
			}
		}
	} else {
		// Check for custom actions
		for action in view.actions {
			if ch == action.key_code {
				if len(view.filtered_items) > 0 && view.selected_index < len(view.filtered_items) {
					item := &view.filtered_items[view.selected_index]

					// Exit raw mode and show cursor for action handler
					// This allows the handler to prompt the user
					CLEAR_SCREEN :: "\033[2J\033[H"
					SHOW_CURSOR :: "\033[?25h"
					HIDE_CURSOR :: "\033[?25l"

					fmt.print(CLEAR_SCREEN)
					fmt.print(SHOW_CURSOR)
					disable_raw_mode()

					// Execute handler
					refresh := action.handler(item)

					// Re-enter raw mode and hide cursor
					if !enable_raw_mode() {
						// If we can't re-enter raw mode, exit gracefully
						return false, false
					}
					fmt.print(HIDE_CURSOR)

					if refresh {
						// Rebuild filter after action
						fuzzy_update_filter(view)
					}
				}
			}
		}
	}

	return true, false
}

// Main loop for enhanced fuzzy finder
fuzzy_run :: proc(view: ^FuzzyView) -> (selected: FuzzyItem, ok: bool) {
	// Terminal control sequences
	CLEAR_SCREEN :: "\033[2J\033[H"
	HIDE_CURSOR :: "\033[?25l"
	SHOW_CURSOR :: "\033[?25h"

	debug("Starting enhanced fuzzy finder with %d items", len(view.items))

	// Enter raw mode
	if !enable_raw_mode() {
		fmt.eprintln("Error: Failed to enable raw mode")
		return FuzzyItem{}, false
	}
	fmt.print(HIDE_CURSOR)

	// Make sure terminal is always restored
	defer {
		fmt.print(CLEAR_SCREEN)
		fmt.print(SHOW_CURSOR)
		disable_raw_mode()
	}

	// Main input loop
	for {
		// Render UI
		fmt.print(CLEAR_SCREEN)
		rendered := fuzzy_render(view)
		defer delete(rendered)
		fmt.print(rendered)

		// Read input
		input_buf: [8]byte
		n, err := os.read(os.stdin, input_buf[:])
		if err != 0 {
			debug("Error reading input: %d", err)
			break
		}

		if n == 0 { continue }

		ch := input_buf[0]

		// Handle key
		continue_loop, has_result := fuzzy_handle_key(view, ch, n, input_buf[:])

		if !continue_loop {
			if has_result && len(view.filtered_items) > 0 && view.selected_index < len(view.filtered_items) {
				result := view.filtered_items[view.selected_index]
				debug("Selected: %s", result.value)
				return result, true
			}
			return FuzzyItem{}, false
		}
	}

	return FuzzyItem{}, false
}

// Cleanup function for FuzzyView
fuzzy_view_destroy :: proc(view: ^FuzzyView) {
	delete(view.filtered_items)
	delete(view.filter_query)
	// Note: items, actions are owned by caller
}

// ============================================================================
// Backward Compatible Legacy Functions
// ============================================================================

// Interactive fuzzy select with real-time filtering and keyboard navigation
interactive_select :: proc(items: []string, prompt: string) -> (selected: string, ok: bool) {
	if len(items) == 0 {
		print_warning("No items to select from")
		return strings.clone(""), false
	}

	debug("Starting interactive fuzzy select with %d items", len(items))

	// Terminal control sequences
	CLEAR_SCREEN :: "\033[2J\033[H"
	CLEAR_LINE :: "\033[2K"
	MOVE_UP :: "\033[A"
	SAVE_CURSOR :: "\033[s"
	RESTORE_CURSOR :: "\033[u"
	HIDE_CURSOR :: "\033[?25l"
	SHOW_CURSOR :: "\033[?25h"

	// State variables
	filter_text: [dynamic]u8
	defer delete(filter_text)

	filtered_items: [dynamic]string
	defer delete(filtered_items)

	selected_index := 0

	// Initial filter (show all items)
	update_filter :: proc(items: []string, filter: []u8, filtered: ^[dynamic]string) {
		clear(filtered)
		filter_str := string(filter)

		for item in items {
			if len(filter) == 0 || strings.contains(strings.to_lower(item), strings.to_lower(filter_str)) {
				append(filtered, item)
			}
		}
		debug("Filter '%s' matches %d items", filter_str, len(filtered))
	}

	render_ui :: proc(prompt: string, filter: []u8, filtered: []string, selected_idx: int) {
		// Clear screen and move to top
		fmt.print(CLEAR_SCREEN)

		// Show prompt
		print_prompt(prompt)
		fmt.printf(" %s\r\n", string(filter))
		fmt.print("\r\n")

		// Show filtered items with selection highlight
		visible_start := max(0, selected_idx - 10) // Show 20 items max, centered on selection
		visible_end := min(len(filtered), visible_start + 20)

		for i in visible_start..<visible_end {
			if i == selected_idx {
				// Highlight selected item
				fmt.printf("  %s%s> %s%s\r\n", BRIGHT_YELLOW, BOLD, filtered[i], RESET)
			} else {
				fmt.printf("    %s\r\n", filtered[i]) // White text (no color codes)
			}
		}

		if len(filtered) == 0 {
			fmt.printf("  No matches found\r\n")
		}

		fmt.printf("\r\nType to filter, Ctrl+N/P to navigate, Ctrl+Y to select, Ctrl+C to quit\r\n")
	}

	// Initialize
	update_filter(items, filter_text[:], &filtered_items)

	// Enter raw mode (disable line buffering and echo)
	if !enable_raw_mode() {
		fmt.eprintln("Error: Failed to enable raw mode")
		return strings.clone(""), false
	}

	fmt.print(HIDE_CURSOR)

	// Make sure terminal is always restored
	defer {
		fmt.print(CLEAR_SCREEN)
		fmt.print(SHOW_CURSOR)
		disable_raw_mode()
	}

	// Initial render
	render_ui(prompt, filter_text[:], filtered_items[:], selected_index)

	// Main input loop
	for {
		input_buf: [8]byte // Buffer for reading key sequences
		n, err := os.read(os.stdin, input_buf[:])
		if err != 0 {
			debug("Error reading input: %d", err)
			break
		}

		if n == 0 { continue }

		ch := input_buf[0]

		// Handle control sequences
		if ch == 3 { // Ctrl+C
			// Clear screen and show cursor before exiting
			fmt.print(CLEAR_SCREEN)
			return strings.clone(""), false
		} else if ch == 25 { // Ctrl+Y - Select
			debug("User pressed Ctrl+Y - selecting item")
			if len(filtered_items) > 0 && selected_index < len(filtered_items) {
				result := strings.clone(filtered_items[selected_index])
				debug("Selected: %s", result)
				return result, true
			}
		} else if ch == 14 { // Ctrl+N - Move down
			debug("User pressed Ctrl+N - move down")
			if len(filtered_items) > 0 {
				selected_index = (selected_index + 1) % len(filtered_items)
			}
			render_ui(prompt, filter_text[:], filtered_items[:], selected_index)
		} else if ch == 16 { // Ctrl+P - Move up
			debug("User pressed Ctrl+P - move up")
			if len(filtered_items) > 0 {
				selected_index = (selected_index - 1 + len(filtered_items)) % len(filtered_items)
			}
			render_ui(prompt, filter_text[:], filtered_items[:], selected_index)
		} else if ch == 127 || ch == 8 { // Backspace/Delete
			debug("User pressed backspace")
			if len(filter_text) > 0 {
				ordered_remove(&filter_text, len(filter_text) - 1)
				update_filter(items, filter_text[:], &filtered_items)
				selected_index = 0 // Reset selection to top
				render_ui(prompt, filter_text[:], filtered_items[:], selected_index)
			}
		} else if ch >= 32 && ch <= 126 { // Printable characters
			debug("User typed character: %c", ch)
			append(&filter_text, ch)
			update_filter(items, filter_text[:], &filtered_items)
			selected_index = 0 // Reset selection to top
			render_ui(prompt, filter_text[:], filtered_items[:], selected_index)
		} else if ch == 13 || ch == 10 { // Enter key
			debug("User pressed Enter - selecting item")
			if len(filtered_items) > 0 && selected_index < len(filtered_items) {
				result := strings.clone(filtered_items[selected_index])
				debug("Selected: %s", result)
				return result, true
			}
		}

		// Handle escape sequences (arrow keys, etc.)
		if ch == 27 && n >= 3 { // ESC sequence
			if input_buf[1] == '[' {
				switch input_buf[2] {
				case 'A': // Up arrow
					debug("User pressed up arrow")
					if len(filtered_items) > 0 {
						selected_index = (selected_index - 1 + len(filtered_items)) % len(filtered_items)
					}
					render_ui(prompt, filter_text[:], filtered_items[:], selected_index)
				case 'B': // Down arrow
					debug("User pressed down arrow")
					if len(filtered_items) > 0 {
						selected_index = (selected_index + 1) % len(filtered_items)
					}
					render_ui(prompt, filter_text[:], filtered_items[:], selected_index)
				}
			}
		}
	}

	return strings.clone(""), false
}

// Interactive fuzzy finder with real-time filtering
// This is a simplified version - for better UX, consider using external tools like fzf
interactive_fuzzy_select :: proc(items: []string, prompt: string) -> (selected: string, ok: bool) {
	if len(items) == 0 {
		fmt.println("No items to select from")
		return strings.clone(""), false
	}

	// For now, just use simple interactive select
	// TODO: Implement real-time fuzzy filtering with terminal input handling
	return interactive_select(items, prompt)
}

// Extract items from configuration files for interactive removal
extract_path_items :: proc() -> []string {
	// Use shell-aware config file with fallback for backward compatibility
	config_file := get_config_file_with_fallback("path", DETECTED_SHELL)
	defer delete(config_file)

	content, read_ok := os.read_entire_file_from_filename(config_file)
	if !read_ok {
		return {}
	}
	defer delete(content)

	content_str := string(content)
	lines := strings.split(content_str, "\n")
	defer delete(lines)

	items := make([dynamic]string)
	defer delete(items)

	for line in lines {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "add_to_path") {
			// Extract path from add_to_path "path"
			start := strings.index(trimmed, "\"")
			if start != -1 {
				end := strings.last_index(trimmed, "\"")
				if end != -1 && end > start {
					path := trimmed[start + 1:end]
					// Store reference, clone later
					append(&items, path)
				}
			}
		}
	}

	// Clone once when creating result
	result := make([]string, len(items))
	for i in 0..<len(items) {
		result[i] = strings.clone(items[i])
	}
	return result
}

extract_alias_items :: proc() -> []string {
	config_file := fmt.aprintf("%s/%s", WAYU_CONFIG, ALIAS_FILE)
	defer delete(config_file)

	content, read_ok := os.read_entire_file_from_filename(config_file)
	if !read_ok {
		return {}
	}
	defer delete(content)

	content_str := string(content)
	lines := strings.split(content_str, "\n")
	defer delete(lines)

	items := make([dynamic]string)
	defer delete(items)

	for line in lines {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "alias ") && strings.contains(trimmed, "=") {
			eq_pos := strings.index(trimmed, "=")
			if eq_pos != -1 {
				name := trimmed[6:eq_pos] // Skip "alias "
				// Store reference, clone later
				append(&items, name)
			}
		}
	}

	// Clone once when creating result
	result := make([]string, len(items))
	for i in 0..<len(items) {
		result[i] = strings.clone(items[i])
	}
	return result
}

extract_constant_items :: proc() -> []string {
	debug("Extracting constant items...")
	config_file := fmt.aprintf("%s/%s", WAYU_CONFIG, CONSTANTS_FILE)
	defer delete(config_file)

	content, read_ok := os.read_entire_file_from_filename(config_file)
	if !read_ok {
		debug("Failed to read constants file")
		return {}
	}
	defer delete(content)
	debug("Read constants file: %d bytes", len(content))

	content_str := string(content)
	lines := strings.split(content_str, "\n")
	defer delete(lines)
	debug("Split into %d lines", len(lines))

	items := make([dynamic]string)
	defer delete(items)

	for line in lines {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "export ") && strings.contains(trimmed, "=") {
			eq_pos := strings.index(trimmed, "=")
			if eq_pos != -1 {
				name := trimmed[7:eq_pos] // Skip "export "
				// Store reference, clone later
				append(&items, name)
				debug("Found constant: %s", name)
			}
		}
	}
	debug("Found %d constants total", len(items))

	// Clone once when creating result
	result := make([]string, len(items))
	for item, i in items {
		result[i] = strings.clone(item)
	}
	debug("Created result array with %d items", len(result))
	return result
}

// Extract completion items from completions directory
extract_completion_items :: proc() -> []string {
	completions_dir := fmt.aprintf("%s/completions", WAYU_CONFIG)
	defer delete(completions_dir)

	// Check directory exists
	if !os.exists(completions_dir) {
		return {}
	}

	// Read directory
	dir_handle, err := os.open(completions_dir)
	if err != 0 {
		return {}
	}
	defer os.close(dir_handle)

	file_infos, read_err := os.read_dir(dir_handle, -1)
	if read_err != 0 {
		return {}
	}
	defer os.file_info_slice_delete(file_infos)

	items := make([dynamic]string)
	defer delete(items)

	// Filter completion files (start with _) but exclude backup files
	for info in file_infos {
		if strings.has_prefix(info.name, "_") && !info.is_dir {
			// Skip backup files
			if strings.contains(info.name, ".backup.") {
				continue
			}
			// Remove underscore for display - no need to clone yet
			name := info.name[1:]
			append(&items, name)
		}
	}

	// Clone once when creating result
	result := make([]string, len(items))
	for item, i in items {
		result[i] = strings.clone(item)
	}
	return result
}