package wayu
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"
// ============================================================================
// Source Counter Helper
// ============================================================================

// Count entries by source from row metadata.
// Returns (wayu_active, wayu_inactive, external, shadowed). Separators and
// source-less rows are not counted.
count_entries_by_source :: proc(meta: []RowMeta) -> (int, int, int, int) {
	wayu_active := 0
	wayu_inactive := 0
	external := 0
	shadowed := 0

	for m in meta {
		if m.kind == .Separator { continue }
		switch m.source {
		case .WAYU_ACTIVE:   wayu_active += 1
		case .WAYU_INACTIVE: wayu_inactive += 1
		case .EXTERNAL:      external += 1
		case .SHADOWED:      shadowed += 1
		case .NONE:
		}
	}

	return wayu_active, wayu_inactive, external, shadowed
}

// ============================================================================
// Text Truncation Helper
// ============================================================================

// Truncate text to fit within max_width terminal columns, appending "…" if
// truncated. Measures display width (CJK/emoji = 2 columns, ANSI = 0) via
// visual_width/get_rune_width so it agrees with the cell renderer.
// Returns `text` itself when it fits, otherwise a temp-allocated string
// (do NOT delete).
truncate_text :: proc(text: string, max_width: int) -> string {
	if max_width <= 0 do return ""
	if visual_width(text) <= max_width do return text
	// Keep runes while they fit in (max_width - 1) columns, then add "…".
	budget := max_width - 1
	used := 0
	end := 0
	for r, i in text {
		w := get_rune_width(r)
		if used + w > budget do break
		used += w
		end = i + utf8.rune_size(r)
	}
	return fmt.tprintf("%s…", text[:end])
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
	filter_str := string(state.filter.text[:])

	max_filter_width := state.terminal_width - BORDER_LEFT_WIDTH - CONTENT_PADDING_LEFT - BORDER_RIGHT_WIDTH - 2

	// Compose an optional `[source:X]` suffix when the source filter is on.
	src_suffix: string = ""
	if state.source_filter != .ALL {
		src_suffix = fmt.tprintf("  [source:%s]", source_filter_label(state.source_filter))
	}

	if state.filter.active {
		filter_display := fmt.tprintf("/ %s\u2588  (%d/%d matches)%s", filter_str, len(state.filter.indices), item_count, src_suffix)
		display := truncate_text(filter_display, max_filter_width)
		render_text_styled(screen, header_x, filter_bar_y, display, TUI_SECONDARY, "", true)
	} else {
		filter_display := fmt.tprintf("/ %s  (%d/%d matches)%s", filter_str, len(state.filter.indices), item_count, src_suffix)
		display := truncate_text(filter_display, max_filter_width)
		render_text_styled(screen, header_x, filter_bar_y, display, TUI_DIM)
	}
	return 1
}

// ============================================================================
// Shared List Item — Single-column with accent bar selection
// ============================================================================

// Render a single list item with ┃ accent bar for selected state.
// `source` selects the leading glyph (none for .NONE); `text` is the plain row
// text without any glyph. Separator rows render dim with no glyph.
render_list_item :: proc(
	screen: ^Screen,
	header_x, y: int,
	text: string,
	max_width: int,
	is_selected: bool,
	source := RowSource.NONE,
	is_separator := false,
) {
	text_x := header_x + MENU_ACCENT_BAR_WIDTH + MENU_ACCENT_GAP

	// Clear the row inside the box only: the box's right border sits at
	// column screen.width - BORDER_HORIZONTAL_TOTAL and must survive.
	right_edge := screen.width - BORDER_HORIZONTAL_TOTAL
	for clear_x in header_x..<right_edge {
		screen_set_cell(screen, clear_x, y, Cell{char = ' '})
	}

	glyph := source_glyph(source)
	glyph_w := visual_width(glyph)
	text_offset := glyph_w + 1 if glyph_w > 0 else 0

	available_width := min(max_width, right_edge - text_x) - text_offset
	display := truncate_text(text, max(0, available_width))

	if is_separator {
		render_text_styled(screen, text_x, y, display, TUI_DIM)
		return
	}

	if is_selected {
		screen_set_cell(screen, header_x, y, Cell{char = BOX_HEAVY_VERTICAL, fg = TUI_PRIMARY, bold = true})
		screen_mark_focus(screen, text_x, y)
		if glyph_w > 0 do render_text_styled(screen, text_x, y, glyph, TUI_PRIMARY, "", true)
		render_text_styled(screen, text_x + text_offset, y, display, TUI_PRIMARY, "", true)
	} else {
		if glyph_w > 0 do render_text_styled(screen, text_x, y, glyph, source_glyph_color(source))
		render_text_styled(screen, text_x + text_offset, y, display, TUI_MUTED)
	}
}

