// tui_views.odin - TUI view rendering for all wayu configuration types
//
// Dashboard-style design with accent bars, dividers, no emoji.
// Inspired by terminal dashboard aesthetic (Dribbble #26767482).
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
import "core:mem"
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
// Shared View Header — Dashboard-style accent bar + title + count + divider
// ============================================================================

// Render a consistent view header across all data views.
// Layout:
//   ┃ TITLE           (accent bar + bold primary, ALL CAPS)
//   ┃ count_text      (accent bar + dim)
//   ────────────────  (divider line)
//
// Returns the border_width so callers can use it for dividers.
render_view_header :: proc(
	screen: ^Screen,
	state: ^TUIState,
	title: string,
	count_text: string,
	border_width: int,
) {
	header_x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT
	title_y := HEADER_TITLE_LINE + CONTENT_PADDING_TOP
	text_x := header_x + MENU_ACCENT_BAR_WIDTH + MENU_ACCENT_GAP

	// Accent bar ┃ spanning title + count lines
	screen_set_cell(screen, header_x, title_y, Cell{char = BOX_HEAVY_VERTICAL, fg = TUI_PRIMARY, bold = true})
	screen_set_cell(screen, header_x, title_y + 1, Cell{char = BOX_HEAVY_VERTICAL, fg = TUI_PRIMARY, bold = true})

	// Title (bold primary)
	render_text_styled(screen, text_x, title_y, title, TUI_PRIMARY, "", true)

	// Count line (dim)
	render_text_styled(screen, text_x, title_y + 1, count_text, TUI_DIM)

	// Horizontal divider below header
	divider_y := LIST_ITEM_START_LINE
	divider_width := border_width - CONTENT_PADDING_LEFT - 2
	for dx in 0..<divider_width {
		screen_set_cell(screen, header_x + dx, divider_y, Cell{char = BOX_HORIZONTAL, fg = TUI_DIVIDER})
	}
}

// Render a loading state for views whose data hasn't arrived yet.
render_view_loading :: proc(screen: ^Screen, state: ^TUIState, title: string, border_width: int) {
	render_view_header(screen, state, title, "Loading...", border_width)
	header_x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT
	text_x := header_x + MENU_ACCENT_BAR_WIDTH + MENU_ACCENT_GAP
	render_text_styled(screen, text_x, LIST_ITEM_START_LINE + 2, "Loading...", TUI_DIM)
	state.needs_refresh = true
}

// ============================================================================
// Shared Filter Bar
// ============================================================================

// Render the inline filter bar. Returns the list_start_offset (0 if no filter, 1 if filter shown).
render_filter_bar :: proc(screen: ^Screen, state: ^TUIState, item_count: int) -> int {
	has_filter := state.filter_active || len(state.filter_text) > 0
	if !has_filter do return 0

	header_x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT
	// Filter bar goes right after the divider line
	filter_bar_y := LIST_ITEM_START_LINE + 1
	filter_str := string(state.filter_text[:])

	if state.filter_active {
		filter_display := fmt.tprintf("/ %s█  (%d/%d matches)", filter_str, len(state.filtered_indices), item_count)
		render_text_styled(screen, header_x, filter_bar_y, filter_display, TUI_SECONDARY, "", true)
	} else {
		filter_display := fmt.tprintf("/ %s  (%d/%d matches)", filter_str, len(state.filtered_indices), item_count)
		render_text_styled(screen, header_x, filter_bar_y, filter_display, TUI_DIM)
	}
	return 1
}

// ============================================================================
// Shared List Item — Single-column with accent bar selection
// ============================================================================

// Render a single list item with ┃ accent bar for selected state.
// text_x is calculated from header_x + accent bar + gap.
render_list_item :: proc(screen: ^Screen, header_x, y: int, text: string, max_width: int, is_selected: bool) {
	text_x := header_x + MENU_ACCENT_BAR_WIDTH + MENU_ACCENT_GAP
	display := truncate_text(text, max_width)

	if is_selected {
		// Selected: accent bar ┃ + bold primary text
		screen_set_cell(screen, header_x, y, Cell{char = BOX_HEAVY_VERTICAL, fg = TUI_PRIMARY, bold = true})
		render_text_styled(screen, text_x, y, display, TUI_PRIMARY, "", true)
	} else {
		// Normal: no accent bar, muted text at same x offset
		render_text_styled(screen, text_x, y, display, TUI_MUTED)
	}
}

// ============================================================================
// Shared Footer — Compact keyboard shortcuts
// ============================================================================

