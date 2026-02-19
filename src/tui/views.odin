// tui_views.odin - TUI view rendering for all wayu configuration types
//
// This module implements the 8 TUI views:
// - Main Menu (navigation hub)
// - PATH View (list PATH entries)
// - Alias View (list aliases with definitions)
// - Constants View (list environment variables)
// - Completions View (list completion scripts)
// - Backups View (list backups with timestamps)
// - Plugins View (placeholder)
// - Settings View (configuration display)
//
// Note: This module does NOT import the main wayu package to avoid circular dependencies.
// Data loading is handled by bridge functions in main.odin that populate the state.data_cache.

package wayu_tui

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

// ============================================================================
// Text Truncation Helper
// ============================================================================

// Truncate text to fit within max_runes, appending "…" if truncated.
// Works on rune count (not byte count) for correct Unicode handling.
// Returns a tprintf'd string (temp allocation, do NOT delete).
truncate_text :: proc(text: string, max_runes: int) -> string {
	if max_runes <= 0 do return ""
	count := utf8.rune_count_in_string(text)
	if count <= max_runes do return text
	// Truncate: take (max_runes - 1) runes + "…"
	truncated_bytes := 0
	runes_seen := 0
	remaining := text
	for len(remaining) > 0 {
		if runes_seen >= max_runes - 1 do break
		_, size := utf8.decode_rune_in_string(remaining)
		truncated_bytes += size
		remaining = remaining[size:]
		runes_seen += 1
	}
	return fmt.tprintf("%s…", text[:truncated_bytes])
}

// ============================================================================
// Table Layout Constants & Helpers
// ============================================================================

// Column layout constants for two-column table views (Alias, Constants)
COLUMN_GAP          :: 3   // spaces between key and value columns
MIN_KEY_COL_WIDTH   :: 8   // minimum key column width
KEY_COL_MAX_PERCENT :: 30  // max % of content width for key column

// Calculate optimal key column width by scanning all items for max key length.
// Items are "key=value" strings; key length is measured in runes.
// Returns width clamped between MIN_KEY_COL_WIDTH and 30% of max_text_width.
calculate_key_column_width :: proc(items: ^[dynamic]string, max_text_width: int) -> int {
	max_key_len := 0
	for item in items {
		eq_idx := strings.index_byte(item, '=')
		key_len: int
		if eq_idx >= 0 {
			key_len = utf8.rune_count_in_string(item[:eq_idx])
		} else {
			key_len = utf8.rune_count_in_string(item)
		}
		if key_len > max_key_len {
			max_key_len = key_len
		}
	}
	desired := max_key_len + 2  // breathing room
	max_allowed := max_text_width * KEY_COL_MAX_PERCENT / 100
	if max_allowed < MIN_KEY_COL_WIDTH {
		max_allowed = MIN_KEY_COL_WIDTH
	}
	return clamp(desired, MIN_KEY_COL_WIDTH, max_allowed)
}

// Render a single table row with key and value in separate columns.
// Splits item on first '=', truncates each column independently,
// pads key to fixed width, and renders with appropriate colors.
render_table_row :: proc(
	screen: ^Screen,
	x, y: int,
	item: string,
	key_col_width, value_col_width: int,
	is_selected: bool,
) {
	// Split on first '='
	eq_idx := strings.index_byte(item, '=')
	key, value: string
	if eq_idx >= 0 {
		key = item[:eq_idx]
		value = item[eq_idx + 1:]
	} else {
		key = item
		value = ""
	}

	// Truncate key and value independently
	truncated_key := truncate_text(key, key_col_width)
	truncated_value := truncate_text(value, value_col_width)

	// Calculate padding to align value column
	key_rune_count := utf8.rune_count_in_string(truncated_key)
	padding := key_col_width - key_rune_count
	if padding < 0 {
		padding = 0
	}

	// Build padded key with prefix
	if is_selected {
		// Selected: "> " + key, all hot pink bold
		prefix_and_key := fmt.tprintf("> %s", truncated_key)
		render_text_styled(screen, x, y, prefix_and_key, TUI_PRIMARY, "", true)
		// Render value at fixed column position
		if len(truncated_value) > 0 {
			value_x := x + SELECTION_PREFIX_WIDTH + key_col_width + COLUMN_GAP
			render_text_styled(screen, value_x, y, truncated_value, TUI_PRIMARY, "", true)
		}
	} else {
		// Normal: "  " + key in muted, value in dim
		prefix_and_key := fmt.tprintf("  %s", truncated_key)
		render_text_styled(screen, x, y, prefix_and_key, TUI_MUTED)
		if len(truncated_value) > 0 {
			value_x := x + SELECTION_PREFIX_WIDTH + key_col_width + COLUMN_GAP
			render_text_styled(screen, value_x, y, truncated_value, TUI_DIM)
		}
	}
}

// Render column header row for table views (e.g., "ALIAS   COMMAND" or "NAME   VALUE")
render_column_header :: proc(screen: ^Screen, x, y: int, key_label, value_label: string, key_col_width: int) {
	render_text_styled(screen, x + SELECTION_PREFIX_WIDTH, y, key_label, TUI_DIM)
	value_x := x + SELECTION_PREFIX_WIDTH + key_col_width + COLUMN_GAP
	render_text_styled(screen, value_x, y, value_label, TUI_DIM)
}

