package test_wayu

// Tests for the TUI source filter (cycled with `s` in data views) and the
// RowMeta-based selection model. Source matching uses RowMeta.source, never
// the rendered glyph text (which differs under NO_COLOR).

import "core:strings"
import "core:testing"
import wayu "../../src"

// Build a cache (display rows + parallel RowMeta) inside `state` for `view`.
@(private="file")
Row :: struct {
	display: string,
	key:     string,
	value:   string,
	source:  wayu.RowSource,
	kind:    wayu.RowKind,
}

@(private="file")
install_rows :: proc(state: ^wayu.TUIState, view: wayu.TUIView, rows: []Row) {
	items := make([dynamic]string)
	meta  := make([dynamic]wayu.RowMeta)
	for r in rows {
		key := r.key if len(r.key) > 0 else r.display
		wayu.cache_push(&items, &meta, strings.clone(r.display), key, r.value, r.source, r.kind)
	}
	wayu.tui_store_cache(state, view, items, meta)
	state.current_view = view
}

@(private="file")
PATH_ROWS := []Row{
	{display = "/wayu/a",              source = .WAYU_ACTIVE},
	{display = "/wayu/missing",        source = .WAYU_INACTIVE},
	{display = "/external/b",          source = .EXTERNAL},
	{display = "─── External (2) ───", kind = .Separator},
	{display = "/external/c",          source = .EXTERNAL},
}

@(test)
test_matches_source_all_passes_everything :: proc(t: ^testing.T) {
	for src in wayu.RowSource {
		testing.expect(t, wayu.matches_source(src, .ALL), "ALL must pass every source")
	}
}

@(test)
test_matches_source_exact :: proc(t: ^testing.T) {
	testing.expect(t, wayu.matches_source(.WAYU_ACTIVE, .WAYU_ACTIVE), "active matches WAYU_ACTIVE")
	testing.expect(t, !wayu.matches_source(.WAYU_INACTIVE, .WAYU_ACTIVE), "inactive must NOT match WAYU_ACTIVE")
	testing.expect(t, !wayu.matches_source(.EXTERNAL, .WAYU_ACTIVE), "external must NOT match WAYU_ACTIVE")
	testing.expect(t, !wayu.matches_source(.NONE, .WAYU_ACTIVE), "source-less rows must NOT match WAYU_ACTIVE")
	testing.expect(t, wayu.matches_source(.EXTERNAL, .EXTERNAL), "external matches EXTERNAL")
	testing.expect(t, wayu.matches_source(.WAYU_INACTIVE, .WAYU_INACTIVE), "inactive matches WAYU_INACTIVE")
}

@(test)
test_cycle_source_filter_rotates_and_reapplies :: proc(t: ^testing.T) {
	state := wayu.tui_state_init()
	defer wayu.tui_state_destroy(&state)
	install_rows(&state, .PATH_VIEW, PATH_ROWS)

	items := wayu.get_current_cache(&state)
	meta  := wayu.get_current_meta(&state)

	wayu.cycle_source_filter(&state, items, meta)
	testing.expect(t, state.source_filter == .WAYU_ACTIVE, "First cycle should land on WAYU_ACTIVE")
	testing.expect_value(t, len(state.filter.indices), 1)

	wayu.cycle_source_filter(&state, items, meta)
	testing.expect(t, state.source_filter == .WAYU_INACTIVE, "Second cycle should land on WAYU_INACTIVE")
	testing.expect_value(t, len(state.filter.indices), 1)

	wayu.cycle_source_filter(&state, items, meta)
	testing.expect(t, state.source_filter == .EXTERNAL, "Third cycle should land on EXTERNAL")
	testing.expect_value(t, len(state.filter.indices), 2)  // separator excluded

	wayu.cycle_source_filter(&state, items, meta)
	testing.expect(t, state.source_filter == .ALL, "Fourth cycle should wrap to ALL")
	testing.expect_value(t, len(state.filter.indices), len(items))
}