// Standard footer for filterable data views
FOOTER_FILTER_ACTIVE :: "Type to filter   Esc Cancel   Enter Accept   j/k Navigate"
FOOTER_DATA_VIEW     :: "/ Filter   a Add   d Delete   h Back   l Enter   j/k Navigate"
FOOTER_READONLY_VIEW :: "/ Filter   h Back   l Enter   j/k Navigate"
FOOTER_BACKUP_VIEW   :: "/ Filter   c Cleanup   h Back   j/k Navigate"
FOOTER_STATIC_VIEW   :: "h Back"

render_data_footer :: proc(screen: ^Screen, state: ^TUIState, footer_text: string) {
	header_x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT
	footer_y := calculate_footer_y(state.terminal_height)

	if state.filter_active {
		render_text_styled(screen, header_x, footer_y, FOOTER_FILTER_ACTIVE, TUI_DIM)
	} else {
		render_text_styled(screen, header_x, footer_y, footer_text, TUI_DIM)
	}
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
// Uses ┃ accent bar for selected items instead of "> " prefix.
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

	// Text starts after accent bar + gap
	text_x := x + MENU_ACCENT_BAR_WIDTH + MENU_ACCENT_GAP
	value_x := text_x + key_col_width + COLUMN_GAP

	if is_selected {
		// Selected: accent bar ┃ + bold primary key + bold primary value
		screen_set_cell(screen, x, y, Cell{char = BOX_HEAVY_VERTICAL, fg = TUI_PRIMARY, bold = true})
		render_text_styled(screen, text_x, y, truncated_key, TUI_PRIMARY, "", true)
		if len(truncated_value) > 0 {
			render_text_styled(screen, value_x, y, truncated_value, TUI_PRIMARY, "", true)
		}
	} else {
		// Normal: no accent bar, muted key + dim value
		render_text_styled(screen, text_x, y, truncated_key, TUI_MUTED)
		if len(truncated_value) > 0 {
			render_text_styled(screen, value_x, y, truncated_value, TUI_DIM)
		}
	}
}

// Render column header row with labels and divider line below.
// Layout:
//   KEY_LABEL   VALUE_LABEL
//   ─────────────────────── (divider)
render_column_header :: proc(screen: ^Screen, x, y: int, key_label, value_label: string, key_col_width, border_width: int) {
	text_x := x + MENU_ACCENT_BAR_WIDTH + MENU_ACCENT_GAP
	value_x := text_x + key_col_width + COLUMN_GAP

	render_text_styled(screen, text_x, y, key_label, TUI_DIM)
	render_text_styled(screen, value_x, y, value_label, TUI_DIM)

	// Divider line below column headers
	divider_y := y + 1
	divider_width := border_width - CONTENT_PADDING_LEFT - 2
	for dx in 0..<divider_width {
		screen_set_cell(screen, x + dx, divider_y, Cell{char = BOX_HORIZONTAL, fg = TUI_DIVIDER})
	}
}

// ============================================================================
// PATH View
// ============================================================================

render_path_view :: proc(state: ^TUIState, screen: ^Screen) {
	border_width, border_height := calculate_border_dimensions(state.terminal_width, state.terminal_height)
	max_text_width := calculate_content_width(border_width)
	render_box_styled(screen, BORDER_LEFT_WIDTH, BORDER_TOP_HEIGHT, border_width, border_height, TUI_BORDER_FOCUSED)

	header_x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT

	if state.data_cache[.PATH_VIEW] == nil {
		render_view_loading(screen, state, "PATH CONFIGURATION", border_width)
		return
	}

	items := cast(^[dynamic]string)state.data_cache[.PATH_VIEW]
	count_text := fmt.tprintf("%d entries", len(items))
	render_view_header(screen, state, "PATH CONFIGURATION", count_text, border_width)

	// Filter bar (after divider)
	has_filter := state.filter_active || len(state.filter_text) > 0
	list_start_offset := render_filter_bar(screen, state, len(items))

	// Content area starts after divider + filter
	content_start := LIST_ITEM_START_LINE + 1 + list_start_offset  // +1 for divider

	if has_filter && len(state.filtered_indices) > 0 {
		visible_height := calculate_visible_height(state.terminal_height) - list_start_offset - 1
		start := state.scroll_offset
		end := min(start + visible_height, len(state.filtered_indices))

		for idx in start..<end {
			y := content_start + (idx - start)
			original_idx := state.filtered_indices[idx]
			render_list_item(screen, header_x, y, items[original_idx], max_text_width, idx == state.selected_index)
		}

		if len(state.filtered_indices) > visible_height {
			scroll_info := fmt.tprintf("Showing %d-%d of %d matches", start+1, end, len(state.filtered_indices))
			render_text_styled(screen, header_x, content_start + visible_height, scroll_info, TUI_DIM)
		}
	} else if has_filter && len(state.filtered_indices) == 0 {
		render_text_styled(screen, header_x + MENU_ACCENT_BAR_WIDTH + MENU_ACCENT_GAP, content_start + 1, "No matches found", TUI_DIM)
	} else if len(items) == 0 {
		render_text_styled(screen, header_x + MENU_ACCENT_BAR_WIDTH + MENU_ACCENT_GAP, content_start + 1, "No PATH entries found", TUI_DIM)
	} else {
		visible_height := calculate_visible_height(state.terminal_height) - 1
		start := state.scroll_offset
		end := min(start + visible_height, len(items))

		for i in start..<end {
			y := content_start + (i - start)
			render_list_item(screen, header_x, y, items[i], max_text_width, i == state.selected_index)
		}

		if len(items) > visible_height {
			scroll_info := fmt.tprintf("Showing %d-%d of %d", start+1, end, len(items))
			render_text_styled(screen, header_x, content_start + visible_height, scroll_info, TUI_DIM)
		}
	}

	render_data_footer(screen, state, FOOTER_DATA_VIEW)
}

