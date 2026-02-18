package test_wayu

import "core:testing"
import wayu "../../src"

// ============================================================================
// visual_width Tests (layout.odin)
// ============================================================================

@(test)
test_visual_width_ascii :: proc(t: ^testing.T) {
	width := wayu.visual_width("hello")
	testing.expect_value(t, width, 5)
}

@(test)
test_visual_width_empty :: proc(t: ^testing.T) {
	width := wayu.visual_width("")
	testing.expect_value(t, width, 0)
}

@(test)
test_visual_width_ansi_codes :: proc(t: ^testing.T) {
	// \e[31m = red color, \e[0m = reset
	width := wayu.visual_width("\x1b[31mred\x1b[0m")
	testing.expect_value(t, width, 3)
}

@(test)
test_visual_width_ansi_bold :: proc(t: ^testing.T) {
	// \e[1m = bold, \e[0m = reset
	width := wayu.visual_width("\x1b[1mbold\x1b[0m")
	testing.expect_value(t, width, 4)
}

@(test)
test_visual_width_multiple_ansi :: proc(t: ^testing.T) {
	// Multiple ANSI sequences around text
	width := wayu.visual_width("\x1b[1m\x1b[31mhi\x1b[0m")
	testing.expect_value(t, width, 2)
}
