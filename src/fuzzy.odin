package wayu

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/unix"
import "core:c/libc"
import "core:slice"

// Simple fuzzy finder implementation
// This provides basic fuzzy matching and interactive selection

// Terminal control for raw mode using system commands
enable_raw_mode :: proc() {
	// Use stty to set terminal to raw mode and disable echo
	libc.system("stty raw -echo")
}

disable_raw_mode :: proc() {
	// Restore normal terminal settings
	libc.system("stty cooked echo")
}
// For production use, you might want to integrate with external tools like fzf

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
	copy(final_results, results[:])
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
	enable_raw_mode()

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
	config_file := fmt.aprintf("%s/%s", WAYU_CONFIG, PATH_FILE)
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
					append(&items, strings.clone(path))
				}
			}
		}
	}

	result := make([]string, len(items))
	copy(result, items[:])
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
				append(&items, strings.clone(name))
			}
		}
	}

	result := make([]string, len(items))
	copy(result, items[:])
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
	defer {
		for item in items {
			delete(item)
		}
		delete(items)
	}

	for line in lines {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "export ") && strings.contains(trimmed, "=") {
			eq_pos := strings.index(trimmed, "=")
			if eq_pos != -1 {
				name := trimmed[7:eq_pos] // Skip "export "
				append(&items, strings.clone(name))
				debug("Found constant: %s", name)
			}
		}
	}
	debug("Found %d constants total", len(items))

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

	// Filter completion files (start with _)
	for info in file_infos {
		if strings.has_prefix(info.name, "_") && !info.is_dir {
			// Remove underscore for display
			name := info.name[1:]
			append(&items, strings.clone(name))
		}
	}

	result := make([]string, len(items))
	for item, i in items {
		result[i] = strings.clone(item)
	}
	return result
}