// ============================================================================
// Alias View
// ============================================================================

render_alias_view :: proc(state: ^TUIState, screen: ^Screen) {
	border_width, border_height := calculate_border_dimensions(state.terminal_width, state.terminal_height)
	max_text_width := calculate_content_width(border_width)
	render_box_styled(screen, BORDER_LEFT_WIDTH, BORDER_TOP_HEIGHT, border_width, border_height, TUI_BORDER_FOCUSED)

	header_x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT

	if state.data_cache[.ALIAS_VIEW] == nil {
		render_view_loading(screen, state, "ALIASES", border_width)
		return
	}

	items := cast(^[dynamic]string)state.data_cache[.ALIAS_VIEW]
	count_text := fmt.tprintf("%d aliases", len(items))
	render_view_header(screen, state, "ALIASES", count_text, border_width)

	// Calculate table column widths
	key_col_width := calculate_key_column_width(items, max_text_width)
	value_col_width := max_text_width - key_col_width - COLUMN_GAP
	if value_col_width < 1 {
		value_col_width = 1
	}

	has_filter := state.filter_active || len(state.filter_text) > 0
	list_start_offset := render_filter_bar(screen, state, len(items))

	// Content area starts after divider + filter
	content_start := LIST_ITEM_START_LINE + 1 + list_start_offset

	// Column header row (when there are items to show)
	show_items := (has_filter && len(state.filtered_indices) > 0) || (!has_filter && len(items) > 0)
	col_header_offset := 0
	if show_items {
		render_column_header(screen, header_x, content_start, "ALIAS", "COMMAND", key_col_width, border_width)
		col_header_offset = 2  // header line + divider line
	}

	data_start := content_start + col_header_offset

	if has_filter && len(state.filtered_indices) > 0 {
		visible_height := calculate_visible_height(state.terminal_height) - list_start_offset - 1 - col_header_offset
		start := state.scroll_offset
		end := min(start + visible_height, len(state.filtered_indices))

		for idx in start..<end {
			y := data_start + (idx - start)
			original_idx := state.filtered_indices[idx]
			render_table_row(screen, header_x, y, items[original_idx], key_col_width, value_col_width, idx == state.selected_index)
		}

		if len(state.filtered_indices) > visible_height {
			scroll_info := fmt.tprintf("Showing %d-%d of %d matches", start+1, end, len(state.filtered_indices))
			render_text_styled(screen, header_x, data_start + visible_height, scroll_info, TUI_DIM)
		}
	} else if has_filter && len(state.filtered_indices) == 0 {
		render_text_styled(screen, header_x + MENU_ACCENT_BAR_WIDTH + MENU_ACCENT_GAP, data_start + 1, "No matches found", TUI_DIM)
	} else if len(items) == 0 {
		render_text_styled(screen, header_x + MENU_ACCENT_BAR_WIDTH + MENU_ACCENT_GAP, content_start + 1, "No aliases found", TUI_DIM)
	} else {
		visible_height := calculate_visible_height(state.terminal_height) - 1 - col_header_offset
		start := state.scroll_offset
		end := min(start + visible_height, len(items))

		for i in start..<end {
			y := data_start + (i - start)
			render_table_row(screen, header_x, y, items[i], key_col_width, value_col_width, i == state.selected_index)
		}

		if len(items) > visible_height {
			scroll_info := fmt.tprintf("Showing %d-%d of %d", start+1, end, len(items))
			render_text_styled(screen, header_x, data_start + visible_height, scroll_info, TUI_DIM)
		}
	}

	render_data_footer(screen, state, FOOTER_DATA_VIEW)
}

