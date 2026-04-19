package test_wayu

// Tests for the TUI source filter (cycled with `s` in data views).
// Ensures items are matched by their leading glyph rune and that
// cycle_source_filter rotates through ALL → WAYU_ACTIVE → WAYU_INACTIVE
// → EXTERNAL → ALL.

import "core:testing"
import tui "../../src/tui"

@(test)
test_matches_source_all_passes_everything :: proc(t: ^testing.T) {
	testing.expect(t, tui.matches_source("● /some/path", .ALL), "ALL must pass active item")
	testing.expect(t, tui.matches_source("○ /external",  .ALL), "ALL must pass external item")
	testing.expect(t, tui.matches_source("─── External (3) ───", .ALL), "ALL must pass separator")
	testing.expect(t, tui.matches_source("", .ALL), "ALL must pass empty string")
}

@(test)
test_matches_source_wayu_active_only_dot :: proc(t: ^testing.T) {
	testing.expect(t, tui.matches_source("● /path", .WAYU_ACTIVE), "● must match WAYU_ACTIVE")
	testing.expect(t, !tui.matches_source("⚠ /path", .WAYU_ACTIVE), "⚠ must NOT match WAYU_ACTIVE")
	testing.expect(t, !tui.matches_source("○ /path", .WAYU_ACTIVE), "○ must NOT match WAYU_ACTIVE")
	testing.expect(t, !tui.matches_source("─── sep ───", .WAYU_ACTIVE), "separator must NOT match WAYU_ACTIVE")
	testing.expect(t, !tui.matches_source("", .WAYU_ACTIVE), "empty must NOT match WAYU_ACTIVE")
}

@(test)
test_matches_source_external_only_circle :: proc(t: ^testing.T) {
	testing.expect(t, tui.matches_source("○ /usr/bin", .EXTERNAL), "○ must match EXTERNAL")
	testing.expect(t, !tui.matches_source("● /path", .EXTERNAL), "● must NOT match EXTERNAL")
	testing.expect(t, !tui.matches_source("⚠ /path", .EXTERNAL), "⚠ must NOT match EXTERNAL")
}

@(test)
test_matches_source_inactive_only_warn :: proc(t: ^testing.T) {
	testing.expect(t, tui.matches_source("⚠ /missing", .WAYU_INACTIVE), "⚠ must match WAYU_INACTIVE")
	testing.expect(t, !tui.matches_source("● /path", .WAYU_INACTIVE), "● must NOT match WAYU_INACTIVE")
	testing.expect(t, !tui.matches_source("○ /ext", .WAYU_INACTIVE), "○ must NOT match WAYU_INACTIVE")
}

@(test)
test_cycle_source_filter_rotates_and_reapplies :: proc(t: ^testing.T) {
	state := tui.tui_state_init()
	defer tui.tui_state_destroy(&state)

	items := []string{
		"● /wayu/a",
		"⚠ /wayu/missing",
		"○ /external/b",
		"─── External (1) ───",
		"○ /external/c",
	}

	// Start: ALL → WAYU_ACTIVE (1 match)
	tui.cycle_source_filter(&state, items)
	testing.expect(t, state.source_filter == .WAYU_ACTIVE, "First cycle should land on WAYU_ACTIVE")
	testing.expect(t, len(state.filtered_indices) == 1, "WAYU_ACTIVE should match exactly 1 item")

	// WAYU_ACTIVE → WAYU_INACTIVE (1 match)
	tui.cycle_source_filter(&state, items)
	testing.expect(t, state.source_filter == .WAYU_INACTIVE, "Second cycle should land on WAYU_INACTIVE")
	testing.expect(t, len(state.filtered_indices) == 1, "WAYU_INACTIVE should match exactly 1 item")

	// WAYU_INACTIVE → EXTERNAL (2 matches; separator excluded)
	tui.cycle_source_filter(&state, items)
	testing.expect(t, state.source_filter == .EXTERNAL, "Third cycle should land on EXTERNAL")
	testing.expect(t, len(state.filtered_indices) == 2, "EXTERNAL should match 2 items, separator excluded")

	// EXTERNAL → ALL (wraps — filtered_indices includes everything)
	tui.cycle_source_filter(&state, items)
	testing.expect(t, state.source_filter == .ALL, "Fourth cycle should wrap to ALL")
	testing.expect(t, len(state.filtered_indices) == len(items), "ALL should include every item including separator")
}

@(test)
test_has_any_filter_reflects_source_alone :: proc(t: ^testing.T) {
	state := tui.tui_state_init()
	defer tui.tui_state_destroy(&state)

	testing.expect(t, !tui.has_any_filter(&state), "Fresh state must report no filter")

	state.source_filter = .EXTERNAL
	testing.expect(t, tui.has_any_filter(&state), "Source filter alone must count as active filter")
}

// ---------------------------------------------------------------------------
// Inline `source:X` syntax in the text filter (feature #2).
// ---------------------------------------------------------------------------

@(test)
test_parse_source_token_extracts_value_and_strips :: proc(t: ^testing.T) {
	rem, src, ok := tui.parse_source_token("source:external")
	testing.expect(t, ok, "source:external should parse")
	testing.expect(t, src == .EXTERNAL, "value must map to EXTERNAL")
	testing.expect(t, rem == "", "remainder should be empty when token is alone")

	rem2, src2, ok2 := tui.parse_source_token("bin source:wayu")
	testing.expect(t, ok2, "trailing token should parse")
	testing.expect(t, src2 == .WAYU_ACTIVE, "wayu must map to WAYU_ACTIVE")
	testing.expect(t, rem2 == "bin", "remainder should keep free text")

	rem3, src3, ok3 := tui.parse_source_token("source:inactive /usr")
	testing.expect(t, ok3, "leading token should parse")
	testing.expect(t, src3 == .WAYU_INACTIVE, "inactive must map to WAYU_INACTIVE")
	testing.expect(t, rem3 == "/usr", "remainder should keep trailing path")

	rem4, _, ok4 := tui.parse_source_token("source:bogus rest")
	testing.expect(t, !ok4, "unknown value must report has_source=false")
	testing.expect(t, rem4 == "rest", "token must still be stripped for text matching")
}

@(test)
test_apply_filter_respects_inline_source_token :: proc(t: ^testing.T) {
	state := tui.tui_state_init()
	defer tui.tui_state_destroy(&state)

	items := []string{
		"● /wayu/bin",
		"⚠ /wayu/missing",
		"○ /external/bin",
		"○ /usr/local/bin",
	}

	// Typing `source:external` into the filter must narrow to the two
	// externals without needing to press `s`.
	append(&state.filter_text, 's', 'o', 'u', 'r', 'c', 'e', ':', 'e', 'x', 't', 'e', 'r', 'n', 'a', 'l')
	tui.apply_filter(&state, items)
	testing.expect(
		t,
		len(state.filtered_indices) == 2,
		"source:external should match exactly the 2 external items",
	)

	// Extend with a text term: `source:external bin` — both externals contain `bin`.
	clear(&state.filter_text)
	for b in "source:external bin" {
		append(&state.filter_text, u8(b))
	}
	tui.apply_filter(&state, items)
	testing.expect(
		t,
		len(state.filtered_indices) == 2,
		"source:external + bin should still match the 2 externals",
	)

	// Narrow further: `source:external usr` — only the `/usr/local/bin` survives.
	clear(&state.filter_text)
	for b in "source:external usr" {
		append(&state.filter_text, u8(b))
	}
	tui.apply_filter(&state, items)
	testing.expect(
		t,
		len(state.filtered_indices) == 1,
		"source:external + usr should narrow to 1 item",
	)
}