@(test)
test_source_filter_ignores_plain_glyph_text :: proc(t: ^testing.T) {
	// NO_COLOR glyphs used to be "[wayu]"/"[ext]" which the old glyph-prefix
	// matcher didn't know. Matching on RowMeta makes glyph text irrelevant,
	// and typing "wayu" must not match every row via its glyph.
	state := wayu.tui_state_init()
	defer wayu.tui_state_destroy(&state)
	install_rows(&state, .PATH_VIEW, PATH_ROWS)

	wayu.tui_plain_glyphs = true
	defer wayu.tui_plain_glyphs = false

	state.source_filter = .EXTERNAL
	wayu.apply_filter(&state, wayu.get_current_cache(&state), wayu.get_current_meta(&state))
	testing.expect_value(t, len(state.filter.indices), 2)

	state.source_filter = .ALL
	for b in "wayu" do append(&state.filter.text, u8(b))
	wayu.apply_filter(&state, wayu.get_current_cache(&state), wayu.get_current_meta(&state))
	testing.expect_value(t, len(state.filter.indices), 2)  // /wayu/a, /wayu/missing
}

@(test)
test_has_any_filter_reflects_source_alone :: proc(t: ^testing.T) {
	state := wayu.tui_state_init()
	defer wayu.tui_state_destroy(&state)

	testing.expect(t, !wayu.has_any_filter(&state), "Fresh state must report no filter")

	state.source_filter = .EXTERNAL
	testing.expect(t, wayu.has_any_filter(&state), "Source filter alone must count as active filter")
}

@(test)
test_deactivate_filter_resets_source_filter :: proc(t: ^testing.T) {
	state := wayu.tui_state_init()
	defer wayu.tui_state_destroy(&state)

	state.source_filter = .EXTERNAL
	wayu.deactivate_filter(&state)
	testing.expect(t, state.source_filter == .ALL, "deactivate_filter must reset source_filter to ALL")
	testing.expect(t, !wayu.has_any_filter(&state), "no filter may survive deactivation")
}

// ---------------------------------------------------------------------------
// Selection → cache index mapping (actions under a filter)
// ---------------------------------------------------------------------------

@(test)
test_selected_row_maps_through_filter_indices :: proc(t: ^testing.T) {
	state := wayu.tui_state_init()
	defer wayu.tui_state_destroy(&state)
	install_rows(&state, .PATH_VIEW, PATH_ROWS)

	state.source_filter = .EXTERNAL
	wayu.apply_filter(&state, wayu.get_current_cache(&state), wayu.get_current_meta(&state))

	// Visible row 1 under the EXTERNAL filter is cache index 4 ("/external/c"),
	// not cache index 1 ("/wayu/missing").
	state.selected_index = 1
	display, row, ok := wayu.selected_row(&state)
	testing.expect(t, ok, "selection must resolve")
	testing.expect_value(t, display, "/external/c")
	testing.expect_value(t, row.key, "/external/c")
	testing.expect(t, row.source == .EXTERNAL, "source must come from metadata")
}

@(test)
test_selected_row_zero_matches_is_noop :: proc(t: ^testing.T) {
	state := wayu.tui_state_init()
	defer wayu.tui_state_destroy(&state)
	install_rows(&state, .PATH_VIEW, PATH_ROWS)

	wayu.activate_filter(&state)
	for b in "zzz-no-match" do append(&state.filter.text, u8(b))
	wayu.apply_filter(&state, wayu.get_current_cache(&state), wayu.get_current_meta(&state))
	testing.expect_value(t, len(state.filter.indices), 0)

	_, _, ok := wayu.selected_row(&state)
	testing.expect(t, !ok, "zero matches must not resolve to any row")
	testing.expect_value(t, wayu.get_view_item_count(&state), 0)
}

@(test)
test_delete_key_is_raw_key_not_display :: proc(t: ^testing.T) {
	state := wayu.tui_state_init()
	defer wayu.tui_state_destroy(&state)
	install_rows(&state, .ALIAS_VIEW, []Row{
		{display = "ll=ls -la", key = "ll", value = "ls -la", source = .WAYU_ACTIVE},
		{display = "gs=git status", key = "gs", value = "git status", source = .WAYU_INACTIVE},
	})

	state.selected_index = 1
	wayu.handle_data_view_event(&state, wayu.KeyEvent{key = .Char, char = 'd'})
	testing.expect(t, state.delete_confirm.pending, "d must open the delete confirmation")
	testing.expect_value(t, state.delete_confirm.name, "gs")
	wayu.clear_detail(&state)
}

