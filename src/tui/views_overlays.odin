package wayu_tui

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"

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
