// fuzzy.odin - Fuzzy matching and interactive terminal selection for wayu
//
// Provides:
//   1. Terminal raw mode management (enable_raw_mode, disable_raw_mode, is_tty)
//   2. calculate_fuzzy_score — subsequence-aware scoring used by search/suggestion
//   3. interactive_select / interactive_fuzzy_select — CLI interactive picker
//   4. extract_completion_items — reads completions directory
//
// The full-screen FuzzyView-based interactive finder was removed as dead code
// (only entry point was list_config_interactive which had zero callers).

package wayu

import "core:fmt"
import "core:os"
import "core:strings"
import "core:slice"
import "core:c"
import "core:c/libc"
import "core:sys/posix"

// ============================================================================
// Terminal State Management
// ============================================================================

foreign import libc_term "system:c"

STDIN_FILENO :: 0
STDOUT_FILENO :: 1
TCSANOW :: 0

// Per-platform terminal flag constants from core:sys/posix.
ICANON :: posix.ICANON
ECHO   :: posix.ECHO
IXON   :: posix.IXON
IXOFF  :: posix.IXOFF

termios :: struct {
	c_iflag:  c.ulong,
	c_oflag:  c.ulong,
	c_cflag:  c.ulong,
	c_lflag:  c.ulong,
	c_cc:     [20]c.uchar,  // NCCS=20 on macOS
	c_ispeed: c.ulong,
	c_ospeed: c.ulong,
}

foreign libc_term {
	tcgetattr :: proc(fd: c.int, termios_p: ^termios) -> c.int ---
	tcsetattr :: proc(fd: c.int, optional_actions: c.int, termios_p: ^termios) -> c.int ---
	isatty :: proc(fd: c.int) -> c.int ---
}

// Saved terminal state for restore.
saved_termios: termios

enable_raw_mode :: proc() -> bool {
	if tcgetattr(STDIN_FILENO, &saved_termios) != 0 {
		debug("Failed to get terminal attributes")
		return false
	}

	raw := saved_termios
	raw.c_lflag &= ~(c.ulong(ECHO) | c.ulong(ICANON))
	raw.c_iflag &= ~(c.ulong(IXON) | c.ulong(IXOFF))

	if tcsetattr(STDIN_FILENO, TCSANOW, &raw) != 0 {
		debug("Failed to set terminal to raw mode")
		return false
	}

	debug("Terminal set to raw mode")
	return true
}

is_tty :: proc(fd: c.int) -> bool {
	return isatty(fd) != 0
}

is_stdin_tty :: proc() -> bool {
	return is_tty(STDIN_FILENO)
}

is_stdout_tty :: proc() -> bool {
	return is_tty(STDOUT_FILENO)
}

disable_raw_mode :: proc() {
	tcsetattr(STDIN_FILENO, TCSANOW, &saved_termios)
	debug("Terminal restored to original state")
}

// ============================================================================
// Fuzzy Scoring
// ============================================================================

// calculate_fuzzy_score returns a match score for text against query.
// Uses subsequence-aware matching: each consecutive query char match earns
// points, with bonus for exact substring match and prefix match.
// Returns 0 if query doesn't match.
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

	if strings.contains(text, query) {
		score += len(query) * 2
	}
	if strings.has_prefix(text, query) {
		score += len(query) * 3
	}

	return score
}

// ============================================================================
// Interactive Terminal Selection
// ============================================================================

