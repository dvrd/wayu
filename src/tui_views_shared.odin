package wayu

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"

// ============================================================================
// Source Counter Helper
// ============================================================================

// Count entries by source from item list (items have glyph prefixes)
// Returns (wayu_active, wayu_inactive, external, shadowed)
count_entries_by_source :: proc(items: ^[dynamic]string) -> (int, int, int, int) {
	wayu_active := 0
	wayu_inactive := 0
	external := 0
	shadowed := 0

	for item in items {
		if len(item) == 0 { continue }

		// Skip separator lines (contain "───")
		if strings.contains(item, "───") { continue }

		// Check glyph prefix
		// Glyphs are Unicode chars with ANSI codes:
		// "●" (U+25CF) = wayu active
		// "⚠" (U+26A0) = wayu inactive
		// "○" (U+25CB) = external
		// "♦" (U+2666) = shadowed
		//
		// But they're prefixed with color codes like "\x1b[38;2;R;G;Bm"
		// Look for the unicode chars directly

		if strings.contains(item, "●") {
			wayu_active += 1
		} else if strings.contains(item, "⚠") {
			wayu_inactive += 1
		} else if strings.contains(item, "○") {
			external += 1
		} else if strings.contains(item, "♦") {
			shadowed += 1
		}
	}

	return wayu_active, wayu_inactive, external, shadowed
}

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

	// Title (bold primary) — truncate if too wide for narrow terminals
	max_title_width := border_width - (text_x - header_x) - BORDER_RIGHT_WIDTH - 1
	title_display := truncate_text(title, max_title_width)
	render_text_styled(screen, text_x, title_y, title_display, TUI_PRIMARY, "", true)

	// Count line (dim) — truncate if too wide
	count_display := truncate_text(count_text, max_title_width)
	render_text_styled(screen, text_x, title_y + 1, count_display, TUI_DIM)

	divider_y := LIST_ITEM_START_LINE
	divider_width := max(0, border_width - CONTENT_PADDING_LEFT - 2)
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
	has_filter := has_any_filter(state)
	if !has_filter do return 0

	header_x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT
	// Filter bar goes right after the divider line
	filter_bar_y := LIST_ITEM_START_LINE + 1
	filter_str := string(state.filter_text[:])

	max_filter_width := state.terminal_width - BORDER_LEFT_WIDTH - CONTENT_PADDING_LEFT - BORDER_RIGHT_WIDTH - 2

	// Compose an optional `[source:X]` suffix when the source filter is on.
	src_suffix: string = ""
	if state.source_filter != .ALL {
		src_suffix = fmt.tprintf("  [source:%s]", source_filter_label(state.source_filter))
	}

	if state.filter_active {
		filter_display := fmt.tprintf("/ %s\u2588  (%d/%d matches)%s", filter_str, len(state.filtered_indices), item_count, src_suffix)
		display := truncate_text(filter_display, max_filter_width)
		render_text_styled(screen, header_x, filter_bar_y, display, TUI_SECONDARY, "", true)
	} else {
		filter_display := fmt.tprintf("/ %s  (%d/%d matches)%s", filter_str, len(state.filtered_indices), item_count, src_suffix)
		display := truncate_text(filter_display, max_filter_width)
		render_text_styled(screen, header_x, filter_bar_y, display, TUI_DIM)
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

	// Clear row
	right_edge := screen.width - BORDER_RIGHT_WIDTH
	for clear_x in header_x..<right_edge {
		screen_set_cell(screen, clear_x, y, Cell{char = ' '})
	}

	// Split "<glyph> <rest>" — glyph is always the first rune, followed by a space.
	glyph, rest, glyph_color := split_list_item_glyph(text)

	// Compute padded visible width (runes only, since no ANSI bytes inflate the count).
	available_width := screen.width - text_x - BORDER_RIGHT_WIDTH
	if available_width < 0 { available_width = 0 }
	display := truncate_text(rest, max(0, available_width - 2))  // -2 for glyph + space

	x := text_x
	if is_selected {
		screen_set_cell(screen, header_x, y, Cell{char = BOX_HEAVY_VERTICAL, fg = TUI_PRIMARY, bold = true})
		render_text_styled(screen, x, y, glyph, TUI_PRIMARY, "", true)
		render_text_styled(screen, x + 2, y, display, TUI_PRIMARY, "", true)
	} else {
		render_text_styled(screen, x, y, glyph, glyph_color)
		render_text_styled(screen, x + 2, y, display, TUI_MUTED)
	}
}

