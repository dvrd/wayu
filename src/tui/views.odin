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
	max_text_width := calculate_content_width(border_width)
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

// ============================================================================
// PATH View
// ============================================================================

render_path_view :: proc(state: ^TUIState, screen: ^Screen) {
	render_list_view(state, screen, ListViewConfig{
		view_key     = .PATH_VIEW,
		title        = "PATH CONFIGURATION",
		count_format = "%d entries",  // Unused (calculated from source counts)
		row_kind     = .Single,
		empty_line_1 = "No PATH entries found",
		footer       = get_footer_data_view(state.terminal_width),
	})
}

// ============================================================================
// Alias View
// ============================================================================

render_alias_view :: proc(state: ^TUIState, screen: ^Screen) {
	render_list_view(state, screen, ListViewConfig{
		view_key     = .ALIAS_VIEW,
		title        = "ALIASES",
		count_format = "%d aliases",
		row_kind     = .Table,
		col_label_0  = "ALIAS",
		col_label_1  = "COMMAND",
		empty_line_1 = "No aliases found",
		footer       = get_footer_data_view(state.terminal_width),
	})
}

// ============================================================================
// Constants View
// ============================================================================

render_constants_view :: proc(state: ^TUIState, screen: ^Screen) {
	render_list_view(state, screen, ListViewConfig{
		view_key     = .CONSTANTS_VIEW,
		title        = "ENVIRONMENT CONSTANTS",
		count_format = "%d constants",
		row_kind     = .Table,
		col_label_0  = "NAME",
		col_label_1  = "VALUE",
		empty_line_1 = "No constants found",
		footer       = get_footer_data_view(state.terminal_width),
	})
}

// ============================================================================
// Completions View
// ============================================================================

render_completions_view :: proc(state: ^TUIState, screen: ^Screen) {
	render_list_view(state, screen, ListViewConfig{
		view_key     = .COMPLETIONS_VIEW,
		title        = "COMPLETIONS",
		count_format = "%d completion scripts",
		row_kind     = .Single,
		empty_line_1 = "No completion scripts found",
		empty_line_2 = "Add completions with: wayu completions add <name> <file>",
		footer       = get_footer_readonly_view(state.terminal_width),
	})
}

// ============================================================================
// Backups View
// ============================================================================

render_backups_view :: proc(state: ^TUIState, screen: ^Screen) {
	render_list_view(state, screen, ListViewConfig{
		view_key     = .BACKUPS_VIEW,
		title        = "BACKUPS",
		count_format = "%d backups available",
		row_kind     = .Single,
		empty_line_1 = "No backups found",
		footer       = get_footer_backup_view(state.terminal_width),
	})
}

// ============================================================================
// Plugins View — tab switcher: [Installed] / [Registry]
// ============================================================================

// Tab indices
PLUGIN_TAB_INSTALLED :: 0
PLUGIN_TAB_REGISTRY  :: 1

// Footer strings for each tab
FOOTER_PLUGINS_INSTALLED :: "Tab Switch tab   / Filter   e Enable   d Disable   h Back   j/k Navigate"
FOOTER_PLUGINS_REGISTRY  :: "Tab Switch tab   / Filter   Enter Install   h Back   j/k Navigate"

