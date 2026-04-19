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