// ============================================================================
// PATH View
// ============================================================================

// Render PATH configuration view with scrollable list (using layout constants)
render_path_view :: proc(state: ^TUIState, screen: ^Screen) {
	// Draw outer border using calculated dimensions
	border_width, border_height := calculate_border_dimensions(state.terminal_width, state.terminal_height)
	max_text_width := calculate_content_width(border_width)
	render_box_styled(screen, BORDER_LEFT_WIDTH, BORDER_TOP_HEIGHT, border_width, border_height, TUI_BORDER_FOCUSED)

	// Data should be loaded by bridge layer
	if state.data_cache[.PATH_VIEW] == nil {
		header_x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT
		render_text_styled(screen, header_x, HEADER_TITLE_LINE + CONTENT_PADDING_TOP, "📂 PATH Configuration", TUI_PRIMARY, "", true)
		render_text_styled(screen, header_x, HEADER_TITLE_LINE + CONTENT_PADDING_TOP + 2, "Loading...", TUI_DIM)
		state.needs_refresh = true
		return
	}

	items := cast(^[dynamic]string)state.data_cache[.PATH_VIEW]

	// Header (hot pink + bold)
	header_x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT
	render_text_styled(screen, header_x, HEADER_TITLE_LINE + CONTENT_PADDING_TOP, "📂 PATH Configuration", TUI_PRIMARY, "", true)
	count_text := fmt.tprintf("%d entries", len(items))
	// Note: tprintf() uses temp buffer, do NOT delete
	render_text_styled(screen, header_x, HEADER_COUNT_LINE + CONTENT_PADDING_TOP, count_text, TUI_DIM)

	// Filter bar (shown when filter is active or has text)
	filter_bar_y := HEADER_COUNT_LINE + CONTENT_PADDING_TOP + 1
	has_filter := state.filter_active || len(state.filter_text) > 0
	list_start_offset := 0
	if has_filter {
		filter_str := string(state.filter_text[:])
		if state.filter_active {
			// Show active filter with cursor
			filter_display := fmt.tprintf("/ %s█  (%d/%d matches)", filter_str, len(state.filtered_indices), len(items))
			render_text_styled(screen, header_x, filter_bar_y, filter_display, TUI_SECONDARY, "", true)
		} else {
			// Show applied filter (no cursor)
			filter_display := fmt.tprintf("/ %s  (%d/%d matches)", filter_str, len(state.filtered_indices), len(items))
			render_text_styled(screen, header_x, filter_bar_y, filter_display, TUI_DIM)
		}
		list_start_offset = 1  // Push list down by 1 line for filter bar
	}

	if has_filter && len(state.filtered_indices) > 0 {
		// Render filtered items
		visible_height := calculate_visible_height(state.terminal_height) - list_start_offset
		start := state.scroll_offset
		end := min(start + visible_height, len(state.filtered_indices))

		for idx in start..<end {
			y := calculate_list_item_y(idx - start) + list_start_offset
			original_idx := state.filtered_indices[idx]
			entry := items[original_idx]

			if idx == state.selected_index {
				text := fmt.tprintf("> %s", truncate_text(entry, max_text_width))
				render_text_styled(screen, header_x, y, text, TUI_PRIMARY, "", true)
			} else {
				text := fmt.tprintf("  %s", truncate_text(entry, max_text_width))
				render_text_styled(screen, header_x + SELECTION_PREFIX_WIDTH, y, text, TUI_MUTED)
			}
		}

		// Scroll indicator for filtered results
		if len(state.filtered_indices) > visible_height {
			scroll_info := fmt.tprintf("Showing %d-%d of %d matches", start+1, end, len(state.filtered_indices))
			scroll_y := LIST_ITEM_START_LINE + visible_height + list_start_offset
			render_text_styled(screen, header_x, scroll_y, scroll_info, TUI_DIM)
		}
	} else if has_filter && len(state.filtered_indices) == 0 {
		// No matches
		no_match_y := LIST_ITEM_START_LINE + list_start_offset + 1
		render_text_styled(screen, header_x, no_match_y, "No matches found", TUI_DIM)
	} else if len(items) == 0 {
		render_text_styled(screen, header_x, LIST_ITEM_START_LINE + 1, "No PATH entries found", TUI_DIM)
	} else {
		// List items with scrolling (unfiltered)
		visible_height := calculate_visible_height(state.terminal_height)
		start := state.scroll_offset
		end := min(start + visible_height, len(items))

		for i in start..<end {
			y := calculate_list_item_y(i - start)
			entry := items[i]

			if i == state.selected_index {
				// Selected item: hot pink text + bold (NO background)
				text := fmt.tprintf("> %s", truncate_text(entry, max_text_width))
				// Note: tprintf() uses temp buffer, do NOT delete
				render_text_styled(screen, header_x, y, text, TUI_PRIMARY, "", true)
			} else {
				// Normal item: muted gray text (indented by selection prefix width)
				text := fmt.tprintf("  %s", truncate_text(entry, max_text_width))
				// Note: tprintf() uses temp buffer, do NOT delete
				render_text_styled(screen, header_x + SELECTION_PREFIX_WIDTH, y, text, TUI_MUTED)
			}
		}

		// Show scroll indicator if needed (dim gray)
		if len(items) > visible_height {
			scroll_info := fmt.tprintf("Showing %d-%d of %d", start+1, end, len(items))
			// Note: tprintf() uses temp buffer, do NOT delete
			scroll_y := LIST_ITEM_START_LINE + visible_height
			render_text_styled(screen, header_x, scroll_y, scroll_info, TUI_DIM)
		}
	}

	// Footer with shortcuts (muted gray)
	footer_y := calculate_footer_y(state.terminal_height)
	if state.filter_active {
		render_text_styled(screen, header_x, footer_y, "Type to filter  Esc=Cancel  Enter=Accept  ↑/↓=Navigate", TUI_MUTED)
	} else if has_filter {
		render_text_styled(screen, header_x, footer_y, "/=Filter  d=Delete  Esc=Back  ↑/↓ or j/k=Navigate", TUI_MUTED)
	} else {
		render_text_styled(screen, header_x, footer_y, "/=Filter  d=Delete  Esc=Back  ↑/↓ or j/k=Navigate", TUI_MUTED)
	}
}