// ============================================================================
// Shared Footer — Compact keyboard shortcuts
// ============================================================================

// Standard footer for filterable data views
FOOTER_FILTER_ACTIVE :: "Type to filter   Esc Cancel   Enter Accept   j/k Navigate"
FOOTER_DATA_VIEW     :: "/ Filter   s Source   a Add   d Delete   h Back   l Enter   j/k"
FOOTER_CONSTANTS_VIEW        :: "/ Filter   v Reveal   s Source   a Add   d Del   h Back   l Enter   j/k"
FOOTER_CONSTANTS_VIEW_REVEAL :: "/ Filter   v Hide   s Source   a Add   d Del   h Back   l Enter   j/k"
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

	if state.filter.active {
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

// Calculate optimal key column width from the widest key (display columns).
// Keys come from RowMeta when available (separators skipped); otherwise the
// part of the display row before the first '='.
// Returns width clamped between MIN_KEY_COL_WIDTH and 30% of max_text_width.
calculate_key_column_width :: proc(items: []string, meta: []RowMeta, max_text_width: int) -> int {
	max_key_len := 0
	for item, i in items {
		key := item
		if i < len(meta) {
			if meta[i].kind == .Separator { continue }
			key = meta[i].key
		} else if eq_idx := strings.index_byte(item, '='); eq_idx >= 0 {
			key = item[:eq_idx]
		}
		max_key_len = max(max_key_len, visual_width(key))
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
	key, value: string,
	key_col_width, value_col_width: int,
	is_selected: bool,
	is_separator := false,
) {
	// Truncate key and value independently
	truncated_key := truncate_text(key, key_col_width)
	truncated_value := truncate_text(value, value_col_width)

	// Text starts after accent bar + gap
	text_x := x + MENU_ACCENT_BAR_WIDTH + MENU_ACCENT_GAP
	value_x := text_x + key_col_width + COLUMN_GAP

	// Clear the row between the box borders to prevent scroll overlap
	// artifacts. Start at position 2 to preserve the left border at position 1
	// and stop before the right border at screen.width - BORDER_HORIZONTAL_TOTAL.
	for clear_x in 2..<screen.width - BORDER_HORIZONTAL_TOTAL {
		screen_set_cell(screen, clear_x, y, Cell{char = ' ', fg = "", bg = "", bold = false, dim = false})
	}

	if is_separator {
		render_text_styled(screen, text_x, y, truncate_text(key, key_col_width + COLUMN_GAP + value_col_width), TUI_DIM)
		return
	}

	if is_selected {
		// Selected: accent bar ┃ + bold primary key + bold primary value
		screen_set_cell(screen, x, y, Cell{char = BOX_HEAVY_VERTICAL, fg = TUI_PRIMARY, bold = true})
		screen_mark_focus(screen, text_x, y)
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
	mask_secrets: bool,     // Table: show secret-looking values as SECRET_MASK
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

	items_ptr := cast(^[dynamic]string)state.data_cache[cfg.view_key]
	items := items_ptr[:]
	meta := state.row_meta[cfg.view_key][:]

	// Count entries by source for the header
	wayu_active, wayu_inactive, external, shadowed := count_entries_by_source(meta)
	total := wayu_active + wayu_inactive + external + shadowed

	// Format count text
	count_text: string
	if total == 0 {
		// No source info — use raw count (completions, backups, etc.)
		raw := 0
		for item, i in items {
			if i < len(meta) && meta[i].kind == .Separator { continue }
			if len(item) > 0 { raw += 1 }
		}
		if raw == 0 {
			count_text = "0 entries"
		} else {
			count_text = fmt.tprintf(cfg.count_format, raw)
		}
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
		key_col_width = calculate_key_column_width(items, meta, max_text_width)
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
	// (must agree with view_shows_column_header used by get_view_visible_height)
	col_header_offset := 0
	if cfg.row_kind == .Table && view_shows_column_header(state) {
		render_column_header(screen, header_x, content_start, cfg.col_label_0, cfg.col_label_1, key_col_width, border_width)
		col_header_offset = 2  // header line + divider line
	}

	data_start := content_start + col_header_offset

	// Unified text_x for empty state rendering (same expression used inline in all five original procs)
	text_x := header_x + MENU_ACCENT_BAR_WIDTH + MENU_ACCENT_GAP

	// Rows to draw: filter.indices when filtering, else every cache index.
	row_count := len(state.filter.indices) if has_filter else len(items)

	if has_filter && row_count == 0 {
		// Filtered — no matches
		render_text_styled(screen, text_x, data_start + 1, "No matches found", TUI_DIM)
	} else if len(items) == 0 {
		// Empty (no items at all)
		render_text_styled(screen, text_x, content_start + 1, cfg.empty_line_1, TUI_DIM)
		if cfg.empty_line_2 != "" {
			render_text_styled(screen, text_x, content_start + 3, cfg.empty_line_2, TUI_MUTED)
		}
	} else {
		// Use get_view_visible_height to match the scroll logic's calculation exactly
		visible_height := max(1, get_view_visible_height(state))
		start := clamp(state.scroll_offset, 0, row_count)
		end := min(start + visible_height, row_count)

		for pos in start..<end {
			y := data_start + (pos - start)
			idx := state.filter.indices[pos] if has_filter else pos
			if idx < 0 || idx >= len(items) { continue }  // stale index guard
			m := meta[idx] if idx < len(meta) else RowMeta{}
			is_sep := m.kind == .Separator
			selected := pos == state.selected_index
			switch cfg.row_kind {
			case .Single:
				render_list_item(screen, header_x, y, items[idx], max_text_width, selected, m.source, is_sep)
			case .Table:
				key, value := items[idx], ""
				if idx < len(meta) {
					key, value = m.key, m.value
				} else if eq_idx := strings.index_byte(key, '='); eq_idx >= 0 {
					key, value = items[idx][:eq_idx], items[idx][eq_idx + 1:]
				}
				if cfg.mask_secrets && !is_sep { value = mask_secret_value(key, value) }
				render_table_row(screen, header_x, y, key, value, key_col_width, value_col_width, selected, is_sep)
			}
		}

		if row_count > visible_height {
			scroll_info: string
			if has_filter {
				scroll_info = fmt.tprintf("Showing %d-%d of %d matches", start+1, end, row_count)
			} else {
				scroll_info = fmt.tprintf("Showing %d-%d of %d", start+1, end, row_count)
			}
			render_text_styled(screen, header_x, data_start + visible_height, scroll_info, TUI_DIM)
		}
	}

	render_data_footer(screen, state, cfg.footer)
}

// True when a Table view draws its column header row (+ divider): items are
// visible either through the filter or, unfiltered, from the cache.
view_shows_column_header :: proc(state: ^TUIState) -> bool {
	if has_any_filter(state) {
		return len(state.filter.indices) > 0
	}
	return len(get_current_cache(state)) > 0
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
	if !state.detail.shown do return

	// Calculate overlay dimensions
	// +7 = 1 top border + 1 title + 1 divider gap + content + 2 blank rows before buttons + 1 button row + 1 bottom border
	overlay_width := min(state.terminal_width - 4, 60)
	overlay_height := min(len(state.detail.lines) + 7, state.terminal_height - 2)
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
	title_display := truncate_text(state.detail.title, overlay_width - 6)
	render_text_styled(screen, content_x + MENU_ACCENT_BAR_WIDTH + 1, title_y, title_display, TUI_PRIMARY, "", true)

	// Detail lines
	max_lines := overlay_height - 6
	for line, i in state.detail.lines {
		if i >= max_lines do break
		line_y := title_y + 2 + i
		max_line_width := overlay_width - 6  // 2 indent + border + padding
		display_line := truncate_text(line, max_line_width)
		render_text_styled(screen, content_x + 2, line_y, display_line, TUI_MUTED)
	}

	// Footer hint — one row above the bottom border; extra blank rows sit between content and buttons
	footer_y := overlay_y + overlay_height - 3
	if state.delete_confirm.pending {
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
		cancel_fg := TUI_ORANGE if !state.delete_confirm.focused else TUI_DIM
		delete_fg := TUI_ORANGE if  state.delete_confirm.focused else TUI_DIM
		cancel_bold := !state.delete_confirm.focused
		delete_bold :=  state.delete_confirm.focused

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
	row_meta_destroy(&state.row_meta[view])
}

// Get item count for current view (updated version with actual data)
get_view_item_count :: proc(state: ^TUIState) -> int {
	// While any filter is active the visible list IS filter.indices — even
	// when it is empty (zero matches → nothing to navigate or act on).
	if state.current_view != .MAIN_MENU && has_any_filter(state) {
		return len(state.filter.indices)
	}

	switch state.current_view {
	case .MAIN_MENU:
		return 8  // PATH, Aliases, Constants, Completions, Backups, Plugins, Hooks, Settings

	case .PATH_VIEW:
		if state.data_cache[.PATH_VIEW] != nil {
			items := cast(^[dynamic]string)state.data_cache[.PATH_VIEW]
			return len(items)
		}
		return 0  // cache not yet loaded

	case .ALIAS_VIEW:
		if state.data_cache[.ALIAS_VIEW] != nil {
			items := cast(^[dynamic]string)state.data_cache[.ALIAS_VIEW]
			return len(items)
		}
		return 0  // cache not yet loaded

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
// Main Event Router
// ============================================================================

handle_view_event :: proc(state: ^TUIState, key: KeyEvent) {
	#partial switch state.current_view {
	case .PATH_VIEW, .ALIAS_VIEW, .CONSTANTS_VIEW, .COMPLETIONS_VIEW, .BACKUPS_VIEW:
		handle_data_view_event(state, key)
	case .PLUGINS_VIEW:
		handle_plugins_event(state, key)
	case .HOOKS_VIEW, .SETTINGS_VIEW, .MAIN_MENU:
		// Read-only or handled elsewhere — no per-view keys
	}
}

// ============================================================================
// Unified Data-View Event Handler
// ============================================================================

// Per-view behavior knobs. Computed inline by `data_view_behavior`.
DataViewBehavior :: struct {
	supports_add:           bool,
	supports_source_filter: bool,
	supports_cleanup:       bool,
	supports_delete:        bool,
	supports_reveal:        bool,          // `v` toggles masking of secret-looking values
	delete_label:           string,        // "" for raw display (PATH); "Alias"/"Constant" otherwise
}

@(private="file")
data_view_behavior :: proc(view: TUIView) -> DataViewBehavior {
	#partial switch view {
	case .PATH_VIEW:
		return DataViewBehavior{
			supports_add           = true,
			supports_source_filter = true,
			supports_delete        = true,
		}
	case .ALIAS_VIEW:
		return DataViewBehavior{
			supports_add           = true,
			supports_source_filter = true,
			supports_delete        = true,
			delete_label           = "Alias",
		}
	case .CONSTANTS_VIEW:
		return DataViewBehavior{
			supports_add           = true,
			supports_source_filter = true,
			supports_delete        = true,
			supports_reveal        = true,
			delete_label           = "Constant",
		}
	case .BACKUPS_VIEW:
		return DataViewBehavior{
			supports_cleanup = true,
		}
	case:
		// .COMPLETIONS_VIEW and any other read-only view
		return DataViewBehavior{}
	}
}

handle_data_view_event :: proc(state: ^TUIState, key: KeyEvent) {
	#partial switch key.key {
	case .Char:
		view := state.current_view
		b := data_view_behavior(view)

		switch key.char {
		case 'a':
			if b.supports_add {
				show_add_form(state, view)
			}
		case 'd', 'x':
			if !b.supports_delete do return
			// Selection maps through filter.indices; zero matches → no-op.
			_, row, ok := selected_row(state)
			if !ok || row.kind == .Separator || len(row.key) == 0 do return
			if row.source == .EXTERNAL {
				set_notification(state, .ERROR, fmt.tprintf("%s is not managed by wayu (external)", row.key))
				return
			}
			// Delete key comes from RowMeta — never from display text, so
			// glyphs ("●", "[wayu]") can't leak into entry_remove.
			display := row.key
			if len(b.delete_label) > 0 {
				display = fmt.tprintf("%s: %s", b.delete_label, row.key)
			}
			show_delete_confirmation(state, view, display, row.key)

		case 'c':
			if !b.supports_cleanup do return
			if tui_cleanup_backups() {
				set_notification(state, .SUCCESS, "Cleaned up old backups")
				clear_view_cache(state, view)
			} else {
				set_notification(state, .ERROR, "Failed to cleanup backups")
			}
			state.full_redraw = true
			state.needs_refresh = true

		case '/':
			activate_filter(state)
			apply_filter(state, get_current_cache(state), get_current_meta(state))
			state.needs_refresh = true

		case 'v':
			if !b.supports_reveal do return
			state.reveal_secrets = !state.reveal_secrets
			state.needs_refresh = true

		case 's':
			if !b.supports_source_filter do return
			cycle_source_filter(state, get_current_cache(state), get_current_meta(state))
			tui_clamp_selection(state)
			state.needs_refresh = true
		}
	}
}

// ============================================================================
// Plugins View Event Handler
// ============================================================================

handle_plugins_event :: proc(state: ^TUIState, key: KeyEvent) {
	#partial switch key.key {
	case .Tab:
		// Switch between Installed and Registry tabs; reset cursor + filter
		switch_plugin_tab(state)

	case .Enter:
		// Registry tab: install selected plugin
		if state.plugin_tab == PLUGIN_TAB_REGISTRY {
			install_selected_registry_plugin(state)
		}

	case .Char:
		switch key.char {
		case '/':
			// Activate inline filter (works on both Installed and Registry tabs)
			activate_filter(state)
			apply_filter(state, get_current_cache(state), get_current_meta(state))
			state.needs_refresh = true
		case 't':
			// 't' also switches tabs (fallback for terminals where Tab is intercepted)
			switch_plugin_tab(state)
		case 'i':
			// 'i' installs selected registry plugin (fallback for terminals where Enter is intercepted)
			if state.plugin_tab == PLUGIN_TAB_REGISTRY {
				install_selected_registry_plugin(state)
			}
		case 'e', 'd':
			// Installed tab: enable/disable selected plugin
			if state.plugin_tab != PLUGIN_TAB_INSTALLED do return
			_, row, ok := selected_row(state)
			if !ok || len(row.key) == 0 do return
			enable := key.char == 'e'
			done := tui_enable_plugin(row.key) if enable else tui_disable_plugin(row.key)
			if done {
				set_notification(state, .SUCCESS, fmt.tprintf("%s %s", "Enabled" if enable else "Disabled", row.key))
				clear_view_cache(state, .PLUGINS_VIEW)
			} else {
				set_notification(state, .ERROR, fmt.tprintf("Failed to %s %s", "enable" if enable else "disable", row.key))
			}
			state.full_redraw = true
			state.needs_refresh = true
		}
	}
}

@(private="file")
switch_plugin_tab :: proc(state: ^TUIState) {
	deactivate_filter(state)
	state.selected_index = 0
	state.scroll_offset  = 0
	state.plugin_tab = 1 - state.plugin_tab  // toggle 0↔1
	state.needs_refresh = true
}

// Install the registry row under the (filter-mapped) selection.
@(private="file")
install_selected_registry_plugin :: proc(state: ^TUIState) {
	display, _, ok := selected_row(state)
	if !ok do return

	// Extract key (first \x00-delimited field)
	sep_idx := strings.index_byte(display, 0)
	plugin_key := strings.clone(display[:sep_idx] if sep_idx >= 0 else display, context.temp_allocator)

	ok = tui_install_plugin(plugin_key)
	if ok {
		// Reload installed list and invalidate registry so the
		// installed plugin is filtered out on next registry load
		clear_view_cache(state, .PLUGINS_VIEW)
		clear_registry_cache(state)
		set_notification(state, .SUCCESS, fmt.tprintf("Installed %s", plugin_key))
	} else {
		set_notification(state, .ERROR, fmt.tprintf("Failed to install %s", plugin_key))
	}
	state.full_redraw = true
	state.needs_refresh = true
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

	// Read-only display of the hooks configured in ~/.config/wayu/hooks.conf.
	// Mirrors the CLI `wayu hooks` status output: each configured hook is shown
	// as "name → command"; an empty config shows guidance instead.
	config := load_hook_config()
	defer free_hook_config(config)

	HookRow :: struct { name: string, cmd: string }
	rows := []HookRow{
		{"pre_path_add", config.pre_path_add},
		{"post_path_add", config.post_path_add},
		{"pre_path_remove", config.pre_path_remove},
		{"post_path_remove", config.post_path_remove},
		{"pre_alias_add", config.pre_alias_add},
		{"post_alias_add", config.post_alias_add},
		{"pre_alias_remove", config.pre_alias_remove},
		{"post_alias_remove", config.post_alias_remove},
		{"pre_constant_add", config.pre_constant_add},
		{"post_constant_add", config.post_constant_add},
		{"pre_constant_remove", config.pre_constant_remove},
		{"post_constant_remove", config.post_constant_remove},
		{"pre_plugin_install", config.pre_plugin_install},
		{"post_plugin_install", config.post_plugin_install},
		{"pre_export", config.pre_export},
		{"post_export", config.post_export},
	}

	// Width budget for the "name → command" line inside the content box.
	avail := max(0, border_width - CONTENT_PADDING_LEFT - 2)
	max_rows := max(0, state.terminal_height - content_start - 2)

	configured := 0
	y := content_start
	for row in rows {
		if len(row.cmd) == 0 do continue
		if configured >= max_rows do break
		// A placeholder inside "..." makes the hook invalid (never runs).
		if tok := hook_double_quoted_placeholder(row.cmd); len(tok) > 0 {
			line := fmt.tprintf("✗ %s → %s  (INVALID: %s inside \"...\")", row.name, row.cmd, tok)
			render_text_styled(screen, text_x, y, truncate_text(line, avail), TUI_ERROR)
		} else {
			line := fmt.tprintf("%s → %s", row.name, row.cmd)
			render_text_styled(screen, text_x, y, truncate_text(line, avail), TUI_MUTED)
		}
		y += 1
		configured += 1
	}

	if configured == 0 {
		render_text_styled(screen, text_x, content_start, "No hooks configured", TUI_PRIMARY, "", true)
		render_text_styled(screen, text_x, content_start + 2, "Hooks run custom commands before/after wayu operations.", TUI_DIM)
		render_text_styled(screen, text_x, content_start + 3, "Configure them by editing hooks.conf:", TUI_DIM)
		render_text_styled(screen, text_x, content_start + 5, "  wayu hooks edit", TUI_DIM)
	}

	render_data_footer(screen, state, get_footer_static_view(state.terminal_width))
}

// Settings View
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
		screen_mark_focus(screen, text_x, y)
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
	max_text_width := tui_calculate_content_width(border_width)
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

		if has_filter && len(state.filter.indices) > 0 {
			// Use get_view_visible_height to match the scroll logic's calculation exactly
			visible_height := get_view_visible_height(state)
			start := state.scroll_offset
			end   := min(start + visible_height, len(state.filter.indices))
			for idx in start..<end {
				y            := content_start + (idx - start)
				original_idx := state.filter.indices[idx]
				if original_idx < 0 || original_idx >= len(items) { continue }
				render_list_item(screen, header_x, y, items[original_idx], max_text_width, idx == state.selected_index)
			}
			if len(state.filter.indices) > visible_height {
				scroll_info := fmt.tprintf("Showing %d-%d of %d matches", start+1, end, len(state.filter.indices))
				render_text_styled(screen, header_x, content_start + visible_height, scroll_info, TUI_DIM)
			}
		} else if has_filter && len(state.filter.indices) == 0 {
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

	if has_filter && len(state.filter.indices) > 0 {
		// Same row budget as tui_state_move_selection uses for scrolling.
		visible_height := max(1, get_view_visible_height(state))
		start := state.scroll_offset
		end   := min(start + visible_height, len(state.filter.indices))
		for list_pos in start..<end {
			original_idx := state.filter.indices[list_pos]
			if original_idx < 0 || original_idx >= len(items^) { continue }
			render_registry_row(screen, header_x, text_x, data_start + (list_pos - start),
				items[original_idx], col_key_w, col_cat_w, col_sh_w, col_desc_w,
				list_pos == state.selected_index)
		}
		if len(state.filter.indices) > visible_height {
			scroll_info := fmt.tprintf("Showing %d-%d of %d matches", start+1, end, len(state.filter.indices))
			render_text_styled(screen, header_x, data_start + visible_height, scroll_info, TUI_DIM)
		}
	} else if has_filter && len(state.filter.indices) == 0 {
		render_text_styled(screen, text_x, data_start + 1, "No matches found", TUI_DIM)
	} else {
		visible_height := max(1, get_view_visible_height(state))
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

render_settings_view :: proc(state: ^TUIState, screen: ^Screen) {
	border_width, border_height := calculate_border_dimensions(state.terminal_width, state.terminal_height)
	render_box_styled(screen, BORDER_LEFT_WIDTH, BORDER_TOP_HEIGHT, border_width, border_height, TUI_BORDER_NORMAL)

	render_view_header(screen, state, "SETTINGS", "wayu Configuration", border_width)

	header_x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT
	text_x := header_x + MENU_ACCENT_BAR_WIDTH + MENU_ACCENT_GAP

	// Load settings from bridge (idempotent — only loads once).
	tui_load_settings(state)

	// Render lines live on context.temp_allocator — automatically freed at
	// end of frame, so we don't need per-line defer delete churn.
	dry_run_status := "off"
	if state.settings.dry_run { dry_run_status = "on" }

	toml_status := "missing"
	if state.settings.toml_exists {
		toml_status = state.settings.toml_path
	}

	settings := []string{
		fmt.tprintf("Version:     %s",    state.settings.version),
		fmt.tprintf("Shell:       %s",    state.settings.shell),
		fmt.tprintf("Config Dir:  %s",    state.settings.config_dir),
		fmt.tprintf("wayu.toml:   %s",    toml_status),
		fmt.tprintf("Backups:     %d",    state.settings.backups),
		fmt.tprintf("Plugins:     %d enabled", state.settings.plugins),
		fmt.tprintf("Dry-run:     %s",    dry_run_status),
	}

	content_start := LIST_ITEM_START_LINE + 2
	for setting, i in settings {
		render_text_styled(screen, text_x, content_start + i, setting, TUI_MUTED)
	}

	render_data_footer(screen, state, get_footer_static_view(state.terminal_width))
}