// Render the two-tab header bar for the plugins view.
@(private="file")
render_plugin_tab_bar :: proc(screen: ^Screen, state: ^TUIState, border_width: int) {
	header_x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT
	text_x   := header_x + MENU_ACCENT_BAR_WIDTH + MENU_ACCENT_GAP
	title_y  := HEADER_TITLE_LINE + CONTENT_PADDING_TOP
	tab_y    := title_y + 1

	// Accent bar spans title + tab line
	screen_set_cell(screen, header_x, title_y, Cell{char = BOX_HEAVY_VERTICAL, fg = TUI_PRIMARY, bold = true})
	screen_set_cell(screen, header_x, tab_y,   Cell{char = BOX_HEAVY_VERTICAL, fg = TUI_PRIMARY, bold = true})

	render_text_styled(screen, text_x, title_y, "PLUGINS", TUI_PRIMARY, "", true)

	// Responsive tab labels
	compact := is_compact(state.terminal_width)
	tab_installed_label := "[Installed]"
	tab_registry_label  := "[Registry]"
	if compact {
		tab_installed_label = "[Inst]"
		tab_registry_label  = "[Reg]"
	}
	tab_gap := 2

	// Active tab bold+primary, inactive dim
	tab_x := text_x
	if state.plugin_tab == PLUGIN_TAB_INSTALLED {
		render_text_styled(screen, tab_x, tab_y, tab_installed_label, TUI_PRIMARY, "", true)
		tab_x += len(tab_installed_label) + tab_gap
		render_text_styled(screen, tab_x, tab_y, tab_registry_label, TUI_DIM)
	} else {
		render_text_styled(screen, tab_x, tab_y, tab_installed_label, TUI_DIM)
		tab_x += len(tab_installed_label) + tab_gap
		render_text_styled(screen, tab_x, tab_y, tab_registry_label, TUI_PRIMARY, "", true)
		tab_x += len("[Installed]") + 2
		render_text_styled(screen, tab_x, tab_y, "[Registry]", TUI_PRIMARY, "", true)
	}

	// Horizontal divider
	divider_y     := LIST_ITEM_START_LINE
	divider_width := max(0, border_width - CONTENT_PADDING_LEFT - 2)
	for dx in 0..<divider_width {
		screen_set_cell(screen, header_x + dx, divider_y, Cell{char = BOX_HORIZONTAL, fg = TUI_DIVIDER})
	}
}

// Render one row of the registry table.
// item format: "key\x00category\x00shell\x00description"
@(private="file")
render_registry_row :: proc(
	screen: ^Screen,
	header_x, text_x, y: int,
	item: string,
	col_key_w, col_cat_w, col_sh_w, col_desc_w: int,
	is_selected: bool,
) {
	parts := strings.split(item, "\x00")
	defer delete(parts)
	if len(parts) < 4 do return

	key  := truncate_text(parts[0], col_key_w  - 1)
	cat  := truncate_text(parts[1], col_cat_w  - 1)
	sh   := truncate_text(parts[2], col_sh_w   - 1)
	desc := truncate_text(parts[3], col_desc_w - 1)

	x_cat  := text_x + col_key_w
	x_sh   := x_cat  + col_cat_w
	x_desc := x_sh   + col_sh_w

	if is_selected {
		screen_set_cell(screen, header_x, y, Cell{char = BOX_HEAVY_VERTICAL, fg = TUI_PRIMARY, bold = true})
		render_text_styled(screen, text_x,   y, key,  TUI_PRIMARY, "", true)
		render_text_styled(screen, x_cat,    y, cat,  TUI_PRIMARY, "", true)
		render_text_styled(screen, x_sh,     y, sh,   TUI_PRIMARY, "", true)
		render_text_styled(screen, x_desc,   y, desc, TUI_PRIMARY, "", true)
	} else {
		render_text_styled(screen, text_x,   y, key,  TUI_MUTED)
		render_text_styled(screen, x_cat,    y, cat,  TUI_DIM)
		render_text_styled(screen, x_sh,     y, sh,   TUI_DIM)
		render_text_styled(screen, x_desc,   y, desc, TUI_DIM)
	}
}