// ============================================================================
// Alias View
// ============================================================================

// Render alias view with two-column table layout (ALIAS | COMMAND)
render_alias_view :: proc(state: ^TUIState, screen: ^Screen) {
	// Draw outer border using calculated dimensions
	border_width, border_height := calculate_border_dimensions(state.terminal_width, state.terminal_height)
	max_text_width := calculate_content_width(border_width)
	render_box_styled(screen, BORDER_LEFT_WIDTH, BORDER_TOP_HEIGHT, border_width, border_height, TUI_BORDER_FOCUSED)

	// Data should be loaded by bridge layer
	if state.data_cache[.ALIAS_VIEW] == nil {
		header_x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT
		render_text_styled(screen, header_x, HEADER_TITLE_LINE + CONTENT_PADDING_TOP, "🔑 Aliases", TUI_PRIMARY, "", true)
		render_text_styled(screen, header_x, HEADER_TITLE_LINE + CONTENT_PADDING_TOP + 2, "Loading...", TUI_DIM)
		state.needs_refresh = true
		return
	}

	items := cast(^[dynamic]string)state.data_cache[.ALIAS_VIEW]

	// Header (hot pink + bold)
	header_x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT
	render_text_styled(screen, header_x, HEADER_TITLE_LINE + CONTENT_PADDING_TOP, "🔑 Aliases", TUI_PRIMARY, "", true)
	count_text := fmt.tprintf("%d aliases", len(items))
	render_text_styled(screen, header_x, HEADER_COUNT_LINE + CONTENT_PADDING_TOP, count_text, TUI_DIM)

	// Calculate table column widths
	key_col_width := calculate_key_column_width(items, max_text_width)
	value_col_width := max_text_width - key_col_width - COLUMN_GAP
	if value_col_width < 1 {
		value_col_width = 1
	}

	// Filter bar (shown when filter is active or has text)
	filter_bar_y := HEADER_COUNT_LINE + CONTENT_PADDING_TOP + 1
	has_filter := state.filter_active || len(state.filter_text) > 0
	list_start_offset := 0
	if has_filter {
		filter_str := string(state.filter_text[:])
		if state.filter_active {
			filter_display := fmt.tprintf("/ %s█  (%d/%d matches)", filter_str, len(state.filtered_indices), len(items))
			render_text_styled(screen, header_x, filter_bar_y, filter_display, TUI_SECONDARY, "", true)
		} else {
			filter_display := fmt.tprintf("/ %s  (%d/%d matches)", filter_str, len(state.filtered_indices), len(items))
			render_text_styled(screen, header_x, filter_bar_y, filter_display, TUI_DIM)
		}
		list_start_offset = 1
	}

	// Column header row (always shown when there are items)
	show_items := (has_filter && len(state.filtered_indices) > 0) || (!has_filter && len(items) > 0)
	if show_items {
		col_header_y := LIST_ITEM_START_LINE + list_start_offset
		render_column_header(screen, header_x, col_header_y, "ALIAS", "COMMAND", key_col_width)
		list_start_offset += 1  // push list items down past column header
	}

	if has_filter && len(state.filtered_indices) > 0 {
		// Render filtered items
		visible_height := calculate_visible_height(state.terminal_height) - list_start_offset
		start := state.scroll_offset
		end := min(start + visible_height, len(state.filtered_indices))

		for idx in start..<end {
			y := calculate_list_item_y(idx - start) + list_start_offset
			original_idx := state.filtered_indices[idx]
			item := items[original_idx]
			render_table_row(screen, header_x, y, item, key_col_width, value_col_width, idx == state.selected_index)
		}

		if len(state.filtered_indices) > visible_height {
			scroll_info := fmt.tprintf("Showing %d-%d of %d matches", start+1, end, len(state.filtered_indices))
			scroll_y := LIST_ITEM_START_LINE + visible_height + list_start_offset
			render_text_styled(screen, header_x, scroll_y, scroll_info, TUI_DIM)
		}
	} else if has_filter && len(state.filtered_indices) == 0 {
		no_match_y := LIST_ITEM_START_LINE + list_start_offset + 1
		render_text_styled(screen, header_x, no_match_y, "No matches found", TUI_DIM)
	} else if len(items) == 0 {
		render_text_styled(screen, header_x, LIST_ITEM_START_LINE + 1, "No aliases found", TUI_DIM)
	} else {
		// List items with scrolling (unfiltered)
		visible_height := calculate_visible_height(state.terminal_height) - list_start_offset
		start := state.scroll_offset
		end := min(start + visible_height, len(items))

		for i in start..<end {
			y := calculate_list_item_y(i - start) + list_start_offset
			item := items[i]
			render_table_row(screen, header_x, y, item, key_col_width, value_col_width, i == state.selected_index)
		}

		// Show scroll indicator if needed (dim gray)
		if len(items) > visible_height {
			scroll_info := fmt.tprintf("Showing %d-%d of %d", start+1, end, len(items))
			scroll_y := LIST_ITEM_START_LINE + visible_height + list_start_offset
			render_text_styled(screen, header_x, scroll_y, scroll_info, TUI_DIM)
		}
	}

	// Footer with shortcuts (muted gray)
	footer_y := calculate_footer_y(state.terminal_height)
	if state.filter_active {
		render_text_styled(screen, header_x, footer_y, "Type to filter  Esc=Cancel  Enter=Accept  ↑/↓=Navigate", TUI_MUTED)
	} else if has_filter {
		render_text_styled(screen, header_x, footer_y, "/=Filter  d=Delete  Esc=Back  ↑/↓ or j/k=Navigate", TUI_MUTED)
	} else {
		render_text_styled(screen, header_x, footer_y, "/=Filter  d=Delete  Esc=Back  ↑/↓ or j/k=Navigate", TUI_MUTED)
	}
}

