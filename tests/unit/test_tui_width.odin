package test_wayu

// Wide-character / display-width regression tests: the cell renderer,
// truncate_text, style.odin width helpers and table truncation must all agree
// that CJK and emoji occupy two terminal columns.

import "core:strings"
import "core:testing"
import wayu "../../src"

@(test)
test_width_functions_agree_on_cjk :: proc(t: ^testing.T) {
	cases := []string{"abc", "日本語", "a日b", "🚀x", "\x1b[31m日本\x1b[0m"}
	want  := []int{3, 6, 4, 3, 4}
	for s, i in cases {
		testing.expectf(t, wayu.visual_width(s) == want[i], "visual_width(%q) = %d, want %d", s, wayu.visual_width(s), want[i])
		testing.expectf(t, wayu.visible_width(s) == want[i], "visible_width(%q) = %d, want %d", s, wayu.visible_width(s), want[i])
	}
}

@(test)
test_truncate_text_counts_columns :: proc(t: ^testing.T) {
	// 5 CJK chars = 10 columns; into 7 columns → 3 chars (6) + "…" (1).
	got := wayu.truncate_text("日本語日本", 7)
	testing.expect_value(t, got, "日本語…")
	testing.expect(t, wayu.visual_width(got) <= 7, "result must fit the budget")
	// Fits → returned unchanged.
	testing.expect_value(t, wayu.truncate_text("日本", 4), "日本")
	testing.expect_value(t, wayu.truncate_text("abc", 0), "")
}

@(test)
test_truncate_to_width_wide_chars :: proc(t: ^testing.T) {
	got := wayu.truncate_to_width("日本語テキスト", 9)
	defer if raw_data(got) != raw_data(string("日本語テキスト")) do delete(got)
	plain := wayu.strip_ansi_codes(got)
	defer delete(plain)
	testing.expectf(t, wayu.visual_width(plain) <= 9, "truncate_to_width overflowed: %q", plain)
	testing.expect(t, strings.has_suffix(plain, "..."), "must end with ellipsis")
}

@(test)
test_align_text_pads_by_columns :: proc(t: ^testing.T) {
	got := wayu.align_text("日本", 6, .Left)
	defer delete(got)
	testing.expect_value(t, got, "日本  ")
}

@(test)
test_pad_string_truncates_by_columns :: proc(t: ^testing.T) {
	got := wayu.pad_string("日本語日本語", 5)
	defer delete(got)
	testing.expectf(t, wayu.visual_width(got) <= 5, "pad_string overflowed: %q (%d cols)", got, wayu.visual_width(got))
}

@(test)
test_apply_text_styles_returns_owned_string :: proc(t: ^testing.T) {
	s := wayu.style_bold(wayu.new_style(), true)
	got := wayu.apply_text_styles(s, "hi", 4)
	defer delete(got)  // must be a live heap string, not a destroyed builder buffer
	plain := wayu.strip_ansi_codes(got)
	defer delete(plain)
	testing.expect_value(t, plain, "hi  ")
}

@(test)
test_render_text_wide_chars_use_two_cells :: proc(t: ^testing.T) {
	screen := wayu.screen_create(10, 1)
	defer wayu.screen_destroy(&screen)

	wayu.render_text_styled(&screen, 0, 0, "日a本")
	row := screen.buffer[0]
	testing.expect_value(t, row[0].char, '日')
	testing.expect_value(t, row[1].char, wayu.CELL_CONTINUATION)
	testing.expect_value(t, row[2].char, 'a')
	testing.expect_value(t, row[3].char, '本')
	testing.expect_value(t, row[4].char, wayu.CELL_CONTINUATION)

	out := wayu.screen_to_string(&screen)
	defer delete(out)
	testing.expect_value(t, out, "日a本     ")
}

@(test)
test_render_text_wide_char_does_not_overflow_edge :: proc(t: ^testing.T) {
	screen := wayu.screen_create(3, 1)
	defer wayu.screen_destroy(&screen)

	// "a日日": 'a' + one wide char fits (3 cols); the second wide char doesn't.
	wayu.render_text_styled(&screen, 0, 0, "a日日")
	row := screen.buffer[0]
	testing.expect_value(t, row[0].char, 'a')
	testing.expect_value(t, row[1].char, '日')
	testing.expect_value(t, row[2].char, wayu.CELL_CONTINUATION)
}

@(test)
test_overwriting_half_of_wide_char_clears_other_half :: proc(t: ^testing.T) {
	screen := wayu.screen_create(4, 1)
	defer wayu.screen_destroy(&screen)

	wayu.render_text_styled(&screen, 0, 0, "日")
	wayu.screen_set_cell(&screen, 1, 0, wayu.Cell{char = 'x'})
	testing.expect_value(t, screen.buffer[0][0].char, ' ')  // orphaned lead blanked
	testing.expect_value(t, screen.buffer[0][1].char, 'x')

	wayu.render_text_styled(&screen, 2, 0, "本")
	wayu.screen_set_cell(&screen, 2, 0, wayu.Cell{char = 'y'})
	testing.expect_value(t, screen.buffer[0][3].char, ' ')  // orphaned continuation blanked
}

@(test)
test_truecolor_downsampling :: proc(t: ^testing.T) {
	is_bg, r, g, b, ok := wayu.parse_truecolor_sgr(wayu.TUI_PRIMARY)
	testing.expect(t, ok && !is_bg, "TUI_PRIMARY is a truecolor fg code")
	testing.expect_value(t, r, 228)
	testing.expect_value(t, g, 0)
	testing.expect_value(t, b, 80)

	saved := wayu.tui_color_mode
	defer wayu.tui_color_mode = saved

	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)

	wayu.tui_color_mode = .ASCII
	wayu.write_tui_color(&sb, wayu.TUI_PRIMARY)
	testing.expect_value(t, strings.to_string(sb), "")

	wayu.tui_color_mode = .ANSI256
	wayu.write_tui_color(&sb, wayu.TUI_PRIMARY)
	testing.expect(t, strings.has_prefix(strings.to_string(sb), "\x1b[38;5;"), "256-color profile must emit 38;5;N")
}