render_plugins_view :: proc(state: ^TUIState, screen: ^Screen) {
	border_width, border_height := calculate_border_dimensions(state.terminal_width, state.terminal_height)
	max_text_width := calculate_content_width(border_width)
	render_box_styled(screen, BORDER_LEFT_WIDTH, BORDER_TOP_HEIGHT, border_width, border_height, TUI_BORDER_FOCUSED)

	header_x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT
	text_x   := header_x + MENU_ACCENT_BAR_WIDTH + MENU_ACCENT_GAP

	// ── Tab: Installed ───────────────────────────────────────────────────
	if state.plugin_tab == PLUGIN_TAB_INSTALLED {
		if state.data_cache[.PLUGINS_VIEW] == nil {
			render_view_loading(screen, state, "PLUGINS", border_width)
			return
		}

		items := cast(^[dynamic]string)state.data_cache[.PLUGINS_VIEW]
		render_plugin_tab_bar(screen, state, border_width)

		has_filter    := has_any_filter(state)
		filter_offset := render_filter_bar(screen, state, len(items))
		content_start := LIST_ITEM_START_LINE + 1 + filter_offset

		if has_filter && len(state.filtered_indices) > 0 {
			// Use get_view_visible_height to match the scroll logic's calculation exactly
			visible_height := get_view_visible_height(state)
			start := state.scroll_offset
			end   := min(start + visible_height, len(state.filtered_indices))
			for idx in start..<end {
				y            := content_start + (idx - start)
				original_idx := state.filtered_indices[idx]
				render_list_item(screen, header_x, y, items[original_idx], max_text_width, idx == state.selected_index)
			}
			if len(state.filtered_indices) > visible_height {
				scroll_info := fmt.tprintf("Showing %d-%d of %d matches", start+1, end, len(state.filtered_indices))
				render_text_styled(screen, header_x, content_start + visible_height, scroll_info, TUI_DIM)
			}
		} else if has_filter && len(state.filtered_indices) == 0 {
			render_text_styled(screen, text_x, content_start + 1, "No matches found", TUI_DIM)
		} else if len(items) == 0 {
			render_text_styled(screen, text_x, content_start + 1, "No plugins installed", TUI_DIM)
			render_text_styled(screen, text_x, content_start + 3,
				"Switch to Registry tab (Tab key) to browse and install", TUI_MUTED)
		} else {
			// Use get_view_visible_height to match the scroll logic's calculation exactly
			visible_height := get_view_visible_height(state)
			start := state.scroll_offset
			end   := min(start + visible_height, len(items))
			for i in start..<end {
				y := content_start + (i - start)
				render_list_item(screen, header_x, y, items[i], max_text_width, i == state.selected_index)
			}
			if len(items) > visible_height {
				scroll_info := fmt.tprintf("Showing %d-%d of %d", start+1, end, len(items))
				render_text_styled(screen, header_x, content_start + visible_height, scroll_info, TUI_DIM)
			}
		}

		render_data_footer(screen, state, get_footer_plugins_installed(state.terminal_width))
		return
	}

	// ── Tab: Registry ────────────────────────────────────────────────────
	if state.plugin_registry_cache == nil {
		render_view_loading(screen, state, "PLUGINS", border_width)
		return
	}

	items := state.plugin_registry_cache
	render_plugin_tab_bar(screen, state, border_width)

	has_filter    := has_any_filter(state)
	filter_offset := render_filter_bar(screen, state, len(items^))
	content_start := LIST_ITEM_START_LINE + 1 + filter_offset

	// Column widths — responsive based on available space
	compact := is_compact(state.terminal_width)
	narrow  := is_narrow(state.terminal_width)
	col_key_w  : int
	col_cat_w  : int
	col_sh_w   : int
	if narrow {
		col_key_w = 14
		col_cat_w = 0  // hide category column
		col_sh_w  = 0  // hide shell column
	} else if compact {
		col_key_w = 16
		col_cat_w = 8
		col_sh_w  = 4
	} else {
		col_key_w = 22
		col_cat_w = 12
		col_sh_w  = 6
	}
	col_desc_w := max(1, max_text_width - col_key_w - col_cat_w - col_sh_w)

	// Column header row
	render_text_styled(screen, text_x,             content_start, "KEY", TUI_DIM, "", true)
	if col_cat_w > 0 {
		render_text_styled(screen, text_x + col_key_w,              content_start, "CATEGORY", TUI_DIM, "", true)
	}
	if col_sh_w > 0 {
		render_text_styled(screen, text_x + col_key_w + col_cat_w,  content_start, "SHELL",    TUI_DIM, "", true)
	}
	render_text_styled(screen, text_x + col_key_w + col_cat_w + col_sh_w, content_start, "DESCRIPTION", TUI_DIM, "", true)

	// Thin divider under column headers
	divider_width := max(0, border_width - CONTENT_PADDING_LEFT - 2)
	for dx in 0..<divider_width {
		screen_set_cell(screen, header_x + dx, content_start + 1,
			Cell{char = BOX_HORIZONTAL, fg = TUI_DIVIDER})
	}

	data_start := content_start + 2  // col header + divider

	if has_filter && len(state.filtered_indices) > 0 {
		visible_height := calculate_visible_height(state.terminal_height) - filter_offset - 3
		start := state.scroll_offset
		end   := min(start + visible_height, len(state.filtered_indices))
		for list_pos in start..<end {
			original_idx := state.filtered_indices[list_pos]
			render_registry_row(screen, header_x, text_x, data_start + (list_pos - start),
				items[original_idx], col_key_w, col_cat_w, col_sh_w, col_desc_w,
				list_pos == state.selected_index)
		}
		if len(state.filtered_indices) > visible_height {
			scroll_info := fmt.tprintf("Showing %d-%d of %d matches", start+1, end, len(state.filtered_indices))
			render_text_styled(screen, header_x, data_start + visible_height, scroll_info, TUI_DIM)
		}
	} else if has_filter && len(state.filtered_indices) == 0 {
		render_text_styled(screen, text_x, data_start + 1, "No matches found", TUI_DIM)
	} else {
		visible_height := calculate_visible_height(state.terminal_height) - 3
		start := state.scroll_offset
		end   := min(start + visible_height, len(items^))
		for i in start..<end {
			render_registry_row(screen, header_x, text_x, data_start + (i - start),
				items[i], col_key_w, col_cat_w, col_sh_w, col_desc_w,
				i == state.selected_index)
		}
		if len(items^) > visible_height {
			scroll_info := fmt.tprintf("Showing %d-%d of %d", start+1, end, len(items^))
			render_text_styled(screen, header_x, data_start + visible_height, scroll_info, TUI_DIM)
		}
	}

	render_data_footer(screen, state, get_footer_plugins_registry(state.terminal_width))
}