// ============================================================================
// Constants View
// ============================================================================

// Render constants view with two-column table layout (NAME | VALUE)
render_constants_view :: proc(state: ^TUIState, screen: ^Screen) {
	// Draw outer border using calculated dimensions
	border_width, border_height := calculate_border_dimensions(state.terminal_width, state.terminal_height)
	max_text_width := calculate_content_width(border_width)
	render_box_styled(screen, BORDER_LEFT_WIDTH, BORDER_TOP_HEIGHT, border_width, border_height, TUI_BORDER_FOCUSED)

	// Data should be loaded by bridge layer
	if state.data_cache[.CONSTANTS_VIEW] == nil {
		header_x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT
		render_text_styled(screen, header_x, HEADER_TITLE_LINE + CONTENT_PADDING_TOP, "💾 Environment Constants", TUI_PRIMARY, "", true)
		render_text_styled(screen, header_x, HEADER_TITLE_LINE + CONTENT_PADDING_TOP + 2, "Loading...", TUI_DIM)
		state.needs_refresh = true
		return
	}

	items := cast(^[dynamic]string)state.data_cache[.CONSTANTS_VIEW]

	// Header (hot pink + bold)
	header_x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT
	render_text_styled(screen, header_x, HEADER_TITLE_LINE + CONTENT_PADDING_TOP, "💾 Environment Constants", TUI_PRIMARY, "", true)
	count_text := fmt.tprintf("%d constants", len(items))
	render_text_styled(screen, header_x, HEADER_COUNT_LINE + CONTENT_PADDING_TOP, count_text, TUI_DIM)

	// Calculate table column widths
	key_col_width := calculate_key_column_width(items, max_text_width)
	value_col_width := max_text_width - key_col_width - COLUMN_GAP
	if value_col_width < 1 {
		value_col_width = 1
	}

	// Filter bar (shown when filter is active or has text)
	filter_bar_y := HEADER_COUNT_LINE + CONTENT_PADDING_TOP + 1
	has_filter := state.filter_active || len(state.filter_text) > 0
	list_start_offset := 0
	if has_filter {
		filter_str := string(state.filter_text[:])
		if state.filter_active {
			filter_display := fmt.tprintf("/ %s█  (%d/%d matches)", filter_str, len(state.filtered_indices), len(items))
			render_text_styled(screen, header_x, filter_bar_y, filter_display, TUI_SECONDARY, "", true)
		} else {
			filter_display := fmt.tprintf("/ %s  (%d/%d matches)", filter_str, len(state.filtered_indices), len(items))
			render_text_styled(screen, header_x, filter_bar_y, filter_display, TUI_DIM)
		}
		list_start_offset = 1
	}

	// Column header row (always shown when there are items)
	show_items := (has_filter && len(state.filtered_indices) > 0) || (!has_filter && len(items) > 0)
	if show_items {
		col_header_y := LIST_ITEM_START_LINE + list_start_offset
		render_column_header(screen, header_x, col_header_y, "NAME", "VALUE", key_col_width)
		list_start_offset += 1  // push list items down past column header
	}

	if has_filter && len(state.filtered_indices) > 0 {
		// Render filtered items
		visible_height := calculate_visible_height(state.terminal_height) - list_start_offset
		start := state.scroll_offset
		end := min(start + visible_height, len(state.filtered_indices))

		for idx in start..<end {
			y := calculate_list_item_y(idx - start) + list_start_offset
			original_idx := state.filtered_indices[idx]
			item := items[original_idx]
			render_table_row(screen, header_x, y, item, key_col_width, value_col_width, idx == state.selected_index)
		}

		if len(state.filtered_indices) > visible_height {
			scroll_info := fmt.tprintf("Showing %d-%d of %d matches", start+1, end, len(state.filtered_indices))
			scroll_y := LIST_ITEM_START_LINE + visible_height + list_start_offset
			render_text_styled(screen, header_x, scroll_y, scroll_info, TUI_DIM)
		}
	} else if has_filter && len(state.filtered_indices) == 0 {
		no_match_y := LIST_ITEM_START_LINE + list_start_offset + 1
		render_text_styled(screen, header_x, no_match_y, "No matches found", TUI_DIM)
	} else if len(items) == 0 {
		render_text_styled(screen, header_x, LIST_ITEM_START_LINE + 1, "No constants found", TUI_DIM)
	} else {
		// List items with scrolling (unfiltered)
		visible_height := calculate_visible_height(state.terminal_height) - list_start_offset
		start := state.scroll_offset
		end := min(start + visible_height, len(items))

		for i in start..<end {
			y := calculate_list_item_y(i - start) + list_start_offset
			item := items[i]
			render_table_row(screen, header_x, y, item, key_col_width, value_col_width, i == state.selected_index)
		}

		// Show scroll indicator if needed (dim gray)
		if len(items) > visible_height {
			scroll_info := fmt.tprintf("Showing %d-%d of %d", start+1, end, len(items))
			scroll_y := LIST_ITEM_START_LINE + visible_height + list_start_offset
			render_text_styled(screen, header_x, scroll_y, scroll_info, TUI_DIM)
		}
	}

	// Footer with shortcuts (muted gray)
	footer_y := calculate_footer_y(state.terminal_height)
	if state.filter_active {
		render_text_styled(screen, header_x, footer_y, "Type to filter  Esc=Cancel  Enter=Accept  ↑/↓=Navigate", TUI_MUTED)
	} else if has_filter {
		render_text_styled(screen, header_x, footer_y, "/=Filter  d=Delete  Esc=Back  ↑/↓ or j/k=Navigate", TUI_MUTED)
	} else {
		render_text_styled(screen, header_x, footer_y, "/=Filter  d=Delete  Esc=Back  ↑/↓ or j/k=Navigate", TUI_MUTED)
	}
}