// ============================================================================
// Constants View
// ============================================================================

render_constants_view :: proc(state: ^TUIState, screen: ^Screen) {
	border_width, border_height := calculate_border_dimensions(state.terminal_width, state.terminal_height)
	max_text_width := calculate_content_width(border_width)
	render_box_styled(screen, BORDER_LEFT_WIDTH, BORDER_TOP_HEIGHT, border_width, border_height, TUI_BORDER_FOCUSED)

	header_x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT

	if state.data_cache[.CONSTANTS_VIEW] == nil {
		render_view_loading(screen, state, "ENVIRONMENT CONSTANTS", border_width)
		return
	}

	items := cast(^[dynamic]string)state.data_cache[.CONSTANTS_VIEW]
	count_text := fmt.tprintf("%d constants", len(items))
	render_view_header(screen, state, "ENVIRONMENT CONSTANTS", count_text, border_width)

	key_col_width := calculate_key_column_width(items, max_text_width)
	value_col_width := max_text_width - key_col_width - COLUMN_GAP
	if value_col_width < 1 {
		value_col_width = 1
	}

	has_filter := state.filter_active || len(state.filter_text) > 0
	list_start_offset := render_filter_bar(screen, state, len(items))

	content_start := LIST_ITEM_START_LINE + 1 + list_start_offset

	show_items := (has_filter && len(state.filtered_indices) > 0) || (!has_filter && len(items) > 0)
	col_header_offset := 0
	if show_items {
		render_column_header(screen, header_x, content_start, "NAME", "VALUE", key_col_width, border_width)
		col_header_offset = 2
	}

	data_start := content_start + col_header_offset

	if has_filter && len(state.filtered_indices) > 0 {
		visible_height := calculate_visible_height(state.terminal_height) - list_start_offset - 1 - col_header_offset
		start := state.scroll_offset
		end := min(start + visible_height, len(state.filtered_indices))

		for idx in start..<end {
			y := data_start + (idx - start)
			original_idx := state.filtered_indices[idx]
			render_table_row(screen, header_x, y, items[original_idx], key_col_width, value_col_width, idx == state.selected_index)
		}

		if len(state.filtered_indices) > visible_height {
			scroll_info := fmt.tprintf("Showing %d-%d of %d matches", start+1, end, len(state.filtered_indices))
			render_text_styled(screen, header_x, data_start + visible_height, scroll_info, TUI_DIM)
		}
	} else if has_filter && len(state.filtered_indices) == 0 {
		render_text_styled(screen, header_x + MENU_ACCENT_BAR_WIDTH + MENU_ACCENT_GAP, data_start + 1, "No matches found", TUI_DIM)
	} else if len(items) == 0 {
		render_text_styled(screen, header_x + MENU_ACCENT_BAR_WIDTH + MENU_ACCENT_GAP, content_start + 1, "No constants found", TUI_DIM)
	} else {
		visible_height := calculate_visible_height(state.terminal_height) - 1 - col_header_offset
		start := state.scroll_offset
		end := min(start + visible_height, len(items))

		for i in start..<end {
			y := data_start + (i - start)
			render_table_row(screen, header_x, y, items[i], key_col_width, value_col_width, i == state.selected_index)
		}

		if len(items) > visible_height {
			scroll_info := fmt.tprintf("Showing %d-%d of %d", start+1, end, len(items))
			render_text_styled(screen, header_x, data_start + visible_height, scroll_info, TUI_DIM)
		}
	}

	render_data_footer(screen, state, FOOTER_DATA_VIEW)
}

// ============================================================================
// Completions View
// ============================================================================