// ============================================================================
// Hooks View
// ============================================================================

render_hooks_view :: proc(state: ^TUIState, screen: ^Screen) {
	border_width, border_height := calculate_border_dimensions(state.terminal_width, state.terminal_height)
	render_box_styled(screen, BORDER_LEFT_WIDTH, BORDER_TOP_HEIGHT, border_width, border_height, TUI_BORDER_NORMAL)

	render_view_header(screen, state, "HOOKS", "Pre/post operation hooks configured", border_width)

	header_x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT
	text_x := header_x + MENU_ACCENT_BAR_WIDTH + MENU_ACCENT_GAP
	content_start := LIST_ITEM_START_LINE + 1

	// Read-only display of configured hooks from wayu.toml
	// Shows hook name and command for all configured hooks

	// In a real implementation, we'd load hooks from the bridge.
	// For now, show a helpful message directing users to the CLI.
	render_text_styled(screen, text_x, content_start, "Hooks Configuration", TUI_PRIMARY, "", true)
	render_text_styled(screen, text_x, content_start + 2, "To configure hooks, edit your wayu.toml file:", TUI_DIM)
	render_text_styled(screen, text_x, content_start + 3, "", TUI_DIM)
	render_text_styled(screen, text_x, content_start + 4, "  wayu config edit", TUI_DIM)
	render_text_styled(screen, text_x, content_start + 5, "", TUI_DIM)
	render_text_styled(screen, text_x, content_start + 6, "Or view configured hooks with:", TUI_DIM)
	render_text_styled(screen, text_x, content_start + 7, "", TUI_DIM)
	render_text_styled(screen, text_x, content_start + 8, "  wayu hooks list", TUI_DIM)
}

// Settings View
// ============================================================================