// ============================================================================
// Completions View
// ============================================================================

// Render completions view (using layout constants)
render_completions_view :: proc(state: ^TUIState, screen: ^Screen) {
	// Draw outer border using calculated dimensions
	border_width, border_height := calculate_border_dimensions(state.terminal_width, state.terminal_height)
	max_text_width := calculate_content_width(border_width)
	render_box_styled(screen, BORDER_LEFT_WIDTH, BORDER_TOP_HEIGHT, border_width, border_height, TUI_BORDER_FOCUSED)

	// Data should be loaded by bridge layer
	if state.data_cache[.COMPLETIONS_VIEW] == nil {
		header_x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT
		render_text_styled(screen, header_x, HEADER_TITLE_LINE + CONTENT_PADDING_TOP, "🎯 Completions", TUI_PRIMARY, "", true)
		render_text_styled(screen, header_x, HEADER_TITLE_LINE + CONTENT_PADDING_TOP + 2, "Loading...", TUI_DIM)
		state.needs_refresh = true
		return
	}

	items := cast(^[dynamic]string)state.data_cache[.COMPLETIONS_VIEW]

	// Header (hot pink + bold)
	header_x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT
	render_text_styled(screen, header_x, HEADER_TITLE_LINE + CONTENT_PADDING_TOP, "🎯 Completions", TUI_PRIMARY, "", true)
	count_text := fmt.tprintf("%d completion scripts", len(items))
	render_text_styled(screen, header_x, HEADER_COUNT_LINE + CONTENT_PADDING_TOP, count_text, TUI_DIM)

	// Filter bar (shown when filter is active or has text)
	filter_bar_y := HEADER_COUNT_LINE + CONTENT_PADDING_TOP + 1
	has_filter := state.filter_active || len(state.filter_text) > 0
	list_start_offset := 0
	if has_filter {
		filter_str := string(state.filter_text[:])
		if state.filter_active {
			filter_display := fmt.tprintf("/ %s█  (%d/%d matches)", filter_str, len(state.filtered_indices), len(items))
			render_text_styled(screen, header_x, filter_bar_y, filter_display, TUI_SECONDARY, "", true)
		} else {
			filter_display := fmt.tprintf("/ %s  (%d/%d matches)", filter_str, len(state.filtered_indices), len(items))
			render_text_styled(screen, header_x, filter_bar_y, filter_display, TUI_DIM)
		}
		list_start_offset = 1
	}

	if has_filter && len(state.filtered_indices) > 0 {
		// Render filtered items
		visible_height := calculate_visible_height(state.terminal_height) - list_start_offset
		start := state.scroll_offset
		end := min(start + visible_height, len(state.filtered_indices))

		for idx in start..<end {
			y := calculate_list_item_y(idx - start) + list_start_offset
			original_idx := state.filtered_indices[idx]
			completion := items[original_idx]

			if idx == state.selected_index {
				text := fmt.tprintf("> %s", truncate_text(completion, max_text_width))
				render_text_styled(screen, header_x, y, text, TUI_PRIMARY, "", true)
			} else {
				text := fmt.tprintf("  %s", truncate_text(completion, max_text_width))
				render_text_styled(screen, header_x + SELECTION_PREFIX_WIDTH, y, text, TUI_MUTED)
			}
		}

		if len(state.filtered_indices) > visible_height {
			scroll_info := fmt.tprintf("Showing %d-%d of %d matches", start+1, end, len(state.filtered_indices))
			scroll_y := LIST_ITEM_START_LINE + visible_height + list_start_offset
			render_text_styled(screen, header_x, scroll_y, scroll_info, TUI_DIM)
		}
	} else if has_filter && len(state.filtered_indices) == 0 {
		no_match_y := LIST_ITEM_START_LINE + list_start_offset + 1
		render_text_styled(screen, header_x, no_match_y, "No matches found", TUI_DIM)
	} else if len(items) == 0 {
		render_text_styled(screen, header_x, LIST_ITEM_START_LINE + 1, "No completion scripts found", TUI_DIM)
		render_text_styled(screen, header_x, LIST_ITEM_START_LINE + 3, "Add completions with: wayu completions add <name> <file>", TUI_MUTED)
	} else {
		// List completions with scrolling (unfiltered)
		visible_height := calculate_visible_height(state.terminal_height)
		start := state.scroll_offset
		end := min(start + visible_height, len(items))

		for i in start..<end {
			y := calculate_list_item_y(i - start)
			completion := items[i]

			if i == state.selected_index {
				// Selected item: hot pink text + bold (NO background)
				text := fmt.tprintf("> %s", truncate_text(completion, max_text_width))
				render_text_styled(screen, header_x, y, text, TUI_PRIMARY, "", true)
			} else {
				// Normal item: muted gray text (indented by selection prefix width)
				text := fmt.tprintf("  %s", truncate_text(completion, max_text_width))
				render_text_styled(screen, header_x + SELECTION_PREFIX_WIDTH, y, text, TUI_MUTED)
			}
		}

		// Show scroll indicator if needed (dim gray)
		if len(items) > visible_height {
			scroll_info := fmt.tprintf("Showing %d-%d of %d", start+1, end, len(items))
			scroll_y := LIST_ITEM_START_LINE + visible_height
			render_text_styled(screen, header_x, scroll_y, scroll_info, TUI_DIM)
		}
	}

	// Footer with shortcuts (muted gray)
	footer_y := calculate_footer_y(state.terminal_height)
	if state.filter_active {
		render_text_styled(screen, header_x, footer_y, "Type to filter  Esc=Cancel  Enter=Accept  ↑/↓=Navigate", TUI_MUTED)
	} else if has_filter {
		render_text_styled(screen, header_x, footer_y, "/=Filter  Esc=Back  ↑/↓ or j/k=Navigate", TUI_MUTED)
	} else {
		render_text_styled(screen, header_x, footer_y, "/=Filter  Esc=Back  ↑/↓ or j/k=Navigate", TUI_MUTED)
	}
}