// Inspect the first rune of `item` and map it to the appropriate fg colour.
split_list_item_glyph :: proc(item: string) -> (glyph, rest, fg: string) {
	if len(item) == 0 { return "", "", TUI_MUTED }
	first_rune, sz := utf8.decode_rune_in_string(item)
	glyph_str := item[:sz]
	rest_str  := item[sz:]
	if len(rest_str) > 0 && rest_str[0] == ' ' { rest_str = rest_str[1:] }
	color: string
	switch first_rune {
	case '●': color = TUI_SOURCE_WAYU_ACTIVE
	case '⚠': color = TUI_SOURCE_WAYU_INACTIVE
	case '○': color = TUI_SOURCE_EXTERNAL
	case '♦': color = TUI_SOURCE_SHADOWED
	case: color = TUI_MUTED  // separator line or ASCII fallback
	}
	return glyph_str, rest_str, color
}

// ============================================================================
// Shared Footer — Compact keyboard shortcuts
// ============================================================================

// Standard footer for filterable data views
FOOTER_FILTER_ACTIVE :: "Type to filter   Esc Cancel   Enter Accept   j/k Navigate"
FOOTER_DATA_VIEW     :: "/ Filter   s Source   a Add   d Delete   h Back   l Enter   j/k"
FOOTER_READONLY_VIEW :: "/ Filter   h Back   l Enter   j/k Navigate"
FOOTER_BACKUP_VIEW   :: "/ Filter   c Cleanup   h Back   j/k Navigate"
FOOTER_STATIC_VIEW   :: "h Back"