render_settings_view :: proc(state: ^TUIState, screen: ^Screen) {
	border_width, border_height := calculate_border_dimensions(state.terminal_width, state.terminal_height)
	render_box_styled(screen, BORDER_LEFT_WIDTH, BORDER_TOP_HEIGHT, border_width, border_height, TUI_BORDER_NORMAL)

	render_view_header(screen, state, "SETTINGS", "wayu Configuration", border_width)

	header_x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT
	text_x := header_x + MENU_ACCENT_BAR_WIDTH + MENU_ACCENT_GAP

	// Load settings from bridge (idempotent — only loads once).
	tui_load_settings_data(state)

	// Render lines live on context.temp_allocator — automatically freed at
	// end of frame, so we don't need per-line defer delete churn.
	dry_run_status := "off"
	if state.settings_dry_run { dry_run_status = "on" }

	toml_status := "missing"
	if state.settings_toml_exists {
		toml_status = state.settings_toml_path
	}

	settings := []string{
		fmt.tprintf("Version:     %s",    state.settings_version),
		fmt.tprintf("Shell:       %s",    state.settings_shell),
		fmt.tprintf("Config Dir:  %s",    state.settings_config_dir),
		fmt.tprintf("wayu.toml:   %s",    toml_status),
		fmt.tprintf("Backups:     %d",    state.settings_backups),
		fmt.tprintf("Plugins:     %d enabled", state.settings_plugins),
		fmt.tprintf("Dry-run:     %s",    dry_run_status),
	}

	content_start := LIST_ITEM_START_LINE + 2
	for setting, i in settings {
		render_text_styled(screen, text_x, content_start + i, setting, TUI_MUTED)
	}

	render_data_footer(screen, state, get_footer_static_view(state.terminal_width))
}

// ============================================================================
// Helper Functions
// ============================================================================

