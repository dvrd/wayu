// test_tui_colors_sync.odin - Regression test for N1
//
// The TUI package (src/tui/colors.odin) intentionally duplicates a subset of
// the main package's VIBRANT color palette because Odin's package system
// can't share compile-time constants across packages without a common base.
//
// This test enforces the duplication contract: whenever a TUI_* constant
// claims to mirror a VIBRANT_* constant from the main package, they MUST be
// byte-identical ANSI escape sequences. If someone updates one side without
// the other, this test fails at compile+test time.
//
// See thoughts/code_review_2026-04-24.md N1 for the long-term consolidation
// story. Until that happens, this test is the line of defense.

package test_wayu

import "core:testing"
import wayu "../../src"
import tui  "../../src/tui"

@(test)
test_tui_color_constants_match_main_package :: proc(t: ^testing.T) {
	// Core palette
	testing.expect(t, tui.TUI_PRIMARY   == wayu.VIBRANT_PRIMARY,
	                  "TUI_PRIMARY must mirror wayu.VIBRANT_PRIMARY")
	testing.expect(t, tui.TUI_SECONDARY == wayu.VIBRANT_SECONDARY,
	                  "TUI_SECONDARY must mirror wayu.VIBRANT_SECONDARY")

	// Semantic colors
	testing.expect(t, tui.TUI_SUCCESS == wayu.VIBRANT_SUCCESS,
	                  "TUI_SUCCESS must mirror wayu.VIBRANT_SUCCESS")
	testing.expect(t, tui.TUI_ERROR   == wayu.VIBRANT_ERROR,
	                  "TUI_ERROR must mirror wayu.VIBRANT_ERROR")
	testing.expect(t, tui.TUI_WARNING == wayu.VIBRANT_WARNING,
	                  "TUI_WARNING must mirror wayu.VIBRANT_WARNING")
	testing.expect(t, tui.TUI_INFO    == wayu.VIBRANT_INFO,
	                  "TUI_INFO must mirror wayu.VIBRANT_INFO")

	// UI text colors
	testing.expect(t, tui.TUI_MUTED == wayu.VIBRANT_MUTED,
	                  "TUI_MUTED must mirror wayu.VIBRANT_MUTED")
	testing.expect(t, tui.TUI_DIM   == wayu.VIBRANT_DIM,
	                  "TUI_DIM must mirror wayu.VIBRANT_DIM")

	// Backgrounds
	testing.expect(t, tui.TUI_BG_NORMAL   == wayu.BG_DARK,
	                  "TUI_BG_NORMAL must mirror wayu.BG_DARK")
	testing.expect(t, tui.TUI_BG_SELECTED == wayu.BG_DARKER,
	                  "TUI_BG_SELECTED must mirror wayu.BG_DARKER")

	// Control codes
	testing.expect(t, tui.TUI_RESET    == wayu.RESET_CODE,
	                  "TUI_RESET must mirror wayu.RESET_CODE")
	testing.expect(t, tui.TUI_BOLD     == wayu.BOLD_CODE,
	                  "TUI_BOLD must mirror wayu.BOLD_CODE")
	testing.expect(t, tui.TUI_DIM_CODE == wayu.DIM_CODE,
	                  "TUI_DIM_CODE must mirror wayu.DIM_CODE")

	// Highlight + primary synonym
	testing.expect(t, tui.TUI_HIGHLIGHT == wayu.VIBRANT_HIGHLIGHT,
	                  "TUI_HIGHLIGHT must mirror wayu.VIBRANT_HIGHLIGHT")
}