// ============================================================================
// Backups View
// ============================================================================

// Render backups view with timestamps and config types (using layout constants)
render_backups_view :: proc(state: ^TUIState, screen: ^Screen) {
	// Draw outer border using calculated dimensions
	border_width, border_height := calculate_border_dimensions(state.terminal_width, state.terminal_height)
	max_text_width := calculate_content_width(border_width)
	render_box_styled(screen, BORDER_LEFT_WIDTH, BORDER_TOP_HEIGHT, border_width, border_height, TUI_BORDER_FOCUSED)

	// Data should be loaded by bridge layer
	if state.data_cache[.BACKUPS_VIEW] == nil {
		header_x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT
		render_text_styled(screen, header_x, HEADER_TITLE_LINE + CONTENT_PADDING_TOP, "💾 Backups", TUI_PRIMARY, "", true)
		render_text_styled(screen, header_x, HEADER_TITLE_LINE + CONTENT_PADDING_TOP + 2, "Loading...", TUI_DIM)
		state.needs_refresh = true
		return
	}

	items := cast(^[dynamic]string)state.data_cache[.BACKUPS_VIEW]

	// Header (hot pink + bold)
	header_x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT
	render_text_styled(screen, header_x, HEADER_TITLE_LINE + CONTENT_PADDING_TOP, "💾 Backups", TUI_PRIMARY, "", true)
	count_text := fmt.tprintf("%d backups available", len(items))
	render_text_styled(screen, header_x, HEADER_COUNT_LINE + CONTENT_PADDING_TOP, count_text, TUI_DIM)

	// Filter bar (shown when filter is active or has text)
	filter_bar_y := HEADER_COUNT_LINE + CONTENT_PADDING_TOP + 1
	has_filter := state.filter_active || len(state.filter_text) > 0
	list_start_offset := 0
	if has_filter {
		filter_str := string(state.filter_text[:])
		if state.filter_active {
			filter_display := fmt.tprintf("/ %s█  (%d/%d matches)", filter_str, len(state.filtered_indices), len(items))
			render_text_styled(screen, header_x, filter_bar_y, filter_display, TUI_SECONDARY, "", true)
		} else {
			filter_display := fmt.tprintf("/ %s  (%d/%d matches)", filter_str, len(state.filtered_indices), len(items))
			render_text_styled(screen, header_x, filter_bar_y, filter_display, TUI_DIM)
		}
		list_start_offset = 1
	}

	if has_filter && len(state.filtered_indices) > 0 {
		// Render filtered items
		visible_height := calculate_visible_height(state.terminal_height) - list_start_offset
		start := state.scroll_offset
		end := min(start + visible_height, len(state.filtered_indices))

		for idx in start..<end {
			y := calculate_list_item_y(idx - start) + list_start_offset
			original_idx := state.filtered_indices[idx]
			backup := items[original_idx]

			if idx == state.selected_index {
				text := fmt.tprintf("> %s", truncate_text(backup, max_text_width))
				render_text_styled(screen, header_x, y, text, TUI_PRIMARY, "", true)
			} else {
				text := fmt.tprintf("  %s", truncate_text(backup, max_text_width))
				render_text_styled(screen, header_x + SELECTION_PREFIX_WIDTH, y, text, TUI_MUTED)
			}
		}

		if len(state.filtered_indices) > visible_height {
			scroll_info := fmt.tprintf("Showing %d-%d of %d matches", start+1, end, len(state.filtered_indices))
			scroll_y := LIST_ITEM_START_LINE + visible_height + list_start_offset
			render_text_styled(screen, header_x, scroll_y, scroll_info, TUI_DIM)
		}
	} else if has_filter && len(state.filtered_indices) == 0 {
		no_match_y := LIST_ITEM_START_LINE + list_start_offset + 1
		render_text_styled(screen, header_x, no_match_y, "No matches found", TUI_DIM)
	} else if len(items) == 0 {
		render_text_styled(screen, header_x, LIST_ITEM_START_LINE + 1, "No backups found", TUI_DIM)
	} else {
		// List backups with scrolling (unfiltered)
		visible_height := calculate_visible_height(state.terminal_height)
		start := state.scroll_offset
		end := min(start + visible_height, len(items))

		for i in start..<end {
			y := calculate_list_item_y(i - start)
			backup := items[i]

			if i == state.selected_index {
				// Selected item: hot pink text + bold (NO background)
				text := fmt.tprintf("> %s", truncate_text(backup, max_text_width))
				render_text_styled(screen, header_x, y, text, TUI_PRIMARY, "", true)
			} else {
				// Normal item: muted gray text (indented by selection prefix width)
				text := fmt.tprintf("  %s", truncate_text(backup, max_text_width))
				render_text_styled(screen, header_x + SELECTION_PREFIX_WIDTH, y, text, TUI_MUTED)
			}
		}

		// Show scroll indicator if needed (dim gray)
		if len(items) > visible_height {
			scroll_info := fmt.tprintf("Showing %d-%d of %d", start+1, end, len(items))
			scroll_y := LIST_ITEM_START_LINE + visible_height
			render_text_styled(screen, header_x, scroll_y, scroll_info, TUI_DIM)
		}
	}

	// Footer with shortcuts (muted gray)
	footer_y := calculate_footer_y(state.terminal_height)
	if state.filter_active {
		render_text_styled(screen, header_x, footer_y, "Type to filter  Esc=Cancel  Enter=Accept  ↑/↓=Navigate", TUI_MUTED)
	} else if has_filter {
		render_text_styled(screen, header_x, footer_y, "/=Filter  c=Cleanup  Esc=Back  ↑/↓ or j/k=Navigate", TUI_MUTED)
	} else {
		render_text_styled(screen, header_x, footer_y, "/=Filter  c=Cleanup  Esc=Back  ↑/↓ or j/k=Navigate", TUI_MUTED)
	}
}