render_completions_view :: proc(state: ^TUIState, screen: ^Screen) {
	border_width, border_height := calculate_border_dimensions(state.terminal_width, state.terminal_height)
	max_text_width := calculate_content_width(border_width)
	render_box_styled(screen, BORDER_LEFT_WIDTH, BORDER_TOP_HEIGHT, border_width, border_height, TUI_BORDER_FOCUSED)

	header_x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT

	if state.data_cache[.COMPLETIONS_VIEW] == nil {
		render_view_loading(screen, state, "COMPLETIONS", border_width)
		return
	}

	items := cast(^[dynamic]string)state.data_cache[.COMPLETIONS_VIEW]
	count_text := fmt.tprintf("%d completion scripts", len(items))
	render_view_header(screen, state, "COMPLETIONS", count_text, border_width)

	has_filter := state.filter_active || len(state.filter_text) > 0
	list_start_offset := render_filter_bar(screen, state, len(items))

	content_start := LIST_ITEM_START_LINE + 1 + list_start_offset

	if has_filter && len(state.filtered_indices) > 0 {
		visible_height := calculate_visible_height(state.terminal_height) - list_start_offset - 1
		start := state.scroll_offset
		end := min(start + visible_height, len(state.filtered_indices))

		for idx in start..<end {
			y := content_start + (idx - start)
			original_idx := state.filtered_indices[idx]
			render_list_item(screen, header_x, y, items[original_idx], max_text_width, idx == state.selected_index)
		}

		if len(state.filtered_indices) > visible_height {
			scroll_info := fmt.tprintf("Showing %d-%d of %d matches", start+1, end, len(state.filtered_indices))
			render_text_styled(screen, header_x, content_start + visible_height, scroll_info, TUI_DIM)
		}
	} else if has_filter && len(state.filtered_indices) == 0 {
		render_text_styled(screen, header_x + MENU_ACCENT_BAR_WIDTH + MENU_ACCENT_GAP, content_start + 1, "No matches found", TUI_DIM)
	} else if len(items) == 0 {
		text_x := header_x + MENU_ACCENT_BAR_WIDTH + MENU_ACCENT_GAP
		render_text_styled(screen, text_x, content_start + 1, "No completion scripts found", TUI_DIM)
		render_text_styled(screen, text_x, content_start + 3, "Add completions with: wayu completions add <name> <file>", TUI_MUTED)
	} else {
		visible_height := calculate_visible_height(state.terminal_height) - 1
		start := state.scroll_offset
		end := min(start + visible_height, len(items))

		for i in start..<end {
			y := content_start + (i - start)
			render_list_item(screen, header_x, y, items[i], max_text_width, i == state.selected_index)
		}

		if len(items) > visible_height {
			scroll_info := fmt.tprintf("Showing %d-%d of %d", start+1, end, len(items))
			render_text_styled(screen, header_x, content_start + visible_height, scroll_info, TUI_DIM)
		}
	}

	render_data_footer(screen, state, FOOTER_READONLY_VIEW)
}

// ============================================================================
// Backups View
// ============================================================================

render_backups_view :: proc(state: ^TUIState, screen: ^Screen) {
	border_width, border_height := calculate_border_dimensions(state.terminal_width, state.terminal_height)
	max_text_width := calculate_content_width(border_width)
	render_box_styled(screen, BORDER_LEFT_WIDTH, BORDER_TOP_HEIGHT, border_width, border_height, TUI_BORDER_FOCUSED)

	header_x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT

	if state.data_cache[.BACKUPS_VIEW] == nil {
		render_view_loading(screen, state, "BACKUPS", border_width)
		return
	}

	items := cast(^[dynamic]string)state.data_cache[.BACKUPS_VIEW]
	count_text := fmt.tprintf("%d backups available", len(items))
	render_view_header(screen, state, "BACKUPS", count_text, border_width)

	has_filter := state.filter_active || len(state.filter_text) > 0
	list_start_offset := render_filter_bar(screen, state, len(items))

	content_start := LIST_ITEM_START_LINE + 1 + list_start_offset

	if has_filter && len(state.filtered_indices) > 0 {
		visible_height := calculate_visible_height(state.terminal_height) - list_start_offset - 1
		start := state.scroll_offset
		end := min(start + visible_height, len(state.filtered_indices))

		for idx in start..<end {
			y := content_start + (idx - start)
			original_idx := state.filtered_indices[idx]
			render_list_item(screen, header_x, y, items[original_idx], max_text_width, idx == state.selected_index)
		}

		if len(state.filtered_indices) > visible_height {
			scroll_info := fmt.tprintf("Showing %d-%d of %d matches", start+1, end, len(state.filtered_indices))
			render_text_styled(screen, header_x, content_start + visible_height, scroll_info, TUI_DIM)
		}
	} else if has_filter && len(state.filtered_indices) == 0 {
		render_text_styled(screen, header_x + MENU_ACCENT_BAR_WIDTH + MENU_ACCENT_GAP, content_start + 1, "No matches found", TUI_DIM)
	} else if len(items) == 0 {
		render_text_styled(screen, header_x + MENU_ACCENT_BAR_WIDTH + MENU_ACCENT_GAP, content_start + 1, "No backups found", TUI_DIM)
	} else {
		visible_height := calculate_visible_height(state.terminal_height) - 1
		start := state.scroll_offset
		end := min(start + visible_height, len(items))

		for i in start..<end {
			y := content_start + (i - start)
			render_list_item(screen, header_x, y, items[i], max_text_width, i == state.selected_index)
		}

		if len(items) > visible_height {
			scroll_info := fmt.tprintf("Showing %d-%d of %d", start+1, end, len(items))
			render_text_styled(screen, header_x, content_start + visible_height, scroll_info, TUI_DIM)
		}
	}

	render_data_footer(screen, state, FOOTER_BACKUP_VIEW)
}

