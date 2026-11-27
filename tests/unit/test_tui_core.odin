package test_wayu

import wayu "../../src"
import "core:testing"

@(test)
test_render_clips_at_right_edge :: proc(t: ^testing.T) {
	screen := wayu.screen_create(3, 2)
	defer wayu.screen_destroy(&screen)

	wayu.render_text(&screen, 2, 0, "xy")
	testing.expect_value(t, screen.buffer[0][2].char, 'x')
	testing.expect_value(t, screen.buffer[1][0].char, ' ')
}