// ============================================================================
// Plugins View
// ============================================================================

// Render plugins view (placeholder) (PHASE 1: COLORED + BORDERED)
render_plugins_view :: proc(state: ^TUIState, screen: ^Screen) {
	// Draw outer border using calculated dimensions
	border_width, border_height := calculate_border_dimensions(state.terminal_width, state.terminal_height)
	render_box_styled(screen, BORDER_LEFT_WIDTH, BORDER_TOP_HEIGHT, border_width, border_height, TUI_BORDER_NORMAL)

	// Header (hot pink + bold)
	header_x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT
	render_text_styled(screen, header_x, HEADER_TITLE_LINE + CONTENT_PADDING_TOP, "🔌 Plugins", TUI_PRIMARY, "", true)
	render_text_styled(screen, header_x, HEADER_TITLE_LINE + CONTENT_PADDING_TOP + 2, "Plugin management system", TUI_MUTED)
	render_text_styled(screen, header_x, HEADER_TITLE_LINE + CONTENT_PADDING_TOP + 4, "(Future feature)", TUI_DIM)

	footer_y := calculate_footer_y(state.terminal_height)
	render_text_styled(screen, header_x, footer_y, "Esc=Back", TUI_MUTED)
}

// ============================================================================
// Settings View
// ============================================================================