// ============================================================================
// Plugins View
// ============================================================================

render_plugins_view :: proc(state: ^TUIState, screen: ^Screen) {
	border_width, border_height := calculate_border_dimensions(state.terminal_width, state.terminal_height)
	render_box_styled(screen, BORDER_LEFT_WIDTH, BORDER_TOP_HEIGHT, border_width, border_height, TUI_BORDER_NORMAL)

	render_view_header(screen, state, "PLUGINS", "Plugin management system", border_width)

	header_x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT
	text_x := header_x + MENU_ACCENT_BAR_WIDTH + MENU_ACCENT_GAP
	content_start := LIST_ITEM_START_LINE + 2
	render_text_styled(screen, text_x, content_start, "(Future feature)", TUI_DIM)

	render_data_footer(screen, state, FOOTER_STATIC_VIEW)
}

// ============================================================================
// Settings View
// ============================================================================

render_settings_view :: proc(state: ^TUIState, screen: ^Screen) {
	border_width, border_height := calculate_border_dimensions(state.terminal_width, state.terminal_height)
	render_box_styled(screen, BORDER_LEFT_WIDTH, BORDER_TOP_HEIGHT, border_width, border_height, TUI_BORDER_NORMAL)

	render_view_header(screen, state, "SETTINGS", "wayu Configuration", border_width)

	header_x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT
	text_x := header_x + MENU_ACCENT_BAR_WIDTH + MENU_ACCENT_GAP

	settings := []string{
		"Shell: (from bridge)",
		"Config Directory: (from bridge)",
		"Backup Retention: 5 (last 5 backups kept)",
		"Dry-run Mode: (from bridge)",
	}

	content_start := LIST_ITEM_START_LINE + 2
	for setting, i in settings {
		render_text_styled(screen, text_x, content_start + i, setting, TUI_MUTED)
	}

	render_data_footer(screen, state, FOOTER_STATIC_VIEW)
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
// Add Form Overlay
// ============================================================================

// Render the add-record modal overlay when state.add_form.active is true.
// Layout (example for ALIAS):
//
//   ╭──────────────────────────────────╮
//   ┃ ADD ALIAS
//
//     NAME
//     > ll█                          ← active field: orange + fake cursor
//
//     COMMAND
//     > ls -la                       ← inactive field: dim
//
//     Error: message here            ← TUI_ERROR, only when error_message != ""
//
//     [ Esc CANCEL ]   [ Enter ADD ] ← dim / orange+bold
//   ╰──────────────────────────────────╯
//
// Field heights: 1-field form = title + 1 field block + error + buttons + borders
//               2-field form = title + 2 field blocks + error + buttons + borders
render_add_form_overlay :: proc(state: ^TUIState, screen: ^Screen) {
	if !state.add_form.active do return

	// Arena for all fmt.tprintf scratch strings in this proc — freed on return.
	// Stack-allocated: no explicit destroy needed; memory reclaimed when proc exits.
	scratch_buf: [2048]byte
	scratch: mem.Arena
	mem.arena_init(&scratch, scratch_buf[:])
	context.allocator = mem.arena_allocator(&scratch)

	form := &state.add_form

	// Determine overlay height:
	//   1 top border + 1 title + 1 blank + (2 per field: label + input) * field_count
	//   + 1 blank + 1 error row (always reserved) + 1 blank + 1 button row + 1 bottom border
	field_rows := form.field_count * 2   // label + input per field
	overlay_height := 1 + 1 + 1 + field_rows + 1 + 1 + 1 + 1 + 1  // = 9 for 1-field, 11 for 2-field

	overlay_width := min(state.terminal_width - 8, 56)
	if overlay_width < 30 {
		overlay_width = 30
	}
	overlay_x := (state.terminal_width - overlay_width) / 2
	overlay_y := (state.terminal_height - overlay_height) / 2

	// Fill interior with spaces to erase underlying content
	for dy in 1..<overlay_height-1 {
		for dx in 1..<overlay_width-1 {
			screen_set_cell(screen, overlay_x + dx, overlay_y + dy, Cell{char = ' '})
		}
	}

	// Border
	render_box_styled(screen, overlay_x, overlay_y, overlay_width, overlay_height, TUI_BORDER_FOCUSED)

	content_x := overlay_x + 2
	max_input_width := overlay_width - 6  // 2 border + 2 content + 2 padding

	// Title: ┃ ADD {VIEW}
	title_y := overlay_y + 1
	view_name: string
	switch form.view {
	case .PATH_VIEW:      view_name = "PATH"
	case .ALIAS_VIEW:     view_name = "ALIAS"
	case .CONSTANTS_VIEW: view_name = "CONSTANT"
	case .MAIN_MENU, .COMPLETIONS_VIEW, .BACKUPS_VIEW, .PLUGINS_VIEW, .SETTINGS_VIEW:
		view_name = "ENTRY"
	}
	title_text := fmt.tprintf("ADD %s", view_name)
	screen_set_cell(screen, content_x, title_y, Cell{char = BOX_HEAVY_VERTICAL, fg = TUI_PRIMARY, bold = true})
	render_text_styled(screen, content_x + MENU_ACCENT_BAR_WIDTH + 1, title_y, title_text, TUI_PRIMARY, "", true)

	// Focus indices: 0..field_count-1 = fields, field_count = CANCEL, field_count+1 = ADD
	cancel_idx := form.field_count
	add_idx    := form.field_count + 1

	// Fields
	field_start_y := title_y + 2  // blank line after title
	for fi in 0..<form.field_count {
		label: string
		if fi == 0 {
			label = form.label_0
		} else {
			label = form.label_1
		}
		input_buf: ^[dynamic]u8
		if fi == 0 {
			input_buf = &form.input_0
		} else {
			input_buf = &form.input_1
		}
		is_focused := fi == form.field_index

		label_y := field_start_y + fi * 2
		input_y := label_y + 1

		// Label — orange only when this field is focused
		label_fg: string
		if is_focused {
			label_fg = TUI_ORANGE
		} else {
			label_fg = TUI_DIM
		}
		render_text_styled(screen, content_x + 2, label_y, label, label_fg, "", is_focused)

		// Input line: "> text█" (focused) or "> text" (unfocused)
		input_str := string(input_buf[:])
		display_max := max_input_width - 2  // ">" + space
		if display_max < 1 {
			display_max = 1
		}
		truncated := truncate_text(input_str, display_max)
		input_display: string
		if is_focused {
			input_display = fmt.tprintf("> %s\u2588", truncated)  // U+2588 FULL BLOCK as cursor
		} else {
			input_display = fmt.tprintf("> %s", truncated)
		}
		input_fg: string
		if is_focused {
			input_fg = TUI_ORANGE
		} else {
			input_fg = TUI_DIM
		}
		render_text_styled(screen, content_x + 2, input_y, input_display, input_fg, "", is_focused)
	}

	// Error line (always 1 row reserved; shown only when non-empty)
	error_y := field_start_y + form.field_count * 2 + 1
	if len(form.error_message) > 0 {
		err_display := truncate_text(form.error_message, overlay_width - 6)
		render_text_styled(screen, content_x + 2, error_y, err_display, TUI_ERROR)
	}

	// Button row — each button is orange+bold only when focused, dim otherwise
	button_y     := error_y + 2
	cancel_label :: "Esc CANCEL"
	add_label    :: "Enter ADD"
	button_gap   :: 2
	right_edge   := overlay_x + overlay_width - 3
	add_btn_w    := len(add_label) + 4    // "[ " + label + " ]"
	cancel_btn_w := len(cancel_label) + 4
	add_start    := right_edge - add_btn_w
	cancel_start := add_start - button_gap - cancel_btn_w

	cancel_focused := form.field_index == cancel_idx
	add_focused    := form.field_index == add_idx

	cancel_fg: string
	if cancel_focused {
		cancel_fg = TUI_ORANGE
	} else {
		cancel_fg = TUI_DIM
	}
	add_fg: string
	if add_focused {
		add_fg = TUI_ORANGE
	} else {
		add_fg = TUI_DIM
	}

	// CANCEL button
	screen_set_cell(screen, cancel_start, button_y, Cell{char = '[', fg = cancel_fg, bold = cancel_focused})
	screen_set_cell(screen, cancel_start + 1, button_y, Cell{char = ' ', fg = cancel_fg})
	render_text_styled(screen, cancel_start + 2, button_y, cancel_label, cancel_fg, "", cancel_focused)
	screen_set_cell(screen, cancel_start + cancel_btn_w - 2, button_y, Cell{char = ' ', fg = cancel_fg})
	screen_set_cell(screen, cancel_start + cancel_btn_w - 1, button_y, Cell{char = ']', fg = cancel_fg, bold = cancel_focused})

	// ADD button
	screen_set_cell(screen, add_start, button_y, Cell{char = '[', fg = add_fg, bold = add_focused})
	screen_set_cell(screen, add_start + 1, button_y, Cell{char = ' ', fg = add_fg})
	render_text_styled(screen, add_start + 2, button_y, add_label, add_fg, "", add_focused)
	screen_set_cell(screen, add_start + add_btn_w - 2, button_y, Cell{char = ' ', fg = add_fg})
	screen_set_cell(screen, add_start + add_btn_w - 1, button_y, Cell{char = ']', fg = add_fg, bold = add_focused})

	_ = add_idx  // suppress unused warning
}

// ============================================================================
// Detail Overlay
// ============================================================================

// Render a detail overlay centered on screen with accent bar on title
render_detail_overlay :: proc(state: ^TUIState, screen: ^Screen) {
	if !state.show_detail do return

	// Calculate overlay dimensions
	// +7 = 1 top border + 1 title + 1 divider gap + content + 2 blank rows before buttons + 1 button row + 1 bottom border
	overlay_width := min(state.terminal_width - 6, 60)
	overlay_height := min(len(state.detail_lines) + 7, state.terminal_height - 4)
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

	// Title line with accent bar
	content_x := overlay_x + 2
	title_y := overlay_y + 1
	screen_set_cell(screen, content_x, title_y, Cell{char = BOX_HEAVY_VERTICAL, fg = TUI_PRIMARY, bold = true})
	render_text_styled(screen, content_x + MENU_ACCENT_BAR_WIDTH + 1, title_y, state.detail_title, TUI_PRIMARY, "", true)

	// Detail lines
	max_lines := overlay_height - 6
	for line, i in state.detail_lines {
		if i >= max_lines do break
		line_y := title_y + 2 + i
		max_line_width := overlay_width - 4
		display_line := line
		if len(line) > max_line_width {
			display_line = line[:max_line_width]
		}
		render_text_styled(screen, content_x + 2, line_y, display_line, TUI_MUTED)
	}

	// Footer hint — one row above the bottom border; extra blank rows sit between content and buttons
	footer_y := overlay_y + overlay_height - 3
	if state.confirm_delete_pending {
		// Bordered box buttons, right-aligned within the overlay
		// Layout: ... [ Esc CANCEL ]  [ y DELETE ] |
		cancel_label :: "Esc CANCEL"   // 10 chars
		delete_label :: "y DELETE"     //  8 chars
		button_gap   :: 2              // spaces between buttons

		// Right-align: position DELETE button first, then CANCEL to its left
		// Each button is: [ + space + label + space + ] = len(label) + 4
		right_edge    := overlay_x + overlay_width - 3
		delete_btn_w  := len(delete_label) + 4
		cancel_btn_w  := len(cancel_label) + 4
		delete_start  := right_edge - delete_btn_w
		cancel_start  := delete_start - button_gap - cancel_btn_w

		// Button colors driven by focus state
		// Focused button: TUI_ORANGE (bright orange), bold. Unfocused: TUI_DIM.
		cancel_fg := TUI_ORANGE if !state.confirm_delete_focused_delete else TUI_DIM
		delete_fg := TUI_ORANGE if  state.confirm_delete_focused_delete else TUI_DIM
		cancel_bold := !state.confirm_delete_focused_delete
		delete_bold :=  state.confirm_delete_focused_delete

		// Render CANCEL button
		screen_set_cell(screen, cancel_start, footer_y, Cell{char = '[', fg = cancel_fg, bold = cancel_bold})
		screen_set_cell(screen, cancel_start + 1, footer_y, Cell{char = ' ', fg = cancel_fg})
		render_text_styled(screen, cancel_start + 2, footer_y, cancel_label, cancel_fg, "", cancel_bold)
		screen_set_cell(screen, cancel_start + cancel_btn_w - 2, footer_y, Cell{char = ' ', fg = cancel_fg})
		screen_set_cell(screen, cancel_start + cancel_btn_w - 1, footer_y, Cell{char = ']', fg = cancel_fg, bold = cancel_bold})

		// Render DELETE button
		screen_set_cell(screen, delete_start, footer_y, Cell{char = '[', fg = delete_fg, bold = delete_bold})
		screen_set_cell(screen, delete_start + 1, footer_y, Cell{char = ' ', fg = delete_fg})
		render_text_styled(screen, delete_start + 2, footer_y, delete_label, delete_fg, "", delete_bold)
		screen_set_cell(screen, delete_start + delete_btn_w - 2, footer_y, Cell{char = ' ', fg = delete_fg})
		screen_set_cell(screen, delete_start + delete_btn_w - 1, footer_y, Cell{char = ']', fg = delete_fg, bold = delete_bold})
	} else {
		render_text_styled(screen, content_x, footer_y, "Esc or Enter to close", TUI_DIM)
	}
}
