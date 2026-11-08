package test_wayu

// OKAMI-172 regressions: data-view rows must stay inside the content box, and
// the constants loader must not list an environment variable twice.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import wayu "../../src"

// Box + one row at the given terminal width, like render_list_view lays it out.
@(private = "file")
rows_screen :: proc(width: int) -> (screen: wayu.Screen, border_width, content_width: int) {
	screen = wayu.screen_create(width, 4)
	border_width = width - wayu.BORDER_HORIZONTAL_TOTAL
	content_width = wayu.tui_calculate_content_width(border_width)
	wayu.render_box_styled(&screen, wayu.BORDER_LEFT_WIDTH, 0, border_width, 4)
	return
}

@(test)
test_list_item_keeps_right_border :: proc(t: ^testing.T) {
	for width in ([]int{40, 80, 120}) {
		screen, border_width, content_width := rows_screen(width)
		defer wayu.screen_destroy(&screen)
		right := wayu.BORDER_LEFT_WIDTH + border_width - 1

		long := strings.repeat("x", 300)
		defer delete(long)
		header_x := wayu.BORDER_LEFT_WIDTH + wayu.CONTENT_PADDING_LEFT
		wayu.render_list_item(&screen, header_x, 1, long, content_width, true, .WAYU_ACTIVE)
		wayu.render_list_item(&screen, header_x, 2, "short", content_width, false)

		for y in 1..=2 {
			testing.expectf(t, screen.buffer[y][right].char == wayu.BOX_VERTICAL,
				"width %d row %d: right border at col %d overwritten with %q", width, y, right, screen.buffer[y][right].char)
		}
		// Truncated text ends with the ellipsis inside the box.
		testing.expectf(t, screen.buffer[1][right - 1].char == ' ' || screen.buffer[1][right - 1].char == '…' || screen.buffer[1][right - 2].char == '…',
			"width %d: row text should be truncated before the border", width)
	}
}

@(test)
test_table_row_keeps_right_border :: proc(t: ^testing.T) {
	for width in ([]int{40, 80, 120}) {
		screen, border_width, content_width := rows_screen(width)
		defer wayu.screen_destroy(&screen)
		right := wayu.BORDER_LEFT_WIDTH + border_width - 1

		key_w := wayu.MIN_KEY_COL_WIDTH
		value_w := max(1, content_width - key_w - wayu.COLUMN_GAP)
		long := strings.repeat("v", 300)
		defer delete(long)
		header_x := wayu.BORDER_LEFT_WIDTH + wayu.CONTENT_PADDING_LEFT
		wayu.render_table_row(&screen, header_x, 1, "KEY", long, key_w, value_w, true)
		wayu.render_table_row(&screen, header_x, 2, "─── External (3) ───", "", key_w, value_w, false, true)

		left := wayu.BORDER_LEFT_WIDTH
		for y in 1..=2 {
			testing.expectf(t, screen.buffer[y][right].char == wayu.BOX_VERTICAL,
				"width %d row %d: right border at col %d overwritten with %q", width, y, right, screen.buffer[y][right].char)
			testing.expectf(t, screen.buffer[y][left].char == wayu.BOX_VERTICAL,
				"width %d row %d: left border overwritten", width, y)
		}
	}
}

@(test)
test_tui_load_constants_lists_each_env_var_once :: proc(t: ^testing.T) {
	dir := test_tmp("wayu-test-tui-rows")
	os.make_directory(dir)
	defer os.remove_all(dir)

	toml_path := fmt.tprintf("%s/%s", dir, wayu.WAYU_TOML)
	content := "[env]\nWAYU_TUI_ROWS_MANAGED = \"1\"\n"
	testing.expect(t, os.write_entire_file(toml_path, transmute([]byte)content) == nil)

	original_config := wayu.wayu.config
	wayu.wayu.config = dir
	defer wayu.wayu.config = original_config

	state := wayu.tui_state_init()
	defer wayu.tui_state_destroy(&state)
	wayu.tui_load_constants(&state)

	seen := make(map[string]int)
	defer delete(seen)
	for m in state.row_meta[.CONSTANTS_VIEW] {
		if m.kind == .Separator do continue
		seen[m.key] += 1
	}
	testing.expect(t, len(seen) > 0, "constants view should list rows")
	testing.expect_value(t, seen["WAYU_TUI_ROWS_MANAGED"], 1)
	for key, n in seen {
		testing.expectf(t, n == 1, "%s listed %d times in the constants view", key, n)
	}
}
