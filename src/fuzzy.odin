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
import "core:unicode"
import "core:unicode/utf8"

STDIN_FILENO :: 0
STDOUT_FILENO :: 1
STDERR_FILENO :: 2

// ============================================================================
// Terminal State Management
// ============================================================================
//
// Uses core:sys/posix termios (correct struct layout per OS) instead of a
// hand-rolled macOS-only struct.
//
// Raw mode clears ISIG and IEXTEN in addition to ECHO/ICANON: Ctrl+C (3)
// is then delivered in-band to the pickers/TUI instead of raising SIGINT and
// killing the process with the terminal left raw + cursor hidden, and
// Ctrl+Y no longer triggers macOS's VDSUSP (delayed suspend). SIGTERM /
// SIGHUP still arrive as signals, so a handler restores the terminal before
// re-raising them with the default disposition.

// Saved terminal state for restore.
saved_termios: posix.termios
raw_mode_active: bool

@(private = "file")
prev_sigterm_handler: proc "c" (libc.int)
@(private = "file")
prev_sighup_handler: proc "c" (libc.int)

SIGHUP_NUM :: 1 // POSIX value on macOS/Linux/BSD

// Async-signal-safe: only tcsetattr, write, signal, raise.
terminal_restore_signal_handler :: proc "c" (sig: libc.int) {
	if raw_mode_active {
		posix.tcsetattr(posix.FD(STDIN_FILENO), .TCSANOW, &saved_termios)
		raw_mode_active = false
	}
	show := "\x1b[?25h"
	posix.write(posix.FD(STDOUT_FILENO), raw_data(show), len(show))
	if wayu.tui_mode {
		leave_alt := "\x1b[?1049l"
		posix.write(posix.FD(STDOUT_FILENO), raw_data(leave_alt), len(leave_alt))
	}
	libc.signal(sig, cast(proc "c" (libc.int))libc.SIG_DFL)
	libc.raise(sig)
}

enable_raw_mode :: proc() -> bool {
	if posix.tcgetattr(posix.FD(STDIN_FILENO), &saved_termios) != .OK {
		debug("Failed to get terminal attributes")
		return false
	}

	raw := saved_termios
	raw.c_lflag -= {.ECHO, .ICANON, .ISIG, .IEXTEN}
	raw.c_iflag -= {.IXON, .IXOFF}

	if posix.tcsetattr(posix.FD(STDIN_FILENO), .TCSANOW, &raw) != .OK {
		debug("Failed to set terminal to raw mode")
		return false
	}
	raw_mode_active = true

	prev_sigterm_handler = libc.signal(libc.SIGTERM, terminal_restore_signal_handler)
	prev_sighup_handler  = libc.signal(SIGHUP_NUM, terminal_restore_signal_handler)

	debug("Terminal set to raw mode")
	return true
}

is_tty :: proc(fd: c.int) -> bool {
	return bool(posix.isatty(posix.FD(fd)))
}

is_stdin_tty :: proc() -> bool {
	return is_tty(STDIN_FILENO)
}

is_stdout_tty :: proc() -> bool {
	return is_tty(STDOUT_FILENO)
}

disable_raw_mode :: proc() {
	if !raw_mode_active { return }
	posix.tcsetattr(posix.FD(STDIN_FILENO), .TCSANOW, &saved_termios)
	raw_mode_active = false

	// Put back whatever handlers were installed before raw mode.
	libc.signal(libc.SIGTERM, prev_sigterm_handler)
	libc.signal(SIGHUP_NUM, prev_sighup_handler)
	debug("Terminal restored to original state")
}

// ============================================================================
// Fuzzy Scoring
// ============================================================================

// calculate_fuzzy_score returns a match score for text against query.
// Uses subsequence-aware matching: each consecutive query char match earns
// points, with bonus for exact substring match and prefix match.
// Returns 0 if query doesn't match. Compares runes (UTF-8 aware).
calculate_fuzzy_score :: proc(text: string, query: string) -> int {
	if len(query) == 0 do return 1
	if len(text) == 0 do return 0

	score := 0
	rest := text

	for query_char in query {
		found := false
		for len(rest) > 0 {
			r, w := utf8.decode_rune_in_string(rest)
			rest = rest[w:]
			if r == query_char {
				score += 1
				found = true
				break
			}
		}
		if !found do return 0
	}

	query_runes := utf8.rune_count_in_string(query)
	if strings.contains(text, query) {
		score += query_runes * 2
	}
	if strings.has_prefix(text, query) {
		score += query_runes * 3
	}

	return score
}