@(test)
test_delete_refuses_separator_and_external :: proc(t: ^testing.T) {
	state := wayu.tui_state_init()
	defer wayu.tui_state_destroy(&state)
	install_rows(&state, .PATH_VIEW, PATH_ROWS)

	state.selected_index = 3  // separator
	wayu.handle_data_view_event(&state, wayu.KeyEvent{key = .Char, char = 'd'})
	testing.expect(t, !state.delete_confirm.pending, "separator rows are not deletable")

	state.selected_index = 2  // external
	wayu.handle_data_view_event(&state, wayu.KeyEvent{key = .Char, char = 'd'})
	testing.expect(t, !state.delete_confirm.pending, "external rows are not managed by wayu")

	state.selected_index = 0
	wayu.handle_data_view_event(&state, wayu.KeyEvent{key = .Char, char = 'd'})
	testing.expect(t, state.delete_confirm.pending, "wayu rows are deletable")
	testing.expect_value(t, state.delete_confirm.name, "/wayu/a")
	wayu.clear_detail(&state)
}

@(test)
test_refresh_filter_after_reload_drops_stale_indices :: proc(t: ^testing.T) {
	state := wayu.tui_state_init()
	defer wayu.tui_state_destroy(&state)
	install_rows(&state, .PATH_VIEW, PATH_ROWS)

	state.source_filter = .EXTERNAL
	wayu.apply_filter(&state, wayu.get_current_cache(&state), wayu.get_current_meta(&state))
	state.selected_index = 1
	testing.expect_value(t, state.filter.indices[1], 4)

	// Reload with a shorter cache: index 4 no longer exists.
	install_rows(&state, .PATH_VIEW, []Row{
		{display = "/wayu/a",     source = .WAYU_ACTIVE},
		{display = "/external/b", source = .EXTERNAL},
	})
	wayu.tui_refresh_filter(&state)

	testing.expect_value(t, len(state.filter.indices), 1)
	testing.expect_value(t, state.filter.indices[0], 1)
	testing.expect_value(t, state.selected_index, 0)
	_, row, ok := wayu.selected_row(&state)
	testing.expect(t, ok, "selection must resolve after refresh")
	testing.expect_value(t, row.key, "/external/b")
}

// ---------------------------------------------------------------------------
// Inline `source:X` syntax in the text filter (feature #2).
// ---------------------------------------------------------------------------

@(test)
test_parse_source_token_extracts_value_and_strips :: proc(t: ^testing.T) {
	rem, src, ok := wayu.parse_source_token("source:external")
	testing.expect(t, ok, "source:external should parse")
	testing.expect(t, src == .EXTERNAL, "value must map to EXTERNAL")
	testing.expect(t, rem == "", "remainder should be empty when token is alone")

	rem2, src2, ok2 := wayu.parse_source_token("bin source:wayu")
	testing.expect(t, ok2, "trailing token should parse")
	testing.expect(t, src2 == .WAYU_ACTIVE, "wayu must map to WAYU_ACTIVE")
	testing.expect(t, rem2 == "bin", "remainder should keep free text")

	rem3, src3, ok3 := wayu.parse_source_token("source:inactive /usr")
	testing.expect(t, ok3, "leading token should parse")
	testing.expect(t, src3 == .WAYU_INACTIVE, "inactive must map to WAYU_INACTIVE")
	testing.expect(t, rem3 == "/usr", "remainder should keep trailing path")

	rem4, _, ok4 := wayu.parse_source_token("source:bogus rest")
	testing.expect(t, !ok4, "unknown value must report has_source=false")
	testing.expect(t, rem4 == "rest", "token must still be stripped for text matching")
}

@(test)
test_apply_filter_respects_inline_source_token :: proc(t: ^testing.T) {
	state := wayu.tui_state_init()
	defer wayu.tui_state_destroy(&state)
	install_rows(&state, .PATH_VIEW, []Row{
		{display = "/wayu/bin",      source = .WAYU_ACTIVE},
		{display = "/wayu/missing",  source = .WAYU_INACTIVE},
		{display = "/external/bin",  source = .EXTERNAL},
		{display = "/usr/local/bin", source = .EXTERNAL},
	})
	items := wayu.get_current_cache(&state)
	meta  := wayu.get_current_meta(&state)

	set_text :: proc(state: ^wayu.TUIState, text: string) {
		clear(&state.filter.text)
		for b in transmute([]u8)text do append(&state.filter.text, b)
	}

	set_text(&state, "source:external")
	wayu.apply_filter(&state, items, meta)
	testing.expect_value(t, len(state.filter.indices), 2)

	set_text(&state, "source:external bin")
	wayu.apply_filter(&state, items, meta)
	testing.expect_value(t, len(state.filter.indices), 2)

	set_text(&state, "source:external usr")
	wayu.apply_filter(&state, items, meta)
	testing.expect_value(t, len(state.filter.indices), 1)
}