// Render settings view with current configuration (PHASE 1: COLORED + BORDERED)
render_settings_view :: proc(state: ^TUIState, screen: ^Screen) {
	// Draw outer border using calculated dimensions
	border_width, border_height := calculate_border_dimensions(state.terminal_width, state.terminal_height)
	render_box_styled(screen, BORDER_LEFT_WIDTH, BORDER_TOP_HEIGHT, border_width, border_height, TUI_BORDER_NORMAL)

	// Header (hot pink + bold)
	header_x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT
	render_text_styled(screen, header_x, HEADER_TITLE_LINE + CONTENT_PADDING_TOP, "⚙️  Settings", TUI_PRIMARY, "", true)
	render_text_styled(screen, header_x, HEADER_COUNT_LINE + CONTENT_PADDING_TOP, "wayu Configuration", TUI_MUTED)

	// Display placeholder settings (actual values set by bridge)
	settings := []string{
		"Shell: (from bridge)",
		"Config Directory: (from bridge)",
		"Backup Retention: 5 (last 5 backups kept)",
		"Dry-run Mode: (from bridge)",
	}

	for setting, i in settings {
		render_text_styled(screen, header_x + 2, LIST_ITEM_START_LINE + i, setting, TUI_MUTED)
	}

	footer_y := calculate_footer_y(state.terminal_height)
	render_text_styled(screen, header_x, footer_y, "Esc=Back", TUI_MUTED)
}

// ============================================================================
// Helper Functions
// ============================================================================

// Clear cached data for a specific view (call after modifications)
clear_view_cache :: proc(state: ^TUIState, view: TUIView) {
	if state.data_cache[view] != nil {
		// Free the cached data
		items := cast(^[dynamic]string)state.data_cache[view]
		if items != nil {
			for item in items {
				delete(item)
			}
			delete(items^)
			free(items)
		}
		delete_key(&state.data_cache, view)
	}
}

// Get item count for current view (updated version with actual data)
get_view_item_count :: proc(state: ^TUIState) -> int {
	// When filter has results, use filtered count
	if len(state.filtered_indices) > 0 {
		return len(state.filtered_indices)
	}

	switch state.current_view {
	case .MAIN_MENU:
		return 7  // 7 menu items

	case .PATH_VIEW:
		if state.data_cache[.PATH_VIEW] != nil {
			items := cast(^[dynamic]string)state.data_cache[.PATH_VIEW]
			return len(items)
		}
		return 0

	case .ALIAS_VIEW:
		if state.data_cache[.ALIAS_VIEW] != nil {
			items := cast(^[dynamic]string)state.data_cache[.ALIAS_VIEW]
			return len(items)
		}
		return 0

	case .CONSTANTS_VIEW:
		if state.data_cache[.CONSTANTS_VIEW] != nil {
			items := cast(^[dynamic]string)state.data_cache[.CONSTANTS_VIEW]
			return len(items)
		}
		return 0

	case .BACKUPS_VIEW:
		if state.data_cache[.BACKUPS_VIEW] != nil {
			items := cast(^[dynamic]string)state.data_cache[.BACKUPS_VIEW]
			return len(items)
		}
		return 0

	case .COMPLETIONS_VIEW:
		if state.data_cache[.COMPLETIONS_VIEW] != nil {
			items := cast(^[dynamic]string)state.data_cache[.COMPLETIONS_VIEW]
			return len(items)
		}
		return 0

	case .PLUGINS_VIEW, .SETTINGS_VIEW:
		return 0  // No navigation in these views yet
	}
	return 0
}

// ============================================================================
// Detail Overlay
// ============================================================================

// Render a detail overlay centered on screen
render_detail_overlay :: proc(state: ^TUIState, screen: ^Screen) {
	if !state.show_detail do return

	// Calculate overlay dimensions
	overlay_width := min(state.terminal_width - 6, 60)
	overlay_height := min(len(state.detail_lines) + 5, state.terminal_height - 4)  // +5 for border, title, gap, footer, border
	overlay_x := (state.terminal_width - overlay_width) / 2
	overlay_y := (state.terminal_height - overlay_height) / 2

	// Fill interior with spaces to cover underlying content
	for dy in 1..<overlay_height-1 {
		for dx in 1..<overlay_width-1 {
			screen_set_cell(screen, overlay_x + dx, overlay_y + dy, Cell{char = ' '})
		}
	}

	// Draw border (hot pink for focused)
	render_box_styled(screen, overlay_x, overlay_y, overlay_width, overlay_height, TUI_BORDER_FOCUSED)

	// Title line (inside border, padded)
	content_x := overlay_x + 2
	title_y := overlay_y + 1
	render_text_styled(screen, content_x, title_y, state.detail_title, TUI_PRIMARY, "", true)

	// Detail lines
	max_lines := overlay_height - 5  // border top + title + gap + footer + border bottom
	for line, i in state.detail_lines {
		if i >= max_lines do break
		line_y := title_y + 2 + i  // +2 for gap after title
		// Truncate line if too wide
		max_line_width := overlay_width - 4  // 2 padding each side
		display_line := line
		if len(line) > max_line_width {
			display_line = line[:max_line_width]
		}
		render_text_styled(screen, content_x, line_y, display_line, TUI_MUTED)
	}

	// Footer hint
	footer_y := overlay_y + overlay_height - 2
	render_text_styled(screen, content_x, footer_y, "Press Esc or Enter to close", TUI_DIM)
}