// Truncate `s` to at most `max_runes` runes (appending "..." when cut),
// never splitting a UTF-8 sequence. Result is either `s` itself or a
// temp-allocated string — do not delete.
truncate_display :: proc(s: string, max_runes: int) -> string {
	if utf8.rune_count_in_string(s) <= max_runes { return s }
	keep := max(0, max_runes - 3)
	count := 0
	for _, i in s {
		if count == keep {
			return fmt.tprintf("%s...", s[:i])
		}
		count += 1
	}
	return s
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
				// Drop the whole last rune, not just its final byte.
				_, w := utf8.decode_last_rune(filter_text[:])
				resize(&filter_text, len(filter_text) - max(w, 1))
				update_filter(items, filter_text[:], &filtered_items)
				selected_index = 0
				render_ui(prompt, filter_text[:], filtered_items[:], selected_index)
			}
		} else if (ch >= 32 && ch <= 126) || (ch >= 0xC2 && ch <= 0xF4 && utf8.valid_string(string(input_buf[:n]))) {
			// Printable ASCII, or one complete UTF-8 encoded character.
			debug("User typed character: %s", string(input_buf[:n]))
			if ch < 0x80 {
				append(&filter_text, ch)
			} else {
				append(&filter_text, ..input_buf[:n])
			}
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
	completions_dir := fmt.aprintf("%s/completions", wayu.data)
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
// ============================================================================
// Scoring and Matching (Pure Odin, no FFI required for basic fuzzy)
// ============================================================================

// Simple fuzzy score calculation (0 = no match, higher = better)
fuzzy_score :: proc(text: string, query: string) -> int {
    if len(query) == 0 {
        return 1
    }
    if len(text) == 0 {
        return 0
    }
    
    text_lower := strings.to_lower(text)
    defer delete(text_lower)
    query_lower := strings.to_lower(query)
    defer delete(query_lower)
    
    score := 0
    rest := text_lower
    consecutive_bonus := 0

    // Rune-by-rune (UTF-8 aware): comparing text bytes against query runes
    // never matched non-ASCII characters.
    for query_char in query_lower {
        found := false
        for len(rest) > 0 {
            r, w := utf8.decode_rune_in_string(rest)
            rest = rest[w:]
            if r == query_char {
                score += 10 + consecutive_bonus
                consecutive_bonus += 5  // Bonus for consecutive matches
                found = true
                break
            }
            consecutive_bonus = 0  // Reset consecutive bonus
        }
        if !found {
            return 0
        }
    }

    query_runes := utf8.rune_count_in_string(query)

    // Bonus for exact substring match
    if strings.contains(text_lower, query_lower) {
        score += query_runes * 20
    }

    // Bonus for exact match at start
    if strings.has_prefix(text_lower, query_lower) {
        score += query_runes * 30
    }

    // Bonus for acronym match (e.g., "frwrks" matches "FIREWORKS")
    if is_acronym_match(text, query) {
        score += query_runes * 25
    }

    // Penalty for length difference
    length_diff := utf8.rune_count_in_string(text) - query_runes
    if length_diff > 0 {
        score -= length_diff * 2
    }
    
    return score
}

// Check if query matches acronym of text
// e.g., text="FIREWORKS_AI_API_KEY", query="frwrks" → true
is_acronym_match :: proc(text: string, query: string) -> bool {
    // Build acronym from the first rune of each separator-delimited word,
    // lower-cased as a full rune (u8 truncation corrupted non-ASCII).
    acronym := strings.builder_make()
    defer strings.builder_destroy(&acronym)

    prev_was_sep := true  // Start true to capture first letter

    for c in text {
        is_sep := c == '_' || c == '-' || c == ' ' || c == '.' || (c >= '0' && c <= '9')

        if is_sep {
            prev_was_sep = true
        } else if prev_was_sep {
            strings.write_rune(&acronym, unicode.to_lower(c))
            prev_was_sep = false
        }
    }

    acronym_str := strings.to_string(acronym)
    if len(acronym_str) == 0 {
        return false
    }
    query_lower := strings.to_lower(query)
    defer delete(query_lower)
    
    return strings.contains(acronym_str, query_lower)
}

// ============================================================================
// Fuzzy Match Result
// ============================================================================

FuzzyMatch :: struct {
    entry: ConfigEntry,
    score: int,
    match_type: MatchType,
}

MatchType :: enum {
    Exact,           // Match exacto
    Prefix,          // Prefijo exacto
    Substring,       // Substring
    Fuzzy,           // Fuzzy match general
    Acronym,         // Match por acrónimo
}

// ============================================================================
// Fuzzy Search Functions
// ============================================================================

// Find fuzzy matches across all entries of a spec
fuzzy_find_entries :: proc(spec: ^ConfigEntrySpec, query: string, max_results := 10) -> []FuzzyMatch {
    if len(query) == 0 {
        return nil
    }
    
    entries := read_config_entries(spec)
    defer cleanup_entries(&entries)
    
    matches := make([dynamic]FuzzyMatch)
    defer if len(matches) == 0 {
        delete(matches)
    }
    
    query_lower := strings.to_lower(query)
    defer delete(query_lower)
    
    for entry in entries {
        score := 0
        match_type := MatchType.Fuzzy
        
        // Check for exact match
        if strings.equal_fold(entry.name, query) {
            score = 10000
            match_type = .Exact
        } else if strings.has_prefix(strings.to_lower(entry.name), query_lower) {
            // Prefix match
            score = 5000 + fuzzy_score(entry.name, query)
            match_type = .Prefix
        } else if strings.contains(strings.to_lower(entry.name), query_lower) {
            // Substring match
            score = 3000 + fuzzy_score(entry.name, query)
            match_type = .Substring
        } else if is_acronym_match(entry.name, query) {
            // Acronym match (e.g., frwrks → FIREWORKS)
            score = 2000 + fuzzy_score(entry.name, query)
            match_type = .Acronym
        } else {
            // General fuzzy match
            score = fuzzy_score(entry.name, query)
            match_type = .Fuzzy
        }
        
        if score > 0 {
            append(&matches, FuzzyMatch{
                entry = clone_entry(entry),
                score = score,
                match_type = match_type,
            })
        }
    }
    
    if len(matches) == 0 {
        return nil
    }
    
    // Sort by score descending
    slice.sort_by(matches[:], proc(a, b: FuzzyMatch) -> bool {
        return a.score > b.score
    })
    
    // Return top results
    result_count := min(max_results, len(matches))
    result := make([]FuzzyMatch, result_count)
    for i in 0..<result_count {
        result[i] = matches[i]
    }
    
    // Clean up remaining matches
    for i in result_count..<len(matches) {
        cleanup_clone(matches[i].entry)
    }
    delete(matches)
    
    return result
}

// Clone a config entry
clone_entry :: proc(entry: ConfigEntry) -> ConfigEntry {
    return ConfigEntry{
        type = entry.type,
        name = strings.clone(entry.name),
        value = strings.clone(entry.value),
        line = strings.clone(entry.line),
    }
}

// Helper to clean up cloned entries - takes entry by value and cleans it up
cleanup_clone :: proc(entry: ConfigEntry) {
    if entry.name != "" {
        delete(entry.name)
    }
    if entry.value != "" {
        delete(entry.value)
    }
    if entry.line != "" {
        delete(entry.line)
    }
}

// ============================================================================
// GET miss reporting
// ============================================================================

// `get` is exact-match only: scripts run X=$(wayu const get NAME) and must
// never receive another entry's value (FIRE used to return
// FIREWORKS_AI_API_KEY). On a miss, print the error plus up to
// GET_SUGGESTION_LIMIT similar NAMES (never values) to stderr and exit
// EXIT_DATAERR. `names` holds every name of the entry type. (OKAMI-207)
GET_SUGGESTION_LIMIT :: 5

exit_get_not_found :: proc(spec: ^ConfigEntrySpec, query: string, names: []string) -> ! {
	print_error_simple("%s not found: %s", spec.display_name, query)
	suggestions := suggest_similar_names(query, names, GET_SUGGESTION_LIMIT, context.temp_allocator)
	if len(suggestions) > 0 {
		fmt.eprintln("Did you mean:")
		for name in suggestions { fmt.eprintfln("  %s", name) }
	}
	os.exit(EXIT_DATAERR)
}

// Rank `names` against `query` (exact-fold > prefix > substring > acronym >
// fuzzy) and return the best `limit`. The result slice is allocated with
// `allocator`; its strings are views into `names`.
suggest_similar_names :: proc(query: string, names: []string, limit: int, allocator := context.allocator) -> []string {
	Scored :: struct { name: string, score: int }
	scored := make([dynamic]Scored, 0, len(names), context.temp_allocator)

	query_lower := strings.to_lower(query, context.temp_allocator)
	for name in names {
		name_lower := strings.to_lower(name, context.temp_allocator)
		score: int
		switch {
		case name_lower == query_lower:                   score = 10000
		case strings.has_prefix(name_lower, query_lower): score = 5000 + fuzzy_score(name, query)
		case strings.contains(name_lower, query_lower):   score = 3000 + fuzzy_score(name, query)
		case is_acronym_match(name, query):               score = 2000 + fuzzy_score(name, query)
		case:                                             score = fuzzy_score(name, query)
		}
		if score > 0 { append(&scored, Scored{name, score}) }
	}

	slice.sort_by(scored[:], proc(a, b: Scored) -> bool {
		if a.score != b.score { return a.score > b.score }
		return a.name < b.name
	})

	n := min(limit, len(scored))
	result := make([]string, n, allocator)
	for i in 0..<n { result[i] = scored[i].name }
	return result
}