render_data_footer :: proc(screen: ^Screen, state: ^TUIState, footer_text: string) {
	header_x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT
	footer_y := calculate_footer_y(state.terminal_height)

	// The footer sits on the same row as the bottom border.
	// Clear the area between the left border and right corner to erase
	// any leftover border dashes (─) from render_box_styled.
	right_x := state.terminal_width - BORDER_RIGHT_WIDTH - 1  // column before ╯
	for x in header_x..<right_x {
		screen_set_cell(screen, x, footer_y, Cell{char = ' '})
	}

	// Reserve 1 cell for the bottom-right corner '╯' and the right border
	max_footer_width := right_x - header_x

	if state.filter_active {
		footer := get_footer_filter_active(state.terminal_width)
		display := truncate_text(footer, max_footer_width)
		render_text_styled(screen, header_x, footer_y, display, TUI_DIM)
	} else {
		display := truncate_text(footer_text, max_footer_width)
		render_text_styled(screen, header_x, footer_y, display, TUI_DIM)
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
	// Items may start with a glyph (● ⚠ ○ ♦) + space; strip it for parsing
	work_item := item
	glyph_prefix := ""

	// Check for ANSI-colored glyph prefix (e.g., "\x1b[38;2;34;197;94m●\x1b[0m ")
	// or plain Unicode glyph + space
	glyph_strs := []string{"●", "⚠", "○", "♦"}
	for gc_str in glyph_strs {
		if strings.contains(work_item, gc_str) {
			// Find the first occurrence of the glyph
			gc_idx := strings.index(work_item, gc_str)
			if gc_idx >= 0 {
				// Extract everything up to and including the glyph and trailing reset code
				// ANSI codes end with "m" followed by optional space
				end_idx := gc_idx + len(gc_str)
				for end_idx < len(work_item) && work_item[end_idx] != ' ' && work_item[end_idx] != '=' {
					end_idx += 1
				}
				// Skip trailing space if present
				if end_idx < len(work_item) && work_item[end_idx] == ' ' {
					end_idx += 1
				}
				glyph_prefix = work_item[:end_idx]
				work_item = work_item[end_idx:]
				break
			}
		}
	}

	// Split on first '='
	eq_idx := strings.index_byte(work_item, '=')
	key, value: string
	if eq_idx >= 0 {
		key = work_item[:eq_idx]
		value = work_item[eq_idx + 1:]
	} else {
		key = work_item
		value = ""
	}

	// Truncate key and value independently
	truncated_key := truncate_text(key, key_col_width)
	truncated_value := truncate_text(value, value_col_width)

	// Text starts after accent bar + gap
	text_x := x + MENU_ACCENT_BAR_WIDTH + MENU_ACCENT_GAP
	value_x := text_x + key_col_width + COLUMN_GAP

	// Clear the entire line width to prevent scroll overlap artifacts
	// Clear from just after the left border to the screen right edge
	// Start at position 2 to preserve the left border at position 1
	// Use a distinct cell state (empty colors) to ensure diff detection
	for clear_x in 2..<screen.width {
		screen_set_cell(screen, clear_x, y, Cell{char = ' ', fg = "", bg = "", bold = false, dim = false})
	}

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
	divider_width := max(0, border_width - CONTENT_PADDING_LEFT - 2)
	for dx in 0..<divider_width {
		screen_set_cell(screen, x + dx, divider_y, Cell{char = BOX_HORIZONTAL, fg = TUI_DIVIDER})
	}
}

// ============================================================================
// Generic List View — shared skeleton for all five data views
// ============================================================================

ListViewRowKind :: enum { Single, Table }

ListViewConfig :: struct {
	view_key:     TUIView,
	title:        string,
	count_format: string,
	row_kind:     ListViewRowKind,
	col_label_0:  string,
	col_label_1:  string,
	empty_line_1: string,
	empty_line_2: string,   // "" means skip second empty line
	footer:       string,
}

// render_list_view is the single generic implementation shared by all five
// data views (path, alias, constants, completions, backups).
// Each public render_*_view proc constructs a ListViewConfig and delegates here.
render_list_view :: proc(state: ^TUIState, screen: ^Screen, cfg: ListViewConfig) {
	border_width, border_height := calculate_border_dimensions(state.terminal_width, state.terminal_height)
	max_text_width := tui_calculate_content_width(border_width)
	render_box_styled(screen, BORDER_LEFT_WIDTH, BORDER_TOP_HEIGHT, border_width, border_height, TUI_BORDER_FOCUSED)

	header_x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT

	// Nil-cache guard: data not yet loaded — show loading state and request refresh
	if state.data_cache[cfg.view_key] == nil {
		render_view_loading(screen, state, cfg.title, border_width)
		return
	}

	items := cast(^[dynamic]string)state.data_cache[cfg.view_key]

	// Count entries by source for the header
	wayu_active, wayu_inactive, external, shadowed := count_entries_by_source(items)
	total := wayu_active + wayu_inactive + external + shadowed  // Skip separators

	// Format count text with source breakdown
	count_text: string
	if wayu_active + wayu_inactive + external + shadowed == 0 {
		count_text = "0 entries"
	} else {
		parts := make([dynamic]string, allocator = context.temp_allocator)
		if wayu_active > 0 {
			append(&parts, fmt.tprintf("%d wayu", wayu_active))
		}
		if wayu_inactive > 0 {
			append(&parts, fmt.tprintf("%d inactive", wayu_inactive))
		}
		if external > 0 {
			append(&parts, fmt.tprintf("%d external", external))
		}
		if shadowed > 0 {
			append(&parts, fmt.tprintf("%d shadowed", shadowed))
		}
		count_text = strings.join(parts[:], " · ", context.temp_allocator)
	}

	render_view_header(screen, state, cfg.title, count_text, border_width)

	// Column widths — only computed for Table row_kind
	key_col_width   := 0
	value_col_width := 0
	if cfg.row_kind == .Table {
		key_col_width = calculate_key_column_width(items, max_text_width)
		value_col_width = max_text_width - key_col_width - COLUMN_GAP
		if value_col_width < 1 {
			value_col_width = 1
		}
	}

	has_filter := has_any_filter(state)
	list_start_offset := render_filter_bar(screen, state, len(items))

	// Content area starts after divider (+1) and optional filter bar
	content_start := LIST_ITEM_START_LINE + 1 + list_start_offset

	// Column header row — only for Table views when items are visible
	show_items := (has_filter && len(state.filtered_indices) > 0) || (!has_filter && len(items) > 0)
	col_header_offset := 0
	if cfg.row_kind == .Table && show_items {
		render_column_header(screen, header_x, content_start, cfg.col_label_0, cfg.col_label_1, key_col_width, border_width)
		col_header_offset = 2  // header line + divider line
	}

	data_start := content_start + col_header_offset

	// Unified text_x for empty state rendering (same expression used inline in all five original procs)
	text_x := header_x + MENU_ACCENT_BAR_WIDTH + MENU_ACCENT_GAP

	if has_filter && len(state.filtered_indices) > 0 {
		// Filtered — show matching items
		// Use get_view_visible_height to match the scroll logic's calculation exactly
		visible_height := get_view_visible_height(state)
		start := state.scroll_offset
		end := min(start + visible_height, len(state.filtered_indices))

		for idx in start..<end {
			y := data_start + (idx - start)
			original_idx := state.filtered_indices[idx]
			switch cfg.row_kind {
			case .Single:
				render_list_item(screen, header_x, y, items[original_idx], max_text_width, idx == state.selected_index)
			case .Table:
				render_table_row(screen, header_x, y, items[original_idx], key_col_width, value_col_width, idx == state.selected_index)
			}
		}

		if len(state.filtered_indices) > visible_height {
			scroll_info := fmt.tprintf("Showing %d-%d of %d matches", start+1, end, len(state.filtered_indices))
			render_text_styled(screen, header_x, data_start + visible_height, scroll_info, TUI_DIM)
		}
	} else if has_filter && len(state.filtered_indices) == 0 {
		// Filtered — no matches
		render_text_styled(screen, text_x, data_start + 1, "No matches found", TUI_DIM)
	} else if len(items) == 0 {
		// Empty (no items at all)
		// Note: use content_start (not data_start) — col_header_offset is 0 when items==0,
		// so they are equal, but content_start is the canonical anchor for empty state.
		render_text_styled(screen, text_x, content_start + 1, cfg.empty_line_1, TUI_DIM)
		if cfg.empty_line_2 != "" {
			render_text_styled(screen, text_x, content_start + 3, cfg.empty_line_2, TUI_MUTED)
		}
	} else {
		// Normal — show all items
		// Use get_view_visible_height to match the scroll logic's calculation exactly
		visible_height := get_view_visible_height(state)
		start := state.scroll_offset
		end := min(start + visible_height, len(items))

		for i in start..<end {
			y := data_start + (i - start)
			switch cfg.row_kind {
			case .Single:
				render_list_item(screen, header_x, y, items[i], max_text_width, i == state.selected_index)
			case .Table:
				render_table_row(screen, header_x, y, items[i], key_col_width, value_col_width, i == state.selected_index)
			}
		}

		if len(items) > visible_height {
			scroll_info := fmt.tprintf("Showing %d-%d of %d", start+1, end, len(items))
			render_text_styled(screen, header_x, data_start + visible_height, scroll_info, TUI_DIM)
		}
	}

	render_data_footer(screen, state, cfg.footer)
}