// interactive_select launches a raw-mode terminal picker for the given items.
// Supports real-time fuzzy filtering, Ctrl+N/P navigation, Ctrl+Y / Enter to
// select, and Ctrl+C to cancel. Returns the selected string.
interactive_select :: proc(items: []string, prompt: string) -> (selected: string, ok: bool) {
	if len(items) == 0 {
		print_warning("No items to select from")
		return strings.clone(""), false
	}

	debug("Starting interactive fuzzy select with %d items", len(items))

	CLEAR_SCREEN  :: "\033[2J\033[H"
	HIDE_CURSOR   :: "\033[?25l"
	SHOW_CURSOR   :: "\033[?25h"

	filter_text: [dynamic]u8
	defer delete(filter_text)

	filtered_items: [dynamic]string
	defer delete(filtered_items)

	selected_index := 0

	update_filter :: proc(items: []string, filter: []u8, filtered: ^[dynamic]string) {
		clear(filtered)
		filter_str := string(filter)

		if len(filter) == 0 {
			for item in items do append(filtered, item)
			debug("Filter '' matches %d items", len(filtered))
			return
		}

		query_lower := strings.to_lower(filter_str)
		defer delete(query_lower)

		Scored :: struct { item: string, score: int }
		tmp := make([dynamic]Scored, context.temp_allocator)
		for item in items {
			item_lower := strings.to_lower(item)
			defer delete(item_lower)
			score := calculate_fuzzy_score(item_lower, query_lower)
			if score > 0 do append(&tmp, Scored{item, score})
		}
		slice.sort_by(tmp[:], proc(a, b: Scored) -> bool { return a.score > b.score })
		for entry in tmp do append(filtered, entry.item)

		debug("Filter '%s' matches %d items", filter_str, len(filtered))
	}

	render_ui :: proc(prompt: string, filter: []u8, filtered: []string, selected_idx: int) {
		fmt.print(CLEAR_SCREEN)
		print_prompt(prompt)
		fmt.printf(" %s\r\n", string(filter))
		fmt.print("\r\n")

		visible_start := max(0, selected_idx - 10)
		visible_end := min(len(filtered), visible_start + 20)

		for i in visible_start..<visible_end {
			if i == selected_idx {
				fmt.printf("  %s%s> %s%s\r\n", BRIGHT_YELLOW, BOLD, filtered[i], RESET)
			} else {
				fmt.printf("    %s\r\n", filtered[i])
			}
		}

		if len(filtered) == 0 {
			fmt.printf("  No matches found\r\n")
		}

		fmt.printf("\r\nType to filter, Ctrl+N/P to navigate, Ctrl+Y to select, Ctrl+C to quit\r\n")
	}

	update_filter(items, filter_text[:], &filtered_items)

	if !enable_raw_mode() {
		fmt.eprintln("Error: Failed to enable raw mode")
		return strings.clone(""), false
	}

	fmt.print(HIDE_CURSOR)
	defer {
		fmt.print(CLEAR_SCREEN)
		fmt.print(SHOW_CURSOR)
		disable_raw_mode()
	}

	render_ui(prompt, filter_text[:], filtered_items[:], selected_index)

	for {
		input_buf: [8]byte
		n, err := os.read(os.stdin, input_buf[:])
		if err != nil {
			debug("Error reading input: %v", err)
			break
		}
		if n == 0 do continue

		ch := input_buf[0]

		if ch == 3 { // Ctrl+C
			fmt.print(CLEAR_SCREEN)
			return strings.clone(""), false
		} else if ch == 25 { // Ctrl+Y
			debug("User pressed Ctrl+Y - selecting item")
			if len(filtered_items) > 0 && selected_index < len(filtered_items) {
				result := strings.clone(filtered_items[selected_index])
				debug("Selected: %s", result)
				return result, true
			}
		} else if ch == 14 { // Ctrl+N
			debug("User pressed Ctrl+N - move down")
			if len(filtered_items) > 0 {
				selected_index = (selected_index + 1) % len(filtered_items)
			}
			render_ui(prompt, filter_text[:], filtered_items[:], selected_index)
		} else if ch == 16 { // Ctrl+P
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
				selected_index = 0
				render_ui(prompt, filter_text[:], filtered_items[:], selected_index)
			}
		} else if ch >= 32 && ch <= 126 {
			debug("User typed character: %c", ch)
			append(&filter_text, ch)
			update_filter(items, filter_text[:], &filtered_items)
			selected_index = 0
			render_ui(prompt, filter_text[:], filtered_items[:], selected_index)
		} else if ch == 13 || ch == 10 { // Enter
			debug("User pressed Enter - selecting item")
			if len(filtered_items) > 0 && selected_index < len(filtered_items) {
				result := strings.clone(filtered_items[selected_index])
				debug("Selected: %s", result)
				return result, true
			}
		}

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

// interactive_fuzzy_select delegates to interactive_select.
// Kept as a separate entry point in case TUI mode wants different behavior later.
interactive_fuzzy_select :: proc(items: []string, prompt: string) -> (selected: string, ok: bool) {
	if len(items) == 0 {
		fmt.println("No items to select from")
		return strings.clone(""), false
	}
	return interactive_select(items, prompt)
}

// ============================================================================
// Completions Helpers
// ============================================================================

// extract_completion_items reads the completions directory and returns a
// list of completion names (without the leading underscore).
extract_completion_items :: proc() -> []string {
	completions_dir := fmt.aprintf("%s/completions", g_ctx.wayu_config)
	defer delete(completions_dir)

	if !os.exists(completions_dir) {
		return {}
	}

	dir_handle, err := os.open(completions_dir)
	if err != nil {
		return {}
	}
	defer os.close(dir_handle)

	file_infos, read_err := os.read_dir(dir_handle, -1, context.allocator)
	if read_err != nil {
		return {}
	}
	defer os.file_info_slice_delete(file_infos, context.allocator)

	items := make([dynamic]string)
	defer delete(items)

	for info in file_infos {
		if strings.has_prefix(info.name, "_") && info.type != .Directory {
			if strings.contains(info.name, ".backup.") {
				continue
			}
			name := info.name[1:]
			append(&items, name)
		}
	}

	result := make([]string, len(items))
	for item, i in items {
		result[i] = strings.clone(item)
	}
	return result
}