// Free and nil out the registry cache so it reloads on next entry.
// Call after a successful install so the installed plugin is filtered out.
clear_registry_cache :: proc(state: ^TUIState) {
	if state.plugin_registry_cache == nil { return }
	for item in state.plugin_registry_cache^ {
		delete(item)
	}
	delete(state.plugin_registry_cache^)
	free(state.plugin_registry_cache)
	state.plugin_registry_cache = nil
}

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
		delete_key(state.data_cache, view)
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
		return 10  // placeholder count when cache not yet loaded

	case .ALIAS_VIEW:
		if state.data_cache[.ALIAS_VIEW] != nil {
			items := cast(^[dynamic]string)state.data_cache[.ALIAS_VIEW]
			return len(items)
		}
		return 8  // placeholder count when cache not yet loaded

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

	case .PLUGINS_VIEW:
		if state.plugin_tab == PLUGIN_TAB_REGISTRY {
			if state.plugin_registry_cache != nil {
				return len(state.plugin_registry_cache^)
			}
			return 0
		}
		if state.data_cache[.PLUGINS_VIEW] != nil {
			items := cast(^[dynamic]string)state.data_cache[.PLUGINS_VIEW]
			return len(items)
		}
		return 0

	case .HOOKS_VIEW:
		return 0  // Read-only view

	case .SETTINGS_VIEW:
		return 0  // Read-only view
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
	//   1 top border + 1 title + 1 blank + (4 per field: label + box-top + box-content + box-bottom) * field_count
	//   + 1 blank + 1 error row (always reserved) + 1 blank + 1 button row + 1 bottom border
	field_rows := form.field_count * 4   // label + box(3 rows) per field
	overlay_height := 1 + 1 + 1 + field_rows + 1 + 1 + 1 + 1 + 1  // = 11 for 1-field, 15 for 2-field

	overlay_width := min(state.terminal_width - 4, 56)
	if overlay_width < 24 {
		overlay_width = 24
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

	// Title: ┃ ADD {VIEW}
	title_y := overlay_y + 1
	view_name: string
	switch form.view {
	case .PATH_VIEW:      view_name = "PATH"
	case .ALIAS_VIEW:     view_name = "ALIAS"
	case .CONSTANTS_VIEW: view_name = "CONSTANT"
	case .MAIN_MENU, .COMPLETIONS_VIEW, .BACKUPS_VIEW, .PLUGINS_VIEW, .HOOKS_VIEW, .SETTINGS_VIEW:
		view_name = "ENTRY"
	}
	title_text := fmt.tprintf("ADD %s", view_name)
	screen_set_cell(screen, content_x, title_y, Cell{char = BOX_HEAVY_VERTICAL, fg = TUI_PRIMARY, bold = true})
	render_text_styled(screen, content_x + MENU_ACCENT_BAR_WIDTH + 1, title_y, title_text, TUI_PRIMARY, "", true)

	// Focus indices: 0..field_count-1 = fields, field_count = CANCEL, field_count+1 = ADD
	cancel_idx := form.field_count
	add_idx    := form.field_count + 1

	// Fields — each block: label row + bordered input box (3 rows: top, content, bottom)
	// Layout per field (4 rows total):
	//   LABEL
	//   ┌──────────────────────────┐
	//   │ text█                    │   ← focused: orange border + cursor; unfocused: dim border
	//   └──────────────────────────┘
	field_start_y := title_y + 2  // blank line after title
	// Box width: overlay_width - 2 (outer border) - 2 (content_x offset) - 2 (inner padding) = overlay_width - 6
	// But content_x is already overlay_x + 2, and we want the box to start at content_x + 2 (same indent as label).
	// Box occupies columns [content_x+2 .. content_x+2+box_width-1].
	// box_width = overlay_width - 2(outer left) - 2(content indent) - 2(outer right) = overlay_width - 6
	box_width := overlay_width - 6
	if box_width < 4 {
		box_width = 4
	}
	// Text fits inside the box: box_width - 2 (left │ and right │)
	text_max := box_width - 2
	if text_max < 1 {
		text_max = 1
	}

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

		label_y   := field_start_y + fi * 4
		box_y     := label_y + 1   // top border of box
		content_y := label_y + 2   // text row inside box
		// box bottom is at label_y + 3 (drawn by render_box_styled)

		// Label — orange only when this field is focused
		label_fg: string
		if is_focused {
			label_fg = TUI_ORANGE
		} else {
			label_fg = TUI_DIM
		}
		render_text_styled(screen, content_x + 2, label_y, label, label_fg, "", is_focused)

		// Bordered input box
		box_x := content_x + 2
		box_fg: string
		if is_focused {
			box_fg = TUI_ORANGE
		} else {
			box_fg = TUI_DIM
		}
		render_box_styled(screen, box_x, box_y, box_width, 3, box_fg)

		// Clear interior (1 row, box_width-2 chars)
		for dx in 1..<box_width-1 {
			screen_set_cell(screen, box_x + dx, content_y, Cell{char = ' '})
		}

		// Text inside box: "text█" when focused, "text" when not
		input_str := string(input_buf[:])
		truncated := truncate_text(input_str, text_max - 1)  // -1 leaves room for cursor
		text_display: string
		if is_focused {
			text_display = fmt.tprintf("%s\u2588", truncated)  // U+2588 FULL BLOCK cursor
		} else {
			text_display = truncated
		}
		text_fg: string
		if is_focused {
			text_fg = TUI_ORANGE
		} else {
			text_fg = TUI_DIM
		}
		render_text_styled(screen, box_x + 1, content_y, text_display, text_fg, "", is_focused)
	}

	// Error line (always 1 row reserved; shown only when non-empty)
	error_y := field_start_y + form.field_count * 4 + 1
	if len(form.error_message) > 0 {
		err_display := truncate_text(form.error_message, overlay_width - 6)
		render_text_styled(screen, content_x + 2, error_y, err_display, TUI_ERROR)
	}

	// Button row — each button is orange+bold only when focused, dim otherwise
	button_y     := error_y + 2
	cancel_label := "Esc CANCEL"
	add_label    := "Enter ADD"

	// Responsive: shorter labels on narrow overlays
	if is_compact(overlay_width) {
		cancel_label = "Esc CAN"
		add_label    = "\u23CE ADD"  // ⏎ ADD
	}
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
	overlay_width := min(state.terminal_width - 4, 60)
	overlay_height := min(len(state.detail_lines) + 7, state.terminal_height - 2)
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
	title_display := truncate_text(state.detail_title, overlay_width - 6)
	render_text_styled(screen, content_x + MENU_ACCENT_BAR_WIDTH + 1, title_y, title_display, TUI_PRIMARY, "", true)

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
		cancel_label := "Esc CANCEL"   // 10 chars
		delete_label := "y DELETE"     //  8 chars

		// Responsive: use shorter labels on narrow terminals
		compact := is_compact(overlay_width)
		if compact {
			cancel_label = "Esc CAN"
			delete_label = "y DEL"
		}

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
