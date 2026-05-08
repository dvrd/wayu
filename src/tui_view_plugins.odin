package wayu

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"

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